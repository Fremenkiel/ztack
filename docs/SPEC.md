# Product Specification

ztack is a standalone GUI debugger for Go and Zig programs, written in Zig. It runs on macOS arm64
first and on Linux later. This document defines what ztack does, for whom, and in what order.

## Problem

Developers often find bugs with print statements. They add a print, rebuild, run, read the output,
and repeat. Each round costs a build and a run. Existing debuggers are faster in theory, but they
are slow to start, hard to learn, or weak for Go and Zig.

ztack makes the debugger the faster path. It starts in under a second, needs no configuration
file, and shows the state of the program in one window.

## Users

The first user is a developer who writes Go and Zig on a Mac. The user knows the language well.
The user does not want to learn debugger commands.

## Goals

The goals are in priority order. If two goals conflict, the higher goal wins.

1. Correct. ztack never shows a wrong value. If ztack cannot read a value, it says so.
2. Fast. ztack starts in under one second. A step shows the new state in under 50 ms. The UI
   draws at the display refresh rate.
3. Simple. A new user sets a breakpoint and inspects a variable in the first minute, with no
   documentation.

Each feature must answer the question "where is the bug" faster than a print statement. If a
feature does not, it is not part of ztack.

## Non-goals for version 1

- Windows.
- Remote debugging over a network.
- Reverse execution (running the program backward).
- Expression evaluation beyond field access, index access and pointer dereference.
- A Debug Adapter Protocol (DAP) server for editors.
- Editor plugins.
- Languages other than Go and Zig. C code linked into a Zig program is supported at the level of
  source lines, symbols and raw memory.

## Concepts

- Target: the program that ztack debugs.
- Session: one run of a target from launch to exit.
- Stop: a pause of all threads of the target. A breakpoint, a step, a signal or a pause request
  causes a stop.
- Snapshot: the state that the engine reads at a stop. The UI shows only snapshots.

## Features

### Launch

- Launch a program with arguments, environment variables and a working directory.
- Launch a single Zig test or Go test from a list.
- Attach to a running process (M5, needs the native backend).
- Remember the last launch configuration for each project directory.

Zig tests. ztack builds the test binary and then runs it under the debugger:

```
zig test <file> --test-no-exec -femit-bin=<path> --test-filter <name>
```

For a project that uses `zig build`, ztack uses the test artifact from `b.addTest` instead.
After the build, ztack runs `dsymutil` on the test binary. The debug map of a Zig binary points
into the Zig cache, and the `.dSYM` bundle keeps the debug information after a cache clean.

Go tests. ztack builds the test binary with optimization and DWARF compression turned off:

```
go test -c -o <path> -gcflags=all="-N -l" -ldflags=-compressdwarf=false ./pkg
<path> -test.run '^TestName$' -test.v
```

To list tests, ztack reads the test functions from the source files. Zig tests are `test` blocks.
Go tests are functions whose names start with `Test` in `_test.go` files.

### Run control

- Continue, pause, restart and kill.
- Step over, step into and step out, by source line.
- Step by instruction, in the disassembly view.
- Run to the line under the cursor.

### Breakpoints

- Breakpoints by file and line, set by a click in the source view.
- Breakpoints by function name.
- Enable, disable and delete. Show the hit count of each breakpoint.
- Conditional breakpoints with a simple comparison (later milestone).
- Hardware watchpoints: if the program writes to a watched address, the target stops.

### Inspect

- Call stack of the current thread. A click on a frame shows its source and variables.
- Thread list. For Go, a goroutine list with the state and the current function of each
  goroutine.
- Locals and arguments as an expandable tree. Values that changed since the last stop are marked.
- Registers, with changed registers marked.
- Language-aware values:
  - Go: strings, slices, maps, interfaces, channels, pointers, structs.
  - Zig: slices, optionals, error unions, tagged unions, enums, packed structs.

### Machine view

- Disassembly beside the source, with source lines between the instruction groups.
- Static disassembly from the binary before the program runs.
- Live disassembly during the run, with the current instruction marked.
- Memory view: a hex and ASCII view of any address range. The view names the region of each
  address (stack, heap, code, data, mapped file).
- A click on a pointer value opens the memory view at that address.

### Performance

- Per-process numbers for the main process and each child process: CPU time, CPU percent,
  physical memory footprint, peak footprint and thread count. Numbers update while the program
  runs.
- A process tree that shows each child process.
- Sampling profiler: start and stop from the toolbar. The default rate is 1000 samples per
  second per thread.
- Flame graph of the samples, with zoom and search.
- Export to pprof and to folded stacks.

### Memory and allocations

A leak means something different in each language family. ztack uses two definitions.

- Non-GC languages (Zig, C): an allocation that the program does not free before exit or before
  the allocator `deinit`.
- GC languages (Go): memory that stays reachable but that the program does not need. A garbage
  collector frees unreachable memory, so ztack looks for growth, not for memory that is never
  freed.

Zig programs:

- The program imports the small `ztack_track` package and wraps its allocator. This is a one-line
  change for the user.
- ztack shows an allocation timeline, live allocations grouped by call site, and a leak report at
  exit.

C allocations in Zig programs:

- ztack loads an interposer library with `DYLD_INSERT_LIBRARIES`. The library records `malloc`,
  `calloc`, `realloc` and `free`.

Go programs:

- ztack reads Go runtime memory statistics and heap profiles.
- ztack shows heap size over time, garbage collection pauses, and the goroutine count.
- ztack compares two heap snapshots and lists the call sites whose memory grew.

## Milestones

Each milestone ends with a working tool. Each milestone has a short demo that the tests repeat.

- M0 Foundation. Pinned Zig, tidy checks, GUI spike, empty docked layout.
  Demo: three docked panels and a 1M-line scroll at 120 Hz.
- M1 Run and stop. `debugserver` backend, launch, line breakpoints, continue, source view.
  Demo: stop at a line in a Zig program and in a Go program.
- M2 Step and inspect. Step over, into and out. Call stack. Locals tree. Registers.
  Demo: step through a loop and see a counter change.
- M3 Go and Zig awareness. Goroutines, Go and Zig value printing, test launch.
  Demo: debug one Go test and one Zig test.
- M4 Machine view. Disassembly, memory view, watchpoints.
  Demo: follow a pointer from a variable into memory.
- M5 Native macOS. Native Mach backend, ad-hoc signing with the debugger entitlement, attach.
  `debugserver` stays as the fallback.
  Demo: the M1 to M4 demos with the native backend.
- M6 Performance. Process numbers, child processes, sampler, flame graph, export.
  Demo: find the hot function in a test program.
- M7 Memory. `ztack_track`, malloc interposer, Go heap views, leak report.
  Demo: find a planted leak in a Zig program and in a Go program.
- M8 Linux. Linux ptrace backend, ELF, DWARF 5.
  Demo: the M1 to M7 demos on Linux x86_64.

## Constraints

- Language: Zig 0.16.0, pinned. ztack changes Zig version only in a dedicated change.
- Platforms: macOS 14 or later on arm64. Linux x86_64 and arm64 from M8.
- Target languages: Go 1.25 or later, Zig 0.16.0 or later.
- Dependencies: only the approved list in `DEPENDENCIES.md`.
- No installation step except the binary. On macOS, Xcode or the Command Line Tools supply
  `debugserver`, `dsymutil` and `codesign`.
- From M5, the build signs ztack ad-hoc (`codesign -s -`) with the
  `com.apple.security.cs.debugger` entitlement. The sampler and the native backend need it. A
  paid developer certificate is not necessary.

## Success measures

- Time from start to the first breakpoint hit: under 2 seconds for a 10 MB binary.
- Step latency, from key press to updated UI: under 50 ms.
- Debug information load for a 100 MB Go binary: under 3 seconds in the background. The UI stays
  responsive during the load.
- No wrong value in the value-printing snapshot tests.
