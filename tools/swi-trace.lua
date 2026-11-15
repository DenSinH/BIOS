-- swi-trace.lua: log GBA state before / after every SWI call (mGBA scripting).
--
-- Usage:   run-gba ROM [STATE] --trace          (see flake.nix)
--     or:  mgba-qt -b bios.bin --script tools/swi-trace.lua ROM
--
-- Environment variables (all optional):
--   SWI_TRACE_OUT      output file                      (default: swi-trace.log)
--   SWI_TRACE_ONLY     comma separated SWI numbers      (e.g. "0x0A,0x09"; default: all)
--   SWI_TRACE_SKIP     comma separated SWI numbers to ignore (e.g. "0x05,0x02" for VBlankIntrWait/Halt)
--   SWI_TRACE_HASH     comma separated memory domains to hash before/after
--                      (e.g. "iwram,vram"; slow for big domains: wram = 256 KiB)
--   SWI_TRACE_CONSOLE  set to 1 to also print to mGBA's scripting console
--
-- How it works: when a SWI executes, the CPU jumps to the SWI vector (0x08).
-- A breakpoint there captures the arguments (r0-r12 are not banked in SVC mode,
-- so they are exactly what the caller passed) and the return address (lr_svc).
-- A second breakpoint on that return address captures the state after the BIOS
-- has returned to the caller.
--
-- The log has one block per call and contains no timing information, so two runs
-- with different BIOSes (same savestate!) can be compared with plain `diff`.

local SWI_VECTOR = 0x08
local MAX_PENDING = 64

local SWI_NAMES = {
	[0x00] = "SoftReset",           [0x01] = "RegisterRamReset",
	[0x02] = "Halt",                [0x03] = "Stop",
	[0x04] = "IntrWait",            [0x05] = "VBlankIntrWait",
	[0x06] = "Div",                 [0x07] = "DivArm",
	[0x08] = "Sqrt",                [0x09] = "ArcTan",
	[0x0A] = "ArcTan2",             [0x0B] = "CpuSet",
	[0x0C] = "CpuFastSet",          [0x0D] = "GetBiosChecksum",
	[0x0E] = "BgAffineSet",         [0x0F] = "ObjAffineSet",
	[0x10] = "BitUnPack",           [0x11] = "LZ77UnCompWram",
	[0x12] = "LZ77UnCompVram",      [0x13] = "HuffUnComp",
	[0x14] = "RLUnCompWram",        [0x15] = "RLUnCompVram",
	[0x16] = "Diff8bitUnFilterWram", [0x17] = "Diff8bitUnFilterVram",
	[0x18] = "Diff16bitUnFilter",   [0x19] = "SoundBiasChange",
	[0x1A] = "SoundDriverInit",     [0x1B] = "SoundDriverMode",
	[0x1C] = "SoundDriverMain",     [0x1D] = "SoundDriverVSync",
	[0x1E] = "SoundChannelClear",   [0x1F] = "MidiKey2Freq",
	[0x20] = "MusicPlayerOpen",     [0x21] = "MusicPlayerStart",
	[0x22] = "MusicPlayerStop",     [0x23] = "MusicPlayerContinue",
	[0x24] = "MusicPlayerFadeOut",  [0x25] = "MultiBoot",
	[0x26] = "HardReset",           [0x27] = "CustomHalt",
	[0x28] = "SoundDriverVSyncOff", [0x29] = "SoundDriverVSyncOn",
	[0x2A] = "SoundGetJumpList",
}

-- configuration ------------------------------------------------------------

local function parseList(s)
	local t = {}
	for item in (s or ""):gmatch("[^,%s]+") do
		t[#t + 1] = item
	end
	return t
end

local function numberSet(s)
	local set, any = {}, false
	for _, item in ipairs(parseList(s)) do
		local n = tonumber(item)
		if n then
			set[n] = true
			any = true
		end
	end
	return set, any
end

local OUT_PATH = os.getenv("SWI_TRACE_OUT") or "swi-trace.log"
local ONLY, HAS_ONLY = numberSet(os.getenv("SWI_TRACE_ONLY"))
local SKIP = numberSet(os.getenv("SWI_TRACE_SKIP"))
local HASH_DOMAINS = parseList(os.getenv("SWI_TRACE_HASH"))
local TO_CONSOLE = os.getenv("SWI_TRACE_CONSOLE") == "1"

local logFile = assert(io.open(OUT_PATH, "w"))
logFile:setvbuf("line")

local function log(line)
	logFile:write(line, "\n")
	if TO_CONSOLE then
		console:log(line)
	end
end

-- helpers ------------------------------------------------------------------

local function u32(n)
	return n % 4294967296
end

local function hex(n)
	return string.format("%08X", u32(n))
end

local function snapshot()
	local s = {}
	for i = 0, 12 do
		s[i] = u32(emu:readRegister("r" .. i))
	end
	s.cpsr = u32(emu:readRegister("cpsr"))
	return s
end

local function flags(cpsr)
	local function bit(n)
		return math.floor(cpsr / 2 ^ n) % 2 == 1
	end
	return (bit(31) and "N" or "-") .. (bit(30) and "Z" or "-")
		.. (bit(29) and "C" or "-") .. (bit(28) and "V" or "-")
end

local function hashDomain(name)
	local dom = emu.memory[name]
	if not dom then
		return "?"
	end
	local data = dom:readRange(0, dom:size())
	local h = 5381
	for i = 1, #data do
		h = (h * 31 + data:byte(i)) % 4294967296
	end
	return hex(h)
end

local function hashAll()
	local t = {}
	for _, name in ipairs(HASH_DOMAINS) do
		t[#t + 1] = { name = name, hash = hashDomain(name) }
	end
	return t
end

-- Work out which SWI was executed from the return address (lr_svc).
-- Thumb: lr = addr + 2, instruction 0xDFnn.  ARM: lr = addr + 4, cond 1111 comment24.
local function decode(ret)
	local hw = emu:read16(ret - 2)
	if hw >= 0xDF00 and hw <= 0xDFFF then
		return "THUMB", hw % 256, hw % 256
	end
	local w = u32(emu:read32(ret - 4))
	if math.floor(w / 0x1000000) % 16 == 0xF then
		local comment = w % 0x1000000
		return "ARM", math.floor(comment / 0x10000), comment
	end
	return "???", -1, 0
end

local function regLine(label, s, first, last)
	local parts = {}
	for i = first, last do
		parts[#parts + 1] = string.format("r%d=%s", i, hex(s[i]))
	end
	return string.format("  %-6s %s", label, table.concat(parts, " "))
end

-- tracing ------------------------------------------------------------------

local pending = {}  -- stack of calls waiting for their return
local afterBp = {}  -- return address -> true once a breakpoint exists there
local seq = 0

local function finishCall(ret)
	local idx
	for i = #pending, 1, -1 do
		if pending[i].ret == ret then
			idx = i
			break
		end
	end
	if not idx then
		return
	end
	local e = table.remove(pending, idx)
	local after = snapshot()

	log(string.format("#%d SWI 0x%02X %s [%s, comment=%06X, ret=%08X]",
		e.seq, e.num, SWI_NAMES[e.num] or "?", e.kind, e.comment, e.ret))
	log(regLine("before", e.before, 0, 3) .. " flags=" .. flags(e.before.cpsr))
	log(regLine("after", after, 0, 3) .. " flags=" .. flags(after.cpsr))
	log(regLine("before", e.before, 4, 12))
	log(regLine("after", after, 4, 12))
	if after.cpsr ~= e.before.cpsr then
		-- flags are restored from SPSR on return, so this should only differ in mode bits
		log(string.format("  cpsr   before(SVC)=%s after=%s", hex(e.before.cpsr), hex(after.cpsr)))
	end
	for i, h in ipairs(e.hashes) do
		local hAfter = hashDomain(h.name)
		log(string.format("  mem    %-8s before=%s after=%s%s", h.name, h.hash, hAfter,
			h.hash == hAfter and "" or "  (changed)"))
	end
end

local function onSwi()
	local ret = u32(emu:readRegister("lr"))
	local kind, num, comment = decode(ret)

	if SKIP[num] or (HAS_ONLY and not ONLY[num]) then
		return
	end

	seq = seq + 1
	pending[#pending + 1] = {
		seq = seq, kind = kind, num = num, comment = comment, ret = ret,
		before = snapshot(), hashes = hashAll(),
	}
	if #pending > MAX_PENDING then
		table.remove(pending, 1)  -- calls that never return (SoftReset, Stop, ...)
	end

	if not afterBp[ret] then
		afterBp[ret] = true
		emu:setBreakpoint(function() finishCall(ret) end, ret)
	end
end

emu:setBreakpoint(onSwi, SWI_VECTOR)

log(string.format("-- swi-trace started (only=%s, skip=%s, hash=%s)",
	os.getenv("SWI_TRACE_ONLY") or "all", os.getenv("SWI_TRACE_SKIP") or "none",
	#HASH_DOMAINS > 0 and table.concat(HASH_DOMAINS, ",") or "none"))
