const std = @import("std");
const nbt = @import("nbt.zig");

const Status = enum {
    full,
    other,

    // example handwritten implementation of the required method
    pub fn parsePayloadInto(
        dst: *@This(),
        reader: *nbt.PayloadReader(.string), // Tag.string here determines the interpretation of Status as NBT data
        _: std.mem.Allocator,
    ) nbt.ParseError!void {
        dst.* = if (std.mem.eql(u8, reader.value, "minecraft:full")) .full else .other;
    }
};

const Block = struct {
    name: []const u8,

    // the method can be "derived" like this for structs (always treated as Tag.compound)
    // this is slightly rustbrained and more setup work than the way the std json parsing works,
    // but i prefer it for being more explicit
    // the downside is that this approach does not work for foreign types (can't just add a const/fn),
    // but that could be solved by passing overrides to the parseLeaky call
    pub const parsePayloadInto = nbt.deriveParsePayloadInto(@This());
    pub const nbt_names: nbt.Names(@This()) = .init(.{ .name = "Name" });
};

const BlockStates = struct {
    const Self = @This();

    palette: []Block,
    data: nbt.LongArray = .empty,

    pub fn parsePayloadInto(self: *Self, reader: *nbt.PayloadReader(.compound), alloc: std.mem.Allocator) nbt.ParseError!void {

        // can use the "derived" parse fn directly like this, then do postprocessing/validation
        try nbt.deriveParsePayloadInto(Self)(self, reader, alloc);

        // there are way fewer than 4096 blocks, it is just a logical upper bound
        // (number of block positions in a section)
        if (self.palette.len == 0 or self.palette.len > 4096) return error.InvalidValue;

        // data empty should be empty with palette length 1
        if (self.palette.len == 1) {
            if (self.data.len != 0) return error.InvalidValue else return;
        }

        // bits required to index into palette
        const bit_width: usize = @max(4, std.math.log2_int_ceil(usize, self.palette.len));

        const expected_len: usize = @divCeil(4096, (64 / bit_width));

        if (self.data.len != expected_len) return error.InvalidValue;
    }

    pub fn blockAt(self: BlockStates, x: u4, y: u4, z: u4) Block {
        std.debug.assert(self.palette.len > 0);

        if (self.palette.len == 1) return self.palette[0];

        const bit_width: u4 = @intCast(@max(4, std.math.log2_int_ceil(usize, self.palette.len)));
        // by the length restriction, the max is <= 12, thus fits u4

        const i = @as(u12, y) * 256 + @as(u12, z) * 16 + @as(u12, x); // fits u12 by construction

        const n: u5 = @truncate(64 / @as(u7, bit_width)); // <= 64/4 = 16

        // i / n < self.data.len by construction
        const u: u64 = @bitCast(self.data.getIth(i / n));

        const shift: u6 = @intCast(bit_width * (i % n));

        // shift = bit_width * (i % n)
        //      <= bit_width * (n-1)
        //       = bit_width * n - bit_width
        //      <= 64 - bit_width
        //      <= 60 (fits u6)

        const mask = (@as(u64, 1) << bit_width) - 1;

        const palette_index = (u >> shift) & mask;

        // within bounds by construction
        return self.palette[palette_index];
    }
};

const Section = struct {
    y: i8,
    block_states: BlockStates,

    pub const parsePayloadInto = nbt.deriveParsePayloadInto(@This());

    // mapping struct field names to nbt field names, in case it is not possible or not
    // desirable to just rename the struct field itself
    pub const nbt_names: nbt.Names(@This()) = .init(.{ .y = "Y" });
};

const Heightmaps = struct {
    world_surface: nbt.Heightmap,
    ocean_floor: nbt.Heightmap,

    pub const parsePayloadInto = nbt.deriveParsePayloadInto(@This());

    pub const nbt_names: nbt.Names(@This()) = .init(.{
        .world_surface = "WORLD_SURFACE",
        .ocean_floor = "OCEAN_FLOOR",
    });
};

const Chunk = struct {
    status: Status,
    x_pos: i32,
    z_pos: i32,
    y_pos: i32,
    sections: nbt.BoundedList(Section, 24),
    heightmaps: Heightmaps,

    pub const parsePayloadInto = nbt.deriveParsePayloadInto(@This());
    pub const nbt_names: nbt.Names(@This()) = .init(.{
        .status = "Status",
        .x_pos = "xPos",
        .z_pos = "zPos",
        .y_pos = "yPos",
        .heightmaps = "Heightmaps",
    });
};

test "Chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const t = std.testing;
    const Loader = @import("loader.zig").Loader;
    const bytes = @embedFile("testdata/r.1.1.mca");

    var loader = Loader.init(t.allocator, t.io);
    defer loader.deinit();

    try loader.loadBytes(bytes);

    const chunk = try loader.getChunkData(5);

    const res = try nbt.parseLeaky(Chunk, alloc, chunk);
    const val = res.val;

    try t.expectEqual(Status.full, val.status);

    try t.expectEqual(37, val.x_pos);
    try t.expectEqual(32, val.z_pos);
    try t.expectEqual(-4, val.y_pos);

    try t.expectEqual(24, val.sections.len);

    const sec = val.sections.slice()[4];

    try t.expectEqual(17, sec.block_states.palette.len);

    try t.expectEqualStrings(
        "minecraft:diamond_ore",
        sec.block_states.blockAt(12, 4, 14).name,
    );
}
