# Architecture

This document describes how ztack is built: the layers, the threads, and the approach to each hard
problem. `RESEARCH.md` has the sources. `DATA_MODEL.md` has the types.

## Layers

ztack has seven modules. Each module is one file plus one directory with the same name. Imports go
in one direction only, from top to bottom:

```
ui
 └─> engine
      ├─> target       Process control. Backends: gdb_remote, darwin, linux, fake.
      ├─> debug_info   Mach-O, ELF, DWARF 4 and 5, Go and Zig specifics.
      ├─> disasm       Capstone wrapper.
      ├─> profile      Sampler, process numbers, flame graph model, export.
      └─> alloc_trace  Events from ztack_track and the malloc interposer.
launch                 Builds programs and test binaries. Used by engine.
stdx                   Shared helpers. Every module can import it.
constants              Limits and sizes. Every module can import it.
```

Rules:

- A lower layer never imports a higher layer. `target` does not know `engine` exists.
- `debug_info`, `disasm` and `profile` do not import `target`. They work on bytes and addresses.
  This keeps them testable with files on disk.
- `ui` never calls `target` or `debug_info` directly. It reads engine snapshots and sends engine
  commands.
- Only `target` and `profile` contain operating system calls. All other modules are portable.

## Threads

```
UI thread  ──commands──>  engine thread  ──requests──>  worker threads
           <─snapshots──                 <─results───   (debug info, sampler)
```

- UI thread. It draws frames and handles input. It never blocks on the target.
- Engine thread. It owns the target and the session state. It runs one command to completion,
  then publishes a new snapshot.
- Worker threads. They load debug information and run the sampler.

The threads talk through bounded queues of messages. A full queue is an error that ztack reports,
not a reason to block. The engine publishes each snapshot as an immutable value with a sequence
number. The UI holds the newest snapshot and never changes it. Three snapshot arenas take turns,
so the engine never waits for the UI (see `DATA_MODEL.md`).

This design follows TigerBeetle: batch work, and never react directly to external events. It also
follows RAD Debugger: the control layer is separate from the UI.

## target

`target` is the process control interface. One interface has several backends:

```zig
pub const Target = union(enum) {
    gdb_remote: *GDBRemote,
    darwin: *Darwin,
    linux: *Linux,
    fake: *Fake,
};
```

A tagged union (not a vtable) keeps calls direct and lets `switch` find a missing backend at
compile time. Each backend implements the same functions:

- `launch`, `attach`, `kill`, `detach`.
- `resume` (all threads or one thread), `step_instruction`, `wait` (returns a stop event).
- `registers_read`, `registers_write`.
- `memory_read`, `memory_write`, `memory_regions`.
- `breakpoint_insert`, `breakpoint_remove`, `watchpoint_insert`, `watchpoint_remove`.
- `threads`, `children`.

Backends, in build order:

1. `gdb_remote` (M1). A client for the GDB remote serial protocol. It starts Apple
   `debugserver` and talks to it over a local socket. Apple signs `debugserver`, so this backend
   needs no entitlement and no code signature on ztack. Delve uses the same approach on macOS.
2. `fake` (M1). An in-memory target for tests. It replays recorded stop events and memory
   images. Engine tests run with it, so most tests do not start a real process.
3. `darwin` (M5). The native Mach backend. It uses `task_for_pid`, exception ports,
   `thread_get_state` and `mach_vm_read_overwrite`. It needs the `com.apple.security.cs.debugger`
   entitlement. `build.zig` signs ztack ad-hoc (`codesign -s -`) with that entitlement. A paid
   certificate is not necessary. From M5, `darwin` is the default macOS backend. `gdb_remote`
   stays as the fallback, for example for an unsigned build.
4. `linux` (M8). The ptrace backend. It uses `PTRACE_SEIZE` with fork, clone and exec tracing.

`gdb_remote` rules, from tests against the Xcode `debugserver` (see `RESEARCH.md`):

- `debugserver` is all-stop. It has no non-stop mode. It reads memory only while the target is
  stopped.
- The `g` packet (all registers) returns an empty reply on arm64. Read the register layout with
  `qXfer:features:read:target.xml`.
- At a stop, take registers from the stop reply, which sends the general registers of the
  stopped thread. Take the other threads from one `jThreadsInfo` packet. Use `p` only for a
  register that neither reply sent.
- Read memory in large blocks. One `x` packet can return up to `PacketSize` (0x20000) bytes.
  Use `MultiMemRead` to read several ranges in one round trip.
- Insert and remove breakpoints with `Z0` and `z0`. `debugserver` writes the trap, keeps the
  original bytes, and steps over a hit breakpoint. It also hides its traps in memory reads (to
  test in M1). Send many breakpoints in one batch: `jMultiBreakpoint`, or pipelined packets in
  no-ack mode.
- At launch, send `QPassSignals` with SIGURG (signal 16 on macOS). Go uses SIGURG for
  preemption, and without this a Go target stops at once.

Child processes. Each backend reports fork and exec events. The engine adds each child to the
process tree. On macOS with `debugserver`, ztack follows children with one `debugserver` per
process. Profile numbers for children come from `proc_listchildpids`, `proc_pid_rusage` and
`proc_pidinfo`, which do not need a debugger connection or an entitlement.

## debug_info

`debug_info` reads executables and debug information. It owns its parsers. It does not use
`std.debug.Dwarf`, because that API is internal to the Zig standard library and changes between
releases.

Input formats:

- Mach-O executables and object files. For Zig on macOS, the executable has no DWARF. It has a
  debug map: `N_OSO` entries that name object files, and `N_FUN` entries that give addresses.
  ztack reads DWARF from each object file and moves the addresses with the debug map. An `N_OSO`
  path can name an archive member, in the form `lib.a(member.o)`.
- Object files of the debug map live in the Zig cache, some under `~/.cache/zig/tmp/`. If an
  object file is missing, its functions have no debug information, and ztack tells the user to
  rebuild. `dsymutil` cannot help then, because it reads the same object files. If ztack builds
  the binary itself, it runs `dsymutil` right after the build and reads the `.dSYM` bundle.
- Go executables. ztack reads the `__DWARF` segment. By default the Go linker compresses the
  sections (`__zdebug_*`). ztack decompresses them with `std.compress.flate`.
- ELF executables (M8). Go on Linux compresses sections with `SHF_COMPRESSED` and keeps the
  `.debug_*` names.
- DWARF versions 4 and 5. On macOS, both Go 1.27 and Zig 0.16 write DWARF 4, so DWARF 4 comes
  first. DWARF 5 is needed for Go on Linux (M8).
- Unwind tables: `__unwind_info` (Apple compact unwind), `__eh_frame` and `__debug_frame`. Go
  binaries on macOS have only `__debug_frame`. System libraries depend on `__unwind_info`.

ztack maps each binary and object file read-only. Uncompressed sections are read in place. Only
decompressed data is copied into the image arena.

Conversion. A worker thread converts the input into an indexed form that ztack owns:

- Address to line: a sorted array of 4-byte address offsets and a parallel array of rows.
  Lookup is a binary search over the offsets.
- Line to addresses: for each file, a sorted array of (line, row index) pairs, for `is_stmt`
  rows only.
- Symbols: sorted parallel arrays of address offsets, sizes and names.
- Types: a flat array of 24-byte `Type` values that refer to each other by `TypeId`.
- Variables: parsed on demand per function, because most functions are never inspected.

Each image has its own string table and arena. The worker thread is the only writer of an image.
After it completes the tables, it publishes them. The engine reads them with no lock.

The UI shows source and symbols as soon as the line table is ready. Types and variables load
later. Later, the converted form can go into a cache file keyed by the binary hash.

Language support lives in `debug_info/go.zig` and `debug_info/zig.zig`:

- Go: goroutine list from `runtime.allgs`, current goroutine from register x28 on arm64,
  interface types from `DW_AT_go_runtime_type` (0x2904), and the layout of strings, slices and
  maps. Maps use the Swiss-table layout from `internal/runtime/maps`.
- Go runtime structures (`g`, `m`, maps, heap statistics) change between releases. ztack finds
  each field by its DWARF member name. It never uses a fixed offset.
- Zig: the layout of slices, optionals, error unions and tagged unions, and error names from the
  error set.

## engine

The engine owns the session. It turns user commands into target operations.

Breakpoints. The engine keeps the user breakpoints and their sites (see `DATA_MODEL.md`). It
asks the target to insert or remove a site. The target writes the trap instruction:

- With `gdb_remote`, `debugserver` writes the trap and steps over it on resume.
- A native backend writes the trap itself. arm64: `BRK #0` (`0xD4200000`). After a hit, the PC
  points at the breakpoint. x86_64: `INT3` (`0xCC`). After a hit, move the PC back by one byte.
- A native backend continues from a breakpoint like this: restore the original instruction, step
  one instruction on that thread only, write the breakpoint again, then resume all threads.

Step over:

1. Find the function that contains the PC.
2. Put a step site on each `is_stmt` line row in that function, except the current line.
   Insert all sites in one batch.
3. Put a step site on the return address.
4. For Go, give each step site the condition "same goroutine ID".
5. Resume. At the first hit that matches the condition, remove all step sites in one batch.

A large function has hundreds of `is_stmt` rows. The batch keeps a step under the 50 ms target.
M2 measures it.

Step into: step instructions until the PC enters a new function. Then run to the first line row
after the prologue (`prologue_end` in DWARF 5). Skip Go runtime functions such as `morestack`.

Step out: put a step site on the return address of the current frame and resume.

Unwinding:

1. Walk frame pointers first. The Apple arm64 ABI keeps frame pointers, so Go and Zig keep them
   on macOS arm64, also in ReleaseFast builds.
2. If the PC of frame 0 is in a prologue or in a leaf function, the link register holds the
   return address. The frame record does not hold it yet.
3. If a frame has no valid frame pointer, use the unwind tables in this order: `__unwind_info`,
   `.eh_frame`, `.debug_frame`.
4. Go on arm64 saves the frame pointer at -8(SP), below the link register at 0(SP). The Go
   unwinder handles this.
5. Go unwinding crosses the `systemstack`, `mcall` and `morestack` transitions.

Every unwind loop has a frame limit (default 1024). If the walk reaches the limit, the call stack
ends with a "truncated" marker.

Values. The engine reads the bytes of a variable at a stop and stores them in the snapshot with
the type. The UI formats the value from the bytes. If the user expands a value, the engine reads
its children (struct fields, slice items, map entries). It does not read them before. The
values of a snapshot form one flat tree, and their bytes sit in one buffer. If ztack cannot read
a value, the value has the status `unreadable`, and the UI says "cannot read".

## disasm

`disasm` wraps Capstone. It decodes a byte range at an address into instructions with text,
length, and branch targets. The engine combines this with the line table to show source lines
between instruction groups. Static disassembly reads bytes from the file. Live disassembly reads
bytes from target memory and hides the bytes of ztack breakpoints.

## profile

Process numbers:

- macOS: `proc_pid_rusage(pid, RUSAGE_INFO_V4)` for CPU time and memory footprint,
  `proc_pidinfo(PROC_PIDTASKINFO)` for the thread count, `proc_listchildpids` for children. CPU
  times are Mach ticks. Convert them with `mach_timebase_info` (125/3 on Apple Silicon). These
  calls need no entitlement for a process of the same user.
- Linux: `/proc/pid/stat`, `/proc/pid/status` and `/proc/pid/smaps_rollup`.

Sampler, on a worker thread. It needs the task port of the target, so on macOS it uses the
`darwin` backend (M5) and its entitlement. `debugserver` cannot do this job, because it reads
memory only while the whole target is stopped.

1. For each thread: suspend, read registers, walk frame pointers, resume.
2. Store the stack as a `StackId` in the stack intern table, with the thread and the time.
3. While a thread is suspended, never allocate and never take a lock. The suspended thread can
   hold the same lock.

The sampler stores raw samples. The flame graph and both export formats (pprof and folded stacks)
come from the raw samples.

## alloc_trace

Allocation events come from two producers:

- `ztack_track`, a Zig package in `lib/ztack_track/`. It wraps any `std.mem.Allocator`. The user
  program opts in.
- A malloc interposer dylib, loaded with `DYLD_INSERT_LIBRARIES` on macOS and `LD_PRELOAD` on
  Linux.

Both producers write records into a shared-memory ring buffer. A record has a 32-byte header
(event kind, frame count, address, size, time stamp) and then the return addresses, at most 32.
A free event has no return addresses. Many threads of the target write at the same time, so a
producer reserves space with one atomic add. ztack reads the ring on a worker thread and interns
the stacks. If the ring is full, the producer counts a dropped event. ztack shows the drop count.

ztack keeps live allocations in a map keyed by address and adds each free to a per-site total.
Memory then grows with the live allocations, not with the count of events.

For Go, ztack does not track single allocations:

- Heap size and garbage collection pauses come from `GODEBUG=gctrace=1`. The runtime writes one
  line per collection to stderr. ztack reads these lines from the target output and does not
  stop the target.
- Live numbers between collections come from runtime memory, read with the task port (M5).
- A heap snapshot comes from the runtime profile buckets, read at a stop. Two snapshots give the
  call sites whose memory grew.

## launch

`launch` builds and starts targets:

- Programs: path, arguments, environment, working directory.
- Zig tests: `zig test --test-no-exec -femit-bin=<path>` or the `b.addTest` artifact. After the
  build, ztack runs `dsymutil` on the binary, so the debug information survives a cache clean.
- Go tests: `go test -c` with `-gcflags=all="-N -l"` and `-ldflags=-compressdwarf=false`.
- Go programs and tests run with `GODEBUG=gctrace=1` added to the environment, for the heap view.
  If the user sets `GODEBUG`, ztack appends `gctrace=1` to the value.
- Test lists: Zig `test` blocks and Go `Test*` functions found in the source files.

## ui

The UI uses Dear ImGui with docking, through `zgui`. Each panel is one file in `src/ui/panels/`.

Panel rules:

- A panel reads one snapshot and returns a list of commands. It holds only view state, such as
  scroll position and expanded tree nodes.
- No debugger logic in a panel. If two panels need the same derived data, the engine computes it.
- Large lists (source lines, disassembly, memory rows) draw only the visible rows with
  `ImGuiListClipper`.
- The source view is a custom read-only text view on `ImDrawList`, with its own line cache.
- The flame graph, the timelines and the memory view draw on `ImDrawList`.

Panels: source, disassembly, call stack, threads and goroutines, variables, registers, memory,
breakpoints, processes, flame graph, allocations, output (target stdout and stderr).

The UI library sits behind these rules. If ImGui stops being a good fit, only `src/ui/` changes.

## Errors

- Target errors (process exited, permission denied, `debugserver` missing) go to the UI as
  events with a message that tells the user what to do.
- Debug information errors are local. A broken compile unit marks its functions as "no debug
  information". The rest of the program still works.
- A failed assertion in ztack is a bug in ztack. ztack crashes with a stack trace. It does not
  try to continue in a broken state.
