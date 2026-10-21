# Repository Layout

This document fixes where code goes, how files are named, how code is ordered inside a file, and
where tests live. The layout follows TigerBeetle. `STYLE.md` covers the code itself.

## Folder structure

```
build.zig                Build steps only. No imports from src/.
build.zig.zon            Dependencies from DEPENDENCIES.md only.
zig/download.sh          Downloads the pinned Zig 0.16.0 and makes sure the SHA-256 matches.
docs/                    Specification, architecture, data model, style, layout.
src/
  main.zig               Entry point. main() comes first.
  constants.zig          All limits and sizes (counts, budgets, timeouts).
  unit_tests.zig         Imports every file that has tests.
  integration_tests.zig  Tests that build and debug real programs from testdata/.
  fuzz_tests.zig         Registry of all *_fuzz.zig files.
  scripts.zig            One binary for all scripts: tidy, ci, fixtures.
  stdx.zig  stdx/        Extended standard library: bounded arrays, queues, interning.
  target.zig  target/    gdb_remote.zig, darwin.zig, linux.zig, fake.zig
  debug_info.zig  debug_info/
                         macho.zig, elf.zig, debug_map.zig, compact_unwind.zig,
                         go.zig, zig.zig
                         dwarf/ info.zig, line.zig, frame.zig, expression.zig
  disasm.zig  disasm/    capstone.zig
  engine.zig  engine/    session.zig, breakpoints.zig, stepping.zig, unwind.zig, values.zig
  profile.zig  profile/  sampler.zig, rusage.zig, flame_graph.zig, pprof.zig, folded.zig
  alloc_trace.zig  alloc_trace/
                         ring.zig, interposer.zig
  launch.zig  launch/    program.zig, zig_test.zig, go_test.zig
  ui.zig  ui/            app.zig, theme.zig, text_view.zig, panels/
  scripts/               tidy.zig, ci.zig, fixtures.zig
  testing/               snapshot.zig, fixtures.zig, fake target recordings
lib/ztack_track/         Tracking allocator package. User programs import it.
testdata/zig/            Small Zig programs that the integration tests build and debug.
testdata/go/             Small Go programs that the integration tests build and debug.
vendor/capstone/         Vendored C source, with its license file.
```

Do not add a top-level folder without a change to this document.

## Modules

- A module is a file plus a directory with the same name, for example `engine.zig` and
  `engine/`. A small module can be one file with no directory.
- The module file is the public API. It re-exports the types that other modules use:
  `pub const Session = @import("engine/session.zig");`.
- Other modules import only the module file: `@import("engine.zig")`. They never import
  `engine/session.zig` directly.
- Files inside a module can import each other.
- The dependency direction in `ARCHITECTURE.md` is a rule. The tidy step rejects an import that
  goes up a layer.

## File names

- Every file name is `snake_case.zig`, also for a file that is a struct.
- A file that is a struct (file-as-struct) starts with its fields and has
  `const Name = @This();`. Other files import it as `const Name = @import("name.zig");`.
- Name a file after its main type or its job: `session.zig`, `line.zig`, `pprof.zig`.
- Do not use generic names such as `utils.zig`, `helpers.zig`, `common.zig` or `types.zig`. If
  code has no clear home, the design is not finished.

## Order inside a file

Put important things near the top. Use this order:

1. A `//!` comment that says what the file is for.
2. Imports, in this order: `std`, `builtin`, `assert`, `stdx`, `constants`, other modules, files
   in the same module. Then short aliases, such as `const log = std.log.scoped(.engine);`.
3. Public constants of the file.
4. The main type: fields, then nested types, then `const Name = @This();`, then methods.
5. Other public types and functions, each followed by its own methods.
6. Private helper functions.
7. Tests.

Rules for types and functions:

- A type comes before the functions that use it.
- A struct and its methods stay in one file. Do not spread the methods of one type over files.
- In a struct, the order is fields, types, then methods. `const Name = @This();` ends the types.
- Methods go in lifecycle order: `init`, `deinit`, then the main operations, then queries.
- If a nested type grows past about 50 lines or gets its own tests, move it to its own file.
- In an entry-point file, `main` comes first.
- If no other rule decides the order, sort alphabetically.

Example:

```zig
//! Breakpoint table for one session. Maps source lines to target addresses.

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("../stdx.zig");
const constants = @import("../constants.zig");
const target = @import("../target.zig");

breakpoints: stdx.BoundedArrayType(Breakpoint, constants.breakpoint_count_max),
id_next: u32,

pub const Breakpoint = struct {
    // Fields, then methods of Breakpoint.
};

const Breakpoints = @This();

pub fn init(breakpoints: *Breakpoints) void {
    // ...
}

pub fn insert(breakpoints: *Breakpoints, location: SourceLocation) !BreakpointId {
    // ...
}

fn address_index(breakpoints: *const Breakpoints, address: u64) ?u32 {
    // ...
}

test "Breakpoints: insert maps one line to every address" {
    // Explains what the test does and how.
}
```

## Tests

### Unit tests

- Unit tests are inline `test` blocks at the end of the file they test.
- Name each test after the type or function, then the behavior:
  `test "LineTable: lookup returns the row before the address"`.
- `src/unit_tests.zig` imports every file that has tests. The tidy step makes sure that no file
  with tests is missing from it.
- Unit tests do not start processes, read the network or depend on the time of day.

### Fuzz tests

- A fuzzer is a sibling file named `<file>_fuzz.zig`, for example `dwarf/line_fuzz.zig`.
- Each fuzzer exports `pub fn main(gpa: std.mem.Allocator, args: FuzzArgs) !void`.
- `src/fuzz_tests.zig` registers each fuzzer by name.
- Every parser of untrusted input has a fuzzer: Mach-O, ELF, DWARF, compact unwind, GDB remote
  packets, Go runtime structures, `ztack_track` records.

### Snapshot tests

- Snapshot tests compare output text with expected text that lives in the test source. They
  follow the TigerBeetle `snaptest` approach.
- If `SNAP_UPDATE=1` is set, the test writes the new output into the source file.
- Use snapshot tests for DWARF dumps, disassembly, value printing and flame graph folding.

### Integration tests

- Integration tests live in `src/integration_tests.zig` and in files that it imports.
- They build a program from `testdata/`, debug it, and compare the results with snapshots.
- They use the `gdb_remote` backend on macOS. Engine tests that do not need a real process use
  the `fake` backend instead.
- Each program in `testdata/` is small and has one purpose, for example
  `testdata/zig/leak_one_allocation.zig` or `testdata/go/goroutines_blocked/main.go`.

### Benchmarks

- A benchmark is a sibling file named `<file>_benchmark.zig`.
- Benchmarks measure the success numbers in `SPEC.md`, such as debug information load time.

There are no `test/` or `tests/` directories in `src/`.

## Build steps

`build.zig` declares every step at the top, in one place:

| Step | Purpose |
|---|---|
| `run` | Build and start ztack. |
| `test` | All unit tests, integration tests and tidy. |
| `test:unit` | Unit tests only. |
| `test:integration` | Integration tests only. |
| `test:tidy` | Mechanical style rules. |
| `test:fmt` | Make sure that `zig fmt --check` passes. |
| `fuzz` | Run one fuzzer by name. |
| `scripts` | Run a script from `src/scripts.zig`. |
| `ci` | Every step that CI runs. |

`build.zig` stays short. Logic goes into `src/scripts/`. From M5, the `run` and `install` steps on
macOS sign ztack ad-hoc with the debugger entitlement. `build.zig` has a `comptime` assertion that
stops the build on any Zig version other than 0.16.0.

## Tidy checks

`src/scripts/tidy.zig` runs as part of `zig build test`. It reads every file that git tracks and
enforces these rules:

- No line over 100 columns, except lines that contain a URL. `vendor/` is exempt.
- No trailing whitespace, no tabs, no carriage returns.
- No banned constructs from `STYLE.md`.
- No function over 70 lines. Each existing exception is on a list that can only shrink.
- No private declaration that nothing uses.
- No Zig file that no other file imports, except the entry points.
- No import that goes up a layer, or into the directory of another module.
- A function whose name starts with a capital letter returns a type and ends in `Type`.
- Each Markdown file has exactly one `# Title`.
- Every file with tests is in `src/unit_tests.zig`.
