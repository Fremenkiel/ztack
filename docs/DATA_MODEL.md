# Data Model

This document defines the core types of ztack, how they refer to each other, and who owns their
memory. The code sketches follow `STYLE.md`. They show the shape of each type, not final code.

## Principles

- Entities refer to each other by typed IDs, not by pointers. An ID is an index into a table that
  the owner of the entity holds.
- Strings and call stacks are interned. An intern table stores each value once and returns an
  ID. Two equal values always have the same ID.
- Tables are arrays. A lookup by ID is an array index. A search by value uses a sorted array or a
  hash map that the table owns.
- Every table has a maximum count. If a table is full, the operation returns an error.
- A snapshot is immutable. The engine builds a new snapshot at each stop and never changes an old
  one.
- Each table has one owner and one writer thread. The session owns session tables. Each image
  owns its debug information tables.
- Hot tables use a struct of arrays. A search reads only the array of keys, so the search touches
  fewer cache lines.
- Each record that the code stores by the million has a fixed size. A `comptime assert` on
  `@sizeOf` keeps it fixed. The sizes are in the table at the end of this document.

## IDs

Each ID is a non-exhaustive `enum(u32)`. The compiler then rejects a `ThreadId` where a
`ProcessId` is expected.

```zig
pub const ProcessId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const ThreadId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const GoroutineId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const BreakpointId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const SiteId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const ImageId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const FileId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const StringId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const SymbolId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const TypeId = enum(u32) { none = std.math.maxInt(u32), _ };
pub const StackId = enum(u32) { root = std.math.maxInt(u32), _ };
```

An ID that can be absent uses its `none` value, not an optional. `?ThreadId` takes 8 bytes,
`ThreadId` with `none` takes 4. Use `?Id` only in function signatures, never in stored records.

An ID is local to a session. Operating system values, such as the pid and the thread port, are
fields with their own names (`pid`, `thread_os`). They are never used as IDs.

`FileId`, `StringId`, `SymbolId` and `TypeId` are local to one image. A reference that leaves
the image, such as a frame in a snapshot, carries the `ImageId` with it.

## Session and processes

```zig
pub const Session = struct {
    processes: stdx.BoundedArrayType(Process, process_count_max),
    threads: stdx.BoundedArrayType(Thread, thread_count_max),
    images: stdx.BoundedArrayType(Image, image_count_max),
    breakpoints: stdx.BoundedArrayType(Breakpoint, breakpoint_count_max),
    sites: stdx.BoundedArrayType(BreakpointSite, site_count_max),
    strings: StringTable,
    stacks: StackTable,
    state: State,
    stop_sequence: u64,

    pub const State = enum(u8) { idle, launching, running, stopped, exited };
};

pub const Process = struct {
    pid: u32,
    parent: ProcessId,
    exit_code: i32,
    state: Session.State,
    language: Language,
    exited: bool,
};

pub const Language = enum(u8) { zig, go, c, unknown };
```

All threads and images of all processes sit in one session table each. A thread or an image
names its process. A process holds no arrays of its own. A Go program can have hundreds of
threads, and a short shell child has one. One shared table with one maximum fits both. An
inline array per process reserves `process_count_max * thread_count_max` slots.

A child process is a `Process` whose `parent` is not `none`. The process tree is the set of
`parent` links. If `exited` is true, `exit_code` holds the exit code.

`Session.strings` holds session strings only: paths, arguments, environment and messages. Debug
information strings live in the image (see "Source and symbols").

## Threads, goroutines and frames

```zig
pub const Thread = struct {
    thread_os: u64,
    process: ProcessId,
    stop_reason: StopReason,
};

pub const StopReason = union(enum(u8)) {
    none,
    breakpoint: BreakpointId,
    step,
    watchpoint: u64,
    signal: u32,
    pause,
    exception: u32,
};

pub const Goroutine = struct {
    goid: u64,
    pc: u64,
    sp: u64,
    stack_start: u64,
    stack_end: u64,
    thread: ThreadId,
    status: u32,
};

pub const Frame = struct {
    pc: u64,
    sp: u64,
    fp: u64,
    image: ImageId,
    symbol: SymbolId,
    location: SourceLocation,
    inline_depth: u8,
};
```

A `ThreadId` is the index of the thread in `Session.threads`. Registers are not part of
`Thread`. The snapshot holds the registers of the stopped threads (see "Snapshot"). The engine
keeps no copy between stops, because a copy goes stale at the next resume.

A goroutine with `thread == .none` is not running. Its registers come from the saved `sched`
fields in the runtime.

The engine reads goroutines on demand. If a Go program stops while the goroutine panel is open,
the engine reads the list. If the user opens the panel at a stop, the engine reads it then. It
reads at most `goroutine_count_max` goroutines and shows the count of the others. It reads
`runtime.allgs` in one block and the `g` structs in batched reads.

## Breakpoints

```zig
pub const Breakpoint = struct {
    location: SourceLocation,
    image: ImageId,
    hit_count: u64,
    sites_start: u32,
    sites_count: u32,
    kind: Kind,
    enabled: bool,

    pub const Kind = enum(u8) { line, function, instruction };
};

pub const BreakpointSite = struct {
    address: u64,
    reference_count: u16,
    owner: Owner,

    pub const Owner = enum(u8) { user, step };
};
```

A breakpoint is what the user asked for. A site is one address in the target that holds a trap
instruction. One source line can map to several addresses, for example in an inlined or generic
function. A breakpoint then refers to several sites.

Two breakpoints on one address share one site. The site counts its references. If the count
changes from 0 to 1, the trap goes in. If the count changes from 1 to 0, the trap comes out.
Then the original instruction is never lost under a second trap.

Step over and step out use sites with `owner == .step`. They do not use slots in
`Session.breakpoints`. At the end of the step, the engine removes all of them.

The original instruction bytes are not in this table. With `gdb_remote`, `debugserver` keeps
them. A native backend keeps them in its own table, keyed by `SiteId`.

## Source and symbols

```zig
pub const SourceLocation = struct {
    file: FileId,
    line: u32,
    column: u16,
};

pub const LineTable = struct {
    address_offsets: []const u32,
    rows: []const LineRow,
};

pub const LineRow = struct {
    file: FileId,
    line: u32,
    column: u16,
    flags: packed struct(u8) {
        is_stmt: bool,
        prologue_end: bool,
        epilogue_begin: bool,
        end_sequence: bool,
        padding: u4 = 0,
    },
};

pub const LineIndexEntry = struct {
    line: u32,
    row_index: u32,
};

pub const SymbolTable = struct {
    address_offsets: []const u32,
    sizes: []const u32,
    names: []const StringId,
};

pub const Image = struct {
    path: StringId,
    process: ProcessId,
    address_load: u64,
    address_text: u64,
    format: enum(u8) { macho, elf },
    language: Language,
    debug_info_state: enum(u8) { none, loading, lines_ready, ready, failed },
};
```

An image owns its debug information: the line table, the symbol table, the types, the files and
an image string table. All of it lives in one arena per image. The worker thread that loads the
image is its only writer. When the state changes to `lines_ready` or `ready`, the worker
publishes the tables and never changes them again. Then the engine reads them with no lock.

The line table is a struct of arrays. `address_offsets[i]` is the address of `rows[i]`, as an
offset from `Image.address_text`. A lookup is a binary search over `address_offsets` only. A 4-byte
offset is enough, because one image has less than 4 GB of code.

The line-to-address index is one sorted array of `LineIndexEntry` per file. It holds only rows
with `is_stmt` set, because a breakpoint goes only on those rows.

The symbol table is also a struct of arrays, sorted by address. The image of a symbol is the
image that owns the table, so a symbol does not store it.

Strings from the debug information stay in the file where possible. ztack maps the binary and the
object files read-only. A name in `.debug_str` is a reference into that mapping. ztack copies
only decompressed data, such as Go `__zdebug_*` sections, into the image arena.

## Types and values

```zig
pub const Type = struct {
    size: u64,
    name: StringId,
    data: u32,
    tag: Tag,
    flags: packed struct(u8) { signed: bool, padding: u7 = 0 },
    bit_count: u16,

    pub const Tag = enum(u8) {
        void,
        bool,
        int,
        float,
        pointer,
        array,
        structure,
        enumeration,
        function,
        go_string,
        go_slice,
        go_map,
        go_interface,
        go_interface_empty,
        go_channel,
        zig_slice,
        zig_optional,
        zig_error_union,
        zig_error_set,
        zig_tagged_union,
    };
};

pub const Field = struct {
    offset_bits: u64,
    name: StringId,
    type: TypeId,
};

pub const EnumValue = struct {
    value: i64,
    name: StringId,
};
```

`tag` decides what `data` means:

| Tag | `data` |
|---|---|
| `pointer`, `go_slice`, `go_channel`, `zig_slice`, `zig_optional` | Element `TypeId`. |
| `array` | Index into `type_extra`: element `TypeId`, then the count as two `u32` words. |
| `structure` | Index into `type_extra`: `fields_start`, `fields_count`. |
| `zig_tagged_union` | Index into `type_extra`: `fields_start`, `fields_count`, tag `TypeId`. |
| `enumeration`, `zig_error_set` | Index into `type_extra`: `values_start`, `values_count`. |
| `go_map` | Index into `type_extra`: key `TypeId`, value `TypeId`. |
| `zig_error_union` | Index into `type_extra`: payload `TypeId`, error set `TypeId`. |
| Other tags | Not used. |

Each image has one `type_extra: []u32` array, one `fields: []Field` array and one
`values: []EnumValue` array. A type refers to them by index. This avoids a separate allocation
per type and keeps `Type` at 24 bytes.

`bit_count` is the width of an integer in bits, for example 3 for a Zig `u3`. `Field.offset_bits`
is the offset of a field in bits. Together they describe Zig packed structs.

A Go map uses the Swiss-table layout of `internal/runtime/maps`. It is the only map layout from
Go 1.26. ztack reads the map header, the directory and the groups by DWARF field names. If the
fields do not match, the value shows "cannot read".

```zig
pub const Value = struct {
    address: u64,
    name: StringId,
    type: TypeId,
    bytes_offset: u32,
    bytes_size: u32,
    parent: u32,
    children_count: u32,
    location: enum(u8) { memory, register, none },
    status: enum(u8) { ok, unreadable, truncated },
    changed: bool,
};
```

The values of a snapshot form one flat tree in pre-order. `parent` is the index of the parent
value, or `maxInt(u32)` for a root. The children of a value follow it directly. The bytes of all
values sit in one byte buffer of the snapshot. A value refers to them by offset and size.

A value in a register has `location == .register`, and `address` is the register number. If
ztack cannot read the bytes, `status` is `unreadable` and the UI says so. If a value is larger
than `value_size_max`, ztack stores the first part and sets `status` to `truncated`. If the bytes
differ from the same value at the previous stop, `changed` is true.

## Memory

```zig
pub const MemoryRegion = struct {
    address_start: u64,
    address_end: u64,
    name: StringId,
    protection: packed struct(u8) { read: bool, write: bool, execute: bool, padding: u5 = 0 },
    kind: enum(u8) { code, data, heap, stack, mapped_file, unknown },
};

pub const Allocation = struct {
    address: u64,
    size: u64,
    time_ns: u64,
    stack: StackId,
    source: enum(u8) { ztack_track, malloc },
};

pub const AllocationSite = struct {
    size_alloc: u64,
    size_free: u64,
    count_alloc: u32,
    count_free: u32,
    stack: StackId,
};
```

ztack keeps live allocations in a hash map keyed by address, with at most
`allocation_count_max` entries. A free event removes the entry and adds to the
`AllocationSite` of its stack. Then memory grows with the live allocations, not with the total
count of events. The allocation timeline is an array of fixed time buckets, each with the bytes
allocated and freed in that bucket.

A leak, for a non-GC language, is an `Allocation` that is still in the map at process exit or at
the allocator `deinit`.

## Profiling

```zig
pub const Sample = struct {
    time_ns: u64,
    thread: ThreadId,
    stack: StackId,
};

pub const StackNode = struct {
    address: u64,
    parent: StackId,
};

pub const ProcessStats = struct {
    time_ns: u64,
    cpu_user_ns: u64,
    cpu_system_ns: u64,
    memory_footprint_size: u64,
    memory_footprint_size_max: u64,
    process: ProcessId,
    thread_count: u32,
};

pub const GoHeapStats = struct {
    time_ns: u64,
    heap_live_size: u64,
    heap_goal_size: u64,
    gc_pause_ns_total: u64,
    gc_count: u32,
    goroutine_count: u32,
};
```

`StackTable` is a prefix tree. A `StackId` is the index of a `StackNode`. A node is one return
address and the `StackId` of its caller. The outermost frame has `parent == .root`. A hash map
on `(parent, address)` interns the nodes. Stacks with a shared prefix store the prefix once. The
flame graph is then a fold over the nodes, with no extra copy of the stacks.

`cpu_user_ns` and `cpu_system_ns` are nanoseconds. On Apple Silicon, `proc_pid_rusage` reports
these times in Mach ticks. ztack converts them with `mach_timebase_info`. `thread_count` comes
from `proc_pidinfo` with `PROC_PIDTASKINFO`, because `rusage_info_v4` has no thread count.

## Snapshot

```zig
pub const Snapshot = struct {
    sequence: u64,
    session_state: Session.State,
    process_current: ProcessId,
    thread_current: ThreadId,
    frame_current: u32,
    frames: []const Frame,
    threads: []const Thread,
    registers: []const RegisterSet,
    goroutines: []const Goroutine,
    goroutine_count_total: u32,
    values: []const Value,
    value_bytes: []const u8,
    breakpoints: []const Breakpoint,
    stats: []const ProcessStats,
};

pub const RegisterSet = struct {
    thread: ThreadId,
    values: [register_count_max]u64,
    valid: std.StaticBitSet(register_count_max),
    changed: std.StaticBitSet(register_count_max),
};
```

`registers` holds the full register set of the current thread. For the other stopped threads it
holds only the registers that the stop reply sent, which include the PC, SP and FP. A register
that ztack did not read has its bit clear in `valid`.

The engine builds each snapshot in a snapshot arena. Three arenas take turns: one holds the
snapshot that the UI reads, one holds the newest published snapshot, and the engine builds into
the third. The UI takes the newest snapshot with one atomic swap. The engine then resets the
arena that the UI released. If the engine publishes faster than the UI draws, two arenas make
the engine wait for the UI. The engine must never wait.

## Memory budgets

TigerBeetle allocates all memory at startup. ztack cannot do that fully, because the size of the
debug information is not known before the user opens a program. ztack adapts the rule:

- Each subsystem declares its limits as constants in `src/constants.zig`, for example
  `thread_count_max`, `breakpoint_count_max`, `site_count_max`, `goroutine_count_max`,
  `sample_count_max`, `allocation_count_max`, `value_size_max` and `debug_info_size_max`.
- The engine allocates session tables once, at session start, from those constants.
- Debug information goes into one arena per image. When the image unloads, ztack frees the arena.
- The UI has a frame arena. It resets at the start of each frame.
- No allocation on the per-frame path, except from the frame arena.
- Queues between threads have a fixed capacity.

If a limit is too small, ztack shows a clear message with the name of the constant.

## Sizes

Each type in this table has a `comptime assert(@sizeOf(T) == size)` next to its declaration.

| Record | Size in bytes | Count |
|---|---|---|
| Line row (`address_offsets` item plus `LineRow`) | 4 + 12 = 16 | One per line table row. |
| `LineIndexEntry` | 8 | One per `is_stmt` row. |
| Symbol (three arrays) | 4 + 4 + 4 = 12 | One per function. |
| `Type` | 24 | One per DWARF type. |
| `Field` | 16 | One per struct field. |
| `Thread` | 32 | `thread_count_max`. |
| `Frame` | 48 | Up to 1024 per stack. |
| `Goroutine` | 48 | `goroutine_count_max`. |
| `BreakpointSite` | 16 | `site_count_max`. |
| `Value` | 40 | Per snapshot. |
| `StackNode` | 16 | One per distinct stack prefix. |
| `Sample` | 16 | `sample_count_max`. |
| `Allocation` | 32 | `allocation_count_max`. |

Estimate for a 100 MB Go binary, with an assumed 4 million line rows, 200 thousand symbols and
300 thousand types: line rows and the line index take about 96 MB, symbols about 2.4 MB, and
types about 7.2 MB plus fields. The first design took about 160 MB, 4.8 MB and 12 MB. The M1
benchmark measures the real counts and replaces these numbers.
