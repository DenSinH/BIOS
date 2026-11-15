# gba-bios

A Game Boy Advance replacement BIOS. Written completely in ARM assembly from scratch.

![Boot Screen](screenshot.png)

### Accuracy

This is mostly a fun project by two programmers, therefore high accuracy is a non-goal.\
But we aim to make it compatible with most commercial games.

### Debugging / testing

In the `flake.nix` a default devShell is defined, with a utility script using mGBA to allow tracing SWIs.
You can use this to compare SWI calls from the built BIOS with another reference BIOS.
For example, run
```bash
SWI_TRACE_OUT=ours.log run-gba -b bios.bin /path/to/game.gba /path/to/savestate.ss1 --trace
```
or 
```bash

```

### TODO

- implement remaining BIOS calls (mainly sound functions)
- handle attempts to read BIOS memory in all BIOS calls
- test BIOS against more games / fix bugs
