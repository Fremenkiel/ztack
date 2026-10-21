//! Entry point of ztack. No debugger code exists yet.

const std = @import("std");

const log = std.log.scoped(.main);

pub fn main() void {
    log.info("no debugger code exists yet", .{});
}
