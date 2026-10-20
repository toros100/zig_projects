const std = @import("std");

pub const Loader = struct {
    const Self = @This();
    gpa: std.mem.Allocator,
    io: std.Io,
    file_buf: std.ArrayList(u8) = .empty,
    chunk_buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Self {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Self) void {
        self.file_buf.deinit(self.gpa);
        self.chunk_buf.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn loadFile(self: *Self, dir: std.Io.Dir, path: []const u8) !void {
        const file = try dir.openFile(self.io, path, .{});
        defer file.close(self.io);

        const size = (try file.stat(self.io)).size;
        self.file_buf.clearRetainingCapacity();
        try self.file_buf.resize(self.gpa, @intCast(size));

        var reader = file.reader(self.io, &.{});

        try reader.interface.readSliceAll(self.file_buf.items);
    }

    pub fn loadBytes(self: *Self, bytes: []const u8) !void {
        self.file_buf.clearRetainingCapacity();
        try self.file_buf.appendSlice(self.gpa, bytes);
    }

    /// returns the chunk offset and length, both measured in 4096 byte sectors
    fn getChunkLocation(self: *Self, idx: u10) !struct { u24, u8 } {
        if (self.file_buf.items.len == 0) {
            return error.NoData;
        }

        if (self.file_buf.items.len < idx * 4 + 4) return error.UnexpectedEof;

        const v = std.mem.readInt(
            u32,
            self.file_buf.items[idx * 4 .. idx * 4 + 4][0..4],
            .big,
        );

        const off: u24 = @truncate(v >> 8);
        const len: u8 = @truncate(v);

        if (off < 2 or len == 0) return error.BadData;
        return .{ off, len };
    }

    pub fn getChunkData(self: *Self, idx: u10) ![]const u8 {
        const o, const l = try self.getChunkLocation(idx);

        const off = @as(usize, o) * 4096;
        const len = @as(usize, l) * 4096;

        if (self.file_buf.items.len < off + len) return error.BadData;

        const b = std.mem.readInt(
            i32,
            self.file_buf.items[off .. off + 4][0..4],
            .big,
        );

        if (b <= 1) return error.BadData;

        const bytes_len: usize = @intCast(b);

        const compression_type = self.file_buf.items[off + 4];

        if (compression_type != 2) return error.UnexpectedCompression;

        const chunk_byte_off = off + 5;
        const chunk_byte_len = bytes_len - 1;

        const compressed_bytes = self.file_buf.items[chunk_byte_off .. chunk_byte_off + chunk_byte_len];

        return self.decompressChunk(compressed_bytes);
    }

    /// the returned slice aliases self.chunk_buf (only valid until the next decompressChunk or deinit)
    fn decompressChunk(self: *Self, compressed: []const u8) ![]const u8 {
        self.chunk_buf.clearRetainingCapacity();
        var aw = std.Io.Writer.Allocating.fromArrayList(self.gpa, &self.chunk_buf);
        defer self.chunk_buf = aw.toArrayList();
        var in = std.Io.Reader.fixed(compressed);
        var decompress = std.compress.flate.Decompress.init(&in, .zlib, &.{});

        _ = decompress.reader.streamRemaining(&aw.writer) catch |e|
            switch (e) {
                error.ReadFailed => return decompress.err.?,
                else => return e,
            };

        return aw.written();
    }
};

test "Loader" {
    const t = std.testing;
    const bytes = @embedFile("testdata/r.1.1.mca");

    var loader = Loader.init(t.allocator, t.io);
    defer loader.deinit();

    try loader.loadFile(std.Io.Dir.cwd(), "src/testdata/r.1.1.mca");

    try t.expectEqualSlices(u8, bytes, loader.file_buf.items);

    const chunk = try loader.getChunkData(0);

    try t.expect(chunk.len > 0);
    try t.expectEqual(10, chunk[0]); // compound tag
    try t.expectEqual(0, chunk[chunk.len - 1]); // end tag
}
