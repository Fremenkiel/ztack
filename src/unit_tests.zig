//! Imports every file that has tests, so that `zig build test:unit` runs them all.

test {
    _ = @import("scripts/tidy.zig");
}
