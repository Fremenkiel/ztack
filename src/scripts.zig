//! One binary for all scripts. Run one with `zig build scripts -- <name>`.

const std = @import("std");
const assert = std.debug.assert;

const tidy = @import("scripts/tidy.zig");

const Command = enum { tidy };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    assert(arguments.len >= 1);

    if (arguments.len != 2) {
        std.process.fatal("usage: scripts <command>, commands: tidy", .{});
    }
    const command = std.meta.stringToEnum(Command, arguments[1]) orelse {
        std.process.fatal("unknown command '{s}', commands: tidy", .{arguments[1]});
    };

    switch (command) {
        .tidy => {
            const problem_count = try tidy.run(arena, init.io);
            if (problem_count > 0) {
                std.process.fatal("tidy: {d} problems", .{problem_count});
            }
        },
    }
}
