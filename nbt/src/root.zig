//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const t = std.testing;
// const nbt = @import("nbt.zig");

test {
    _ = @import("nbt.zig");
    _ = @import("parse.zig");
    _ = @import("literal.zig");
    _ = @import("meta.zig");
    _ = @import("loader.zig");
    _ = @import("chunk_test.zig");
}
