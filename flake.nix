{
  description = "GBA replacement BIOS dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    
    devkitNix = {
      url = "github:bandithedoge/devkitNix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mgba-src = {
      url = "github:mgba-emu/mgba";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      devkitNix,
      mgba-src,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ devkitNix.overlays.default ];
        };

        # compile mGBA ourselves to get --script support
        mgba = pkgs.mgba.overrideAttrs (_: {
          version = "master";
          src = mgba-src;
        });

        # run-gba ROM [SAVESTATE] [--trace] [extra mgba args...]
        runGba = pkgs.writeShellApplication {
          name = "run-gba";
          runtimeInputs = [ mgba pkgs.git ];
          text = ''
            if [ $# -lt 1 ]; then
              echo "usage: run-gba ROM.gba [SAVESTATE] [--trace] [extra mgba args...]" >&2
              echo "  GBA_BIOS=/path/to/official.bin   use another BIOS" >&2
              echo "  SWI_TRACE_OUT / _ONLY / _SKIP / _HASH   see tools/swi-trace.lua" >&2
              exit 1
            fi

            root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            rom=$(realpath "$1"); shift

            args=()
            if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
              args+=(-t "$(realpath "$1")"); shift
            fi

            extra=()
            for a in "$@"; do
              case "$a" in
                --trace) extra+=(--script "${tools/swi-trace.lua}") ;;
                *) extra+=("$a") ;;
              esac
            done

            export SWI_TRACE_OUT="''${SWI_TRACE_OUT:-$root/swi-trace.log}"

            (cd "$root" && sh ./make.sh)

            exec "''${MGBA_BIN:-mgba-qt}" -b "''${GBA_BIOS:-$root/bios.bin}" \
              "''${args[@]}" "''${extra[@]}" "$rom"
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.devkitNix.devkitARM pkgs.mgba runGba ];
          env = rec {
            DEVKITPRO = "${pkgs.devkitNix.devkitARM}/opt/devkitpro";
            DEVKITARM = "${DEVKITPRO}/devkitARM";
          };
        };

        packages.default = pkgs.devkitNix.stdenvARM.mkDerivation {
          name = "gba-bios";
          src = ./.;
          buildPhase = ''
            runHook preBuild
            sh ./make.sh
            runHook postBuild
          '';
          installPhase = ''
            install -Dm644 bios.bin $out/bios.bin
          '';
        };
        formatter = pkgs.nixfmt-tree;
      }
    );
}
