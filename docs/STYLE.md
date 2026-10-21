# Style Guide

This guide is the coding standard for ztack. It adapts TigerBeetle `TIGER_STYLE.md`. If this
guide does not cover a case, follow `TIGER_STYLE.md`, then the Zig style guide. `LAYOUT.md`
covers folders, files and the order of code inside a file.

The tidy step (`zig build test:tidy`) enforces the mechanical rules. Code review enforces the
others.

## Priorities

The design goals are safety, performance and developer experience, in that order. Simple code
comes from revision, not from the first draft. ztack keeps zero technical debt. If you find a
problem, fix it, or do not merge the change.

## Safety

### Control flow

- Use simple, explicit control flow.
- Do not use recursion. Use an explicit stack with a fixed capacity. Debug information trees and
  type trees are deep, so this rule matters in `debug_info`.
- Give every loop and every queue a fixed upper bound. If a loop must run forever, such as the
  engine loop, assert that.
- Split compound conditions into nested `if` statements.
- Turn long `else if` chains into a `switch` or a tree of `if` statements.
- Decide for each `if` whether it needs an `else`. State conditions positively:
  `if (index < count)`, not `if (!(index >= count))`.

### Assertions

- Assert arguments, return values, preconditions, postconditions and invariants.
- Write at least two assertions per function on average.
- Split compound assertions. Write `assert(a); assert(b);`, not `assert(a and b);`.
- Write an implication as `if (a) assert(b);`.
- Assert both what you expect and what you do not expect.
- Assert relationships between compile-time constants with `comptime assert`.
- Pair assertions. If data crosses a boundary, assert its property on both sides. An example is
  a packet that `gdb_remote` encodes and decodes.
- Import `assert` directly: `const assert = std.debug.assert;`.

Target data is input, not an invariant. The target program can corrupt its own memory. Never
assert on bytes that come from the target. Return an error and show "cannot read" in the UI.

### Types and sizes

- Use explicitly sized integers: `u32`, `u64`, `i64`. Use `usize` only for slice indexing and
  lengths that the standard library requires.
- Store target addresses as `u64`, also on a 32-bit host or target.
- Show division intent with `@divExact`, `@divFloor` or `stdx.div_ceil`.
- Treat `index`, `count` and `size` as different things. `count` is a number of items. `size` is
  a number of bytes. `index` is zero-based.

### Errors

- Handle all errors. Test the error paths.
- Compare errors with `switch`, not `== error.X`. A comparison can silently widen the type to
  `anyerror`.
- Never discard an error with `catch {}`. If an error is impossible, write
  `catch |err| switch (err) { ... }` and name each case.
- Do not use `catch unreachable` for target or file input.

### Memory

- Allocate session tables at session start, sized from `src/constants.zig`.
- Do not allocate on the per-frame UI path, except from the frame arena.
- Name allocators by their lifetime: `gpa`, `arena`, `frame_arena`, `session_arena`. From the
  name, the reader knows whether a `deinit` or a `free` is necessary.
- Put each allocation and its `defer` together, followed by a blank line.
- Declare variables in the smallest possible scope.
- Zero padding bytes in structs that cross a process boundary, such as `ztack_track` records.
- In a stored record, an absent ID is the `none` value of the ID, not an optional. An optional
  ID doubles the size of the field.
- Give each record that ztack stores in large numbers a `comptime assert(@sizeOf(T) == size)`.
  `DATA_MODEL.md` lists the sizes.

### Compiler

- Build Debug and ReleaseSafe in CI.
- Treat every compiler warning as an error.
- Pass library options explicitly at the call site. Do this also for options that equal the
  default.

## Performance

- Estimate cost before you write code. Consider memory, CPU and I/O, for bandwidth and latency.
- Batch work. Read target memory in large blocks, not one word at a time.
- Separate the control plane from the data plane. The engine decides, the workers do bulk work.
- Move hot loops into standalone functions with primitive arguments and no `self`.
- In the UI, draw only visible rows. Cache text layout per line.
- Never block the UI thread on the target or on a file.

## Naming

### Case

- `snake_case` for functions, variables, constants and file names.
- `TitleCase` for types.
- Write acronyms in full capitals: `DWARFReader`, `GDBRemote`, `PC`. In `snake_case` names, write
  them in lowercase: `dwarf_reader`, `pc_current`.
- A function that returns a type has a name that ends in `Type`: `QueueType`, `RingBufferType`.
- Never write `Self`. Name the type: `const Queue = @This();`.

### Words

- Do not abbreviate. Write `address`, not `addr`. Write `register`, not `reg`. Exceptions: `pc`,
  `sp`, `fp`, `lr`, `pid`, `id`, `os`, `ns`, `ms`, and loop counters `i`, `j` in short loops.
- Put units and qualifiers last, from most to least important. Write `latency_ms_max`, not
  `max_latency_ms`. Write `address_start` and `address_end`, not `start_address`.
- For related names, prefer pairs of equal length, so that the code lines up. Write `source`
  and `target`, not `src` and `dest`. If no natural pair of equal length exists, use the clearest
  pair.
- Name a helper after its caller, with a suffix: `memory_read` and `memory_read_callback`.
- Use one name for one concept across the codebase. A thread is always a `thread`, never a
  `task` or a `worker`.
- Use nouns for data: `session.breakpoints`, `constants.breakpoint_count_max`.

### Parameters

- Put allocators and other shared objects first, from general to specific.
- Put callbacks last.
- If two parameters have the same type and a caller can swap them, use an options struct.
- Name optional parameters so that a `null` at the call site is clear.
- Pass arguments larger than 16 bytes as `*const T`.

## Functions

- Keep each function to 70 lines or fewer.
- Keep signatures small: few parameters and a simple return type.
- Prefer simple return types, in this order: `void`, `bool`, `u64`, `?u64`, `!u64`.
- Push `if` statements up and `for` loops down. The parent function holds the control flow and
  the state. Leaf functions compute and do not branch on state.
- Run each function to completion. A function does not wait on another thread in the middle.
- Initialize large structs in place, through an out pointer:
  `fn init(session: *Session, gpa: std.mem.Allocator) !void`.
- Compute a value close to where you use it. Do not keep a copy of state that can go stale.

## Comments

- Comments explain why. The code shows what.
- Write comments as full sentences, with a capital letter and a full stop. A comment at the end
  of a line can be a short phrase.
- Start each test with a comment that explains what it tests and how.
- Start each file with a `//!` comment that says what the file is for.
- Mark each fact about an operating system or a file format with its source, for example the
  section of the DWARF 5 standard or a link to Apple documentation.

## Formatting

- Run `zig fmt`. Indent with 4 spaces.
- Keep every line to 100 columns or fewer. Lines that contain a URL are the only exception.
- To wrap a long call or literal, add a trailing comma and run `zig fmt`.
- Use braces on every `if`, unless the whole statement fits on one line.
- Do not leave trailing whitespace, tabs or carriage returns.

## Dependencies

- Use only the dependencies in `DEPENDENCIES.md`.
- Write scripts in Zig, as subcommands of `src/scripts.zig`. Do not add shell scripts, except
  `zig/download.sh`.
- Use the pinned compiler: `./zig/zig build`. `build.zig` stops with a compile error on any other
  Zig version.

## Commits

- Write a commit message that says what changed and why. A pull request description does not
  replace it.
- Keep each commit to one logical change. A commit compiles and passes `zig build test`.
- Do not merge `FIXME` comments or debug prints. Use `TODO(name): reason` for planned work. If
  an issue exists, add its link.

## Banned constructs

The tidy step rejects these strings outside `vendor/`:

| Banned | Use instead |
|---|---|
| `Self = @This()` | `TypeName = @This()` |
| `usingnamespace` | Explicit declarations. |
| `std.debug.assert(` | `assert(` with a direct import. |
| `== error.` and `!= error.` | `switch` on the error. |
| `catch unreachable` in `target/`, `debug_info/` | Return an error. |
| `@memcpy(` | `stdx.copy_disjoint`, which asserts no overlap. |
| `FIXME`, `dbg(` | Remove before merge. |
| `std.debug.print(` outside `scripts/` | `std.log` with a scope. |

## Changes from TigerBeetle

ztack differs from `TIGER_STYLE.md` in three places:

- Dependencies. TigerBeetle has zero dependencies. ztack has a short approved list, because a
  GUI toolkit and a disassembler are each months of work.
- Memory. TigerBeetle allocates all memory at startup. ztack uses declared limits, session
  tables and arenas, because the size of debug information is not known at startup.
- Contributions. TigerBeetle does not accept AI-assisted commits. ztack has no such rule.
