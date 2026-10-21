# Research Notes

This file records the research behind the decisions in the other documents. Each section names
the decision, the facts that support it, and the sources. The research was done in October 2026
with Zig 0.16.0 and Go 1.27.0 on macOS 26.6 arm64, with the `debugserver` from Xcode.

Facts marked "(unverified)" came from one source or from memory. Make sure that each one is true
before the code depends on it. Facts marked "(tested)" come from an experiment on the machine
above. The section "Verification log" at the end lists each experiment.

## Process control on macOS

On macOS, `ptrace` cannot read or write registers or memory. Debuggers use `ptrace` only for
`PT_ATTACHEXC` and `PT_CONTINUE`. The real work goes through Mach calls:

- `task_for_pid` gets the task port of the target process.
- `task_set_exception_ports` and a `mach_msg` receive loop catch breakpoint and step exceptions.
- `task_threads` lists the threads.
- `thread_get_state` and `thread_set_state` read and write `ARM_THREAD_STATE64` (general
  registers) and `ARM_DEBUG_STATE64` (debug registers).
- `mach_vm_read_overwrite`, `mach_vm_write`, `mach_vm_protect` and `mach_vm_region` access memory.

A native debugger needs the `com.apple.security.cs.debugger` entitlement and a code signature.
The target needs `get-task-allow` or no hardened runtime. Go and Zig sign their binaries ad-hoc
with no hardened runtime (tested).

- Without the entitlement, `task_for_pid` on a child process fails with `KERN_FAILURE` (5)
  (tested).
- With an ad-hoc signature (`codesign -s -`) and the entitlement, `task_for_pid` on a child
  process succeeds, with Developer Mode off and no prompt (tested). A paid certificate is not
  necessary.
- For a process that is not a child of ztack, Apple documents an administrator prompt for a
  user who is not root. The grant lasts 10 hours, and `DevToolsSecurity -enable` reduces the
  prompts (unverified, test in M5).

Delve, the Go debugger, does not use a native backend on macOS. Its default macOS backend starts
Apple `debugserver` and talks to it with the GDB remote serial protocol (`pkg/proc/gdbserial`).
Apple signs `debugserver`, so the debugger itself needs no entitlement. `pkg/proc/native` has
only `registers_darwin_amd64.go` for darwin, so Delve has no native darwin/arm64 backend.

`debugserver` details:

- The `g` packet (read all registers) returns an empty reply on arm64 (tested). An LLVM report
  from 2021 shows the same refusal. The `p` packet (read one register) works (tested).
- `qXfer:features:read:target.xml` returns the register layout (tested).
- A stop reply (`T` packet) carries the general registers of the stopped thread (tested).
- `jThreadsInfo` returns every thread with its registers in one reply (tested).
- `qSupported` reports `PacketSize=20000` (hex), `MultiMemRead+`, `jMultiBreakpoint+` and
  `SupportedWatchpointTypes=aarch64-mask,aarch64-bas` (tested).
- `QNonStop:1` returns an empty reply, so `debugserver` is all-stop only (tested). In
  `RNBRemote.cpp`, the `m` and `x` packets have no handler for a running target. Memory reads
  need a stopped target.
- After `c` (continue), a Go program stops at once with signal 16, which is SIGURG on macOS
  (tested). Go uses SIGURG for preemption. Pass it with `QPassSignals`.
- An arm64e target needs an arm64e `debugserver` (unverified).

On this machine, `debugserver` is at `LLDB.framework/Resources/debugserver` in two places
(tested):

- Command Line Tools: `/Library/Developer/CommandLineTools/Library/PrivateFrameworks/`
- Xcode: `/Applications/Xcode.app/Contents/SharedFrameworks/`

Decision: the first `target` backend is a GDB remote client to `debugserver` (M1). The native
Mach backend follows in M5, before the profiler. The sampler and live Go statistics need the
task port, and `debugserver` cannot read a running target.

Sources:

- https://llvm.googlesource.com/lldb/+/master/tools/debugserver/source/MacOSX/arm64/DNBArchImplARM64.cpp
- https://github.com/llvm/llvm-project/blob/main/lldb/tools/debugserver/source/RNBRemote.cpp
- https://steveindusteves.substack.com/p/a-macos-debugger
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger
- https://developer.apple.com/forums/thread/723044
- https://docs.godotengine.org/en/3.4/development/cpp/macos_debug.html
- https://github.com/go-delve/delve/blob/master/Documentation/usage/dlv_backend.md
- https://github.com/go-delve/delve/tree/master/pkg/proc/native
- https://lists.llvm.org/pipermail/lldb-dev/2021-April/016852.html

## Process control on Linux

- Attach with `PTRACE_SEIZE` and the options `TRACECLONE`, `TRACEFORK`, `TRACEVFORK`,
  `TRACEEXEC` and `EXITKILL`. Fork and clone events make child processes visible.
- Wait with `waitpid(-1, __WALL)`. Go creates many OS threads, so expect many clone events.
- Read memory with `process_vm_readv`. Write memory with `/proc/pid/mem` or `PTRACE_POKEDATA`.
- Read the memory map from `/proc/pid/maps`.
- Read `/proc/sys/kernel/yama/ptrace_scope` to explain permission errors to the user.
- Pass `SIGURG` through to the target. Go uses it for asynchronous preemption since Go 1.14.

## Breakpoints, stepping and watchpoints

- arm64 breakpoint: `BRK #0`, the 32-bit word `0xD4200000`, bytes `00 00 20 D4`. After a hit,
  the PC points at the `BRK` instruction itself.
- x86_64 breakpoint: `INT3`, the byte `0xCC`. After a hit, the PC is one byte past the
  breakpoint, so the debugger moves it back.
- With `debugserver`, the `Z0` and `z0` packets insert and remove a software breakpoint.
  `debugserver` keeps the original bytes.
- macOS code pages need `mach_vm_protect` with `VM_PROT_COPY` before a write (unverified, test in
  M5).
- macOS arm64 single step: set the SS bit in `__mdscr_el1` in `ARM_DEBUG_STATE64`.
- Linux single step: `PTRACE_SINGLESTEP`.
- To continue from a breakpoint: restore the original instruction, single-step only that thread,
  then write the breakpoint again.
- arm64 hardware watchpoints use the `DBGWVR<n>` and `DBGWCR<n>` registers. macOS exposes them
  in `ARM_DEBUG_STATE64`. `sysctlbyname("hw.optional.watchpoint")` gives the count: 4 on this
  machine. `hw.optional.breakpoint` gives 6 (tested).
- Step over (Delve model): set temporary breakpoints on every `is_stmt` row of the line table in
  the current function, on the return address, and on Go deferred calls. For Go, each temporary
  breakpoint has the condition "same goroutine", because other goroutines run the same code.
- A large function has hundreds of `is_stmt` rows. With `debugserver`, each breakpoint is one
  packet, so send them in one batch.
- Step into: stop at the first line of the callee after the prologue. DWARF 5 marks this with
  `prologue_end`. Skip Go runtime functions such as `morestack`.

Source: https://df.lth.se/~getz/ARM/SysReg/AArch64-dbgwvrn_el1.html

## Debug information

A debugger reads these DWARF sections:

- `.debug_info` and `.debug_abbrev`: functions, variables and types.
- `.debug_line`: the line table (address to source line).
- `.debug_frame` and `.eh_frame`: call frame information (CFI), the rules to unwind a stack.
- `.debug_loc` and `.debug_loclists`: variable locations as `DW_OP_*` expressions.
- DWARF 5 also adds `.debug_str_offsets`, `.debug_addr` and `.debug_rnglists`.

macOS also has `__TEXT,__unwind_info`, the Apple compact unwind format. A Zig binary has
`__unwind_info` and `__eh_frame`. A Go binary has only `__debug_frame` (tested). System libraries
depend on `__unwind_info`. `std.macho` defines its structures.

Zig on macOS:

- The executable contains no DWARF. It contains a debug map: `N_OSO` and `N_FUN` symbol table
  entries that point at object files in the Zig cache (tested).
- An `N_OSO` path can point into `~/.cache/zig/tmp/<hash>/`, or at an archive member in the
  form `libcompiler_rt.a(libcompiler_rt_zcu.o)` (tested).
- `dsymutil` makes a `.dSYM` bundle from the same object files. If an object file is missing,
  `dsymutil` cannot recover its DWARF either.
- The object files hold DWARF 4 (tested with `dwarfdump`).
- The Zig 0.16 aarch64 backend is not ready, so Debug builds on aarch64-macos use LLVM.
- The 0.16 self-hosted ELF linker does not write DWARF yet.
- `std.debug.Dwarf` is a useful reference, but its API is internal and changes between releases.
- ReleaseFast on aarch64-macos keeps frame pointers. Each function saves `x29` and `x30` and sets
  `x29` (tested). The Apple arm64 ABI requires a frame pointer.

Go:

- The Go linker writes DWARF into the `__DWARF` segment, compressed as `__zdebug_*` sections by
  default (tested). `-ldflags=-compressdwarf=false` turns compression off (tested). On ELF, Go
  keeps the `.debug_*` names and sets `SHF_COMPRESSED` (`cmd/link/internal/ld/dwarf.go`).
- `-gcflags=all="-N -l"` turns off optimization and inlining.
- Go adds its own attributes (`cmd/internal/dwarf/dwarf.go`): `DW_AT_go_kind` 0x2900,
  `DW_AT_go_key` 0x2901, `DW_AT_go_elem` 0x2902, `DW_AT_go_embedded_field` 0x2903,
  `DW_AT_go_runtime_type` 0x2904, `DW_AT_go_package_name` 0x2905, `DW_AT_go_dict_index` 0x2906,
  `DW_AT_go_closure_offset` 0x2907. `DW_AT_go_runtime_type` maps an interface value to its
  DWARF type.
- Go 1.25 made DWARF 5 the default, except on darwin, ios and aix. Older `dsymutil` cannot read
  `.debug_rnglists` (`internal/buildcfg/exp.go`). Go on macOS writes DWARF 4 (tested with Go
  1.27). Go on Linux writes DWARF 5.
- Go 1.24 introduced Swiss-table maps. Go 1.26 removed the old map implementation. The layout is
  in `internal/runtime/maps`.
- Go 1.27 turns on the Green Tea garbage collector and size-specialized malloc by default
  (`internal/buildcfg/exp.go`). Runtime structures change between releases, so read them by DWARF
  member name.
- Goroutine list (Delve): read `runtime.allgs` and `runtime.allglen`. For each `g`, read `goid`,
  `atomicstatus`, `stack.lo`, `stack.hi` and `sched` (pc, sp, bp, lr).
- The current goroutine on arm64 is in register R28 (`cmd/compile/abi-internal.md`). If `goid` is
  0, the thread runs on the system stack. Then follow `m.curg`.
- If a goroutine stack grows, the runtime moves it. Never cache a stack address across a resume.
- Unwinding crosses `systemstack`, `mcall` and `morestack` transitions.

Sources:

- https://ziglang.org/download/0.16.0/release-notes.html
- https://go.dev/doc/go1.25
- https://go.dev/doc/go1.26
- https://go.dev/src/cmd/link/internal/ld/macho_combine_dwarf.go
- https://go.dev/src/cmd/internal/dwarf/dwarf.go
- https://go.dev/src/internal/buildcfg/exp.go
- https://golang.google.cn/cmd/link/
- https://github.com/golang/go/blob/master/src/cmd/compile/abi-internal.md
- https://raw.githubusercontent.com/go-delve/delve/master/pkg/proc/variables.go

## Disassembly

| Option | arm64 | x86_64 | Notes |
|---|---|---|---|
| Capstone | yes | yes | C99, BSD-3-Clause, builds with `addCSourceFiles`. |
| Zydis | no | yes | C, MIT license, needs Zycore. |
| LLVM MC | yes | yes | C++ and very large. |
| Zig std | no | no | No disassembler in the 0.16 standard library (tested). |

Capstone 6.0 has no final release. The newest release is 6.0.0-Alpha11. Capstone 6 renamed the
ARM64 architecture to AArch64 (`CS_ARCH_AARCH64`). The repository also contains code derived from
LLVM, under Apache-2.0 with the LLVM exception.

Decision: vendor Capstone 6.0 at a pinned pre-release commit, for the AArch64 tables that come
from LLVM. Record the tag and the commit in `vendor/capstone/VERSION`. After 6.0.0 releases,
move to it.

Sources:

- https://github.com/capstone-engine/capstone/releases

## Memory and allocation tracking

Zig:

- `std.heap.DebugAllocator` and `std.testing.allocator` report leaks with stack traces.
- Zig passes allocators explicitly, so there is no global hook.
- Decision: a small package, `ztack_track`, wraps any `std.mem.Allocator`. The user program
  opts in. The wrapper sends allocation events to ztack.

C `malloc` on macOS:

- `DYLD_INSERT_LIBRARIES` with a `__DATA,__interpose` section replaces `malloc` and `free`.
  dyld ignores it for hardened or SIP-protected programs.
- `MallocStackLogging=1` with the `leaks` and `malloc_history` tools needs no code.
- On Linux, `LD_PRELOAD` does the same job.

Go:

- The Go heap does not use `malloc`.
- `runtime/pprof` heap profiles are sampled, one sample per 512 KB by default.
- `runtime.ReadMemStats` stops the world. `runtime/metrics` is cheaper.
- `GODEBUG=gctrace=1` prints one line per garbage collection to stderr. ztack reads these lines
  for heap size and pauses, with no stop and no task port.
- `runtime/trace` records an execution trace.
- A heap snapshot reads the runtime profile buckets at a stop. Their layout is not known yet
  (unverified, test in M7).

Leak definitions:

- Non-GC languages (Zig, C): memory that is not freed at exit or at `deinit`.
- GC languages (Go): memory that stays reachable but is not needed. The signs are a heap that
  grows between collections and a goroutine count that grows. Show differences between heap
  snapshots, not counts of memory that is not freed.

Sources:

- https://developer.apple.com/library/mac/releasenotes/DeveloperTools/RN-MallocOptions
- https://leancrew.com/all-this/man/man1/malloc_history.html

## Profiling and flame graphs

- macOS sampling: `task_threads`, then for each thread `thread_suspend`, `thread_get_state`,
  walk the frame pointers with `mach_vm_read_overwrite`, then `thread_resume`. This needs the
  task port, so it needs the entitlement.
- Never take a lock or allocate memory while a target thread is suspended. The target can hold
  the same lock, and the profiler then deadlocks.
- Go keeps frame pointers on amd64 and arm64. Go 1.21 notes that "the runtime now maintains the
  frame pointers for stack transitions" on amd64. The notes say nothing about arm64.
- Go on arm64 saves the frame pointer at -8(SP), below the link register at 0(SP)
  (`abi-internal.md`). Golang issue 69032 shows that this layout breaks naive backtraces through
  libc trampolines. The issue is open.
- Zig ReleaseFast keeps frame pointers on aarch64-macos (tested). On other targets, it can omit
  them (unverified). Use the unwind tables as the fallback.
- Linux: `perf_event_open` with `PERF_SAMPLE_CALLCHAIN`. `perf_event_paranoid` limits access.
- Output formats: pprof (gzipped `profile.proto`) and folded stacks (`a;b;c 123` per line).
- Per-process numbers on macOS: `proc_pid_rusage(pid, RUSAGE_INFO_V4)` gives the physical
  footprint and CPU times. The CPU times are Mach ticks. Convert them with `mach_timebase_info`,
  which is 125/3 on this machine (tested). `rusage_info_v4` has no thread count. Use
  `proc_pidinfo(PROC_PIDTASKINFO)` and `pti_threadnum` (tested).
- `proc_listchildpids` lists child processes. It returns a count of pids (tested).
- These calls work on a process of the same user with no entitlement (tested).
- Per-process numbers on Linux: `/proc/pid/stat`, `/proc/pid/status`, `/proc/pid/smaps_rollup`.

Sources:

- https://github.com/mstange/samply
- https://blog.sentry.io/building-a-performant-ios-profiler/
- https://bugzilla.mozilla.org/show_bug.cgi?id=1150252
- https://go.dev/doc/go1.21
- https://golang.org/issue/69032
- https://github.com/nushell/nushell/pull/6457
- https://www.brendangregg.com/blog/2016-04-30/linux-perf-folded.html
- https://opensource.apple.com/source/WTF/WTF-7609.2.9.0.5/wtf/spi/darwin/ProcessMemoryFootprint.h.auto.html

## Running tests

Zig:

- `zig test src/x.zig --test-no-exec -femit-bin=<path>` builds the test binary without a run
  (tested).
- In `build.zig`, `b.addTest` makes the same artifact. `addInstallArtifact` puts it at a known
  path.
- Run the binary directly. Under `zig build`, the test runner talks a binary protocol
  (`--listen=-`) to the build runner instead.
- `--test-filter` selects tests. Zig 0.16 adds `--test-timeout` to `zig build`, for example
  `zig build test --test-timeout 500ms`. `zig test` does not have it (tested).

Go:

- Build: `go test -c -o x.test -gcflags=all="-N -l" ./pkg`.
- Run: `./x.test -test.run '^TestName$' -test.v`. `dlv test` does the same.

Sources:

- https://ziggit.dev/t/build-tests-as-a-binary/8278
- https://ziggit.dev/t/running-tests-with-my-own-wrapper/6331/2

## Other debuggers

- RAD Debugger (Epic Games): layers form a one-way graph. `demon` controls processes, `ctrl`
  runs stepping and breakpoints, `dbg_engine` holds the logic, and `dbg_info` converts debug
  information in the background into its own indexed format (RDI). Render, font and UI layers
  sit on top. Lesson: convert DWARF in the background, and keep platforms behind one interface.
- uscope: a Linux-only Zig debugger. It is library-first, with a separate adapter layer.
- gf and Seer: small user interfaces on top of GDB. Lesson: a thin UI over an existing engine
  gives a usable tool quickly.
- Delve: `pkg/proc` controls the target, `service` exposes JSON-RPC and DAP, and a terminal
  client sits on top. Go knowledge lives in `pkg/proc`.

Sources:

- https://raw.githubusercontent.com/EpicGamesExt/raddebugger/master/README.md
- https://github.com/jcalabro/uscope
- https://github.com/nakst/gf
- https://ziggit.dev/t/hacking-lldb-for-a-great-zig-debugging-experience/13562

## GUI library

| Library | Zig 0.16 | Docking | C build in build.zig | Verdict |
|---|---|---|---|---|
| zgui (Dear ImGui) | yes | mature | yes | Primary choice. |
| dvui | yes | new, July 2026 | yes | Fallback. Pure Zig. |
| raylib + raygui | older commit only | no | yes | No docking. |
| Capy | no, targets 0.14 | no | yes | Not ready for production. |
| Mach | dev build only | no | yes | No UI toolkit. |
| SDL3 + own UI | yes | write it | yes | Months of work first. |
| Clay, microui, Nuklear | partial | no | yes | Too limited. |
| GTK4, Qt | poor | yes | no | System libraries, weak on macOS. |
| zig-objc + AppKit | yes | write it | n/a | macOS only. |

Decision: Dear ImGui with docking through `zig-gamedev/zgui`. ImGui gives the most mature
docking, `ImDrawList` for custom drawing, and `ImGuiListClipper` for very large text views. The
Tracy profiler uses Dear ImGui for the same kinds of views. The fallback is `dvui` on SDL3.

- zgui sets `minimum_zig_version` to 0.16.0 and uses the ImGui docking branch.
- dvui sets `minimum_zig_version` to 0.16.0. PR 931 added dockable panels, merged on 2026-07-17.
- Zig 0.17.0 released on 2026-10-01. zgui does not support it yet. Stay on 0.16.0 until zgui and
  dvui support 0.17.

Sources:

- https://ziglang.org/download/
- https://github.com/zig-gamedev/zgui
- https://github.com/zig-gamedev
- https://github.com/david-vanderson/dvui
- https://github.com/david-vanderson/dvui/pull/931
- https://github.com/floooh/sokol-zig
- https://github.com/raylib-zig/raylib-zig
- https://github.com/capy-ui/capy
- https://github.com/hexops/mach
- https://github.com/mitchellh/zig-objc

## TigerBeetle

TigerBeetle is the reference for code style and repository layout. The rules come from three
places. The first is `docs/TIGER_STYLE.md`. The second is the layout of `src/`. The third is the
last version of `src/tidy.zig`. Commit `2f45ef6` ("tidy: move", 2026-09-23) moved `tidy.zig` out
of the repository. `src/stdx/testing/snaptest.zig` is still on the main branch.

Sources:

- https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md
- https://github.com/tigerbeetle/tigerbeetle/tree/main/src
- https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/internals/HACKING.md
- https://github.com/tigerbeetle/tigerbeetle/commit/2f45ef6
- https://github.com/tigerbeetle/tigerbeetle/blob/2f45ef6d49084d8f6a1840eca2934bf6795b94fd~1/src/tidy.zig
- https://github.com/tigerbeetle/tigerbeetle/blob/main/src/stdx/testing/snaptest.zig
- https://github.com/tigerbeetle/tigerbeetle/blob/main/src/fuzz_tests.zig
- https://github.com/tigerbeetle/tigerbeetle/blob/main/src/scripts.zig
- https://github.com/tigerbeetle/tigerbeetle/blob/main/zig/download.sh
- https://github.com/tigerbeetle/tigerbeetle/blob/main/build.zig

## Verification log

The experiments ran on 2026-10-11 on macOS 26.6.2 (25G83), arm64, with Zig 0.16.0, Go 1.27.0
and the Xcode `debugserver`. Each item gives the method and the result.

1. `ls` on both `debugserver` paths. Both exist.
2. A raw GDB remote session with `debugserver` on a Go loop program. `g` is empty, `p` works,
   `jThreadsInfo` works, `QNonStop` is empty, and the target stops with signal 16.
3. `sysctl hw.optional`. `watchpoint: 4`, `breakpoint: 6`.
4. `grep` in the Go 1.27 source tree. DWARF attribute codes, DWARF 5 off on darwin, no
   `noswissmap` experiment.
5. `go build` with and without `-compressdwarf=false`, then `otool -l`. `__zdebug_info` by
   default, `__debug_info` without compression.
6. `dwarfdump --debug-info` on Go and Zig objects. DWARF version 4 for both.
7. `zig build-exe`, then `dsymutil -s`. `N_OSO` paths into `~/.cache/zig/tmp/`, and the archive
   member form.
8. `zig build-exe -O ReleaseFast`, then `otool -tV`. Each function saves and sets `x29`.
9. `otool -l` for unwind sections. Zig: `__unwind_info` and `__eh_frame`. Go: `__debug_frame`.
10. `grep` in Zig 0.16 `lib/std`. No disassembler. `std.macho` has compact unwind structures.
11. `zig test --help` and `zig build --help`. `--test-timeout` is only in `zig build`.
12. A C program calls `proc_pid_rusage`, `proc_pidinfo` and `proc_listchildpids` on a busy
    child. The ticks need the factor 125/3, `pti_threadnum` gives the thread count, and the
    child is listed.
13. The same program calls `task_for_pid` on the child, first unsigned, then ad-hoc signed with
    the entitlement. The result is `KERN_FAILURE` (5), then success.

Web checks in October 2026 covered the Delve backends, the Go 1.21, 1.25 and 1.26 notes, and
golang issue 69032. They also covered the Zig 0.16 notes, Zig 0.17, zgui, dvui, the TigerBeetle
commit and the Capstone releases. The sources are in the sections above. Two citations were
wrong and are removed: Delve issues 1112 and 2277 are not about SIGSEGV.
