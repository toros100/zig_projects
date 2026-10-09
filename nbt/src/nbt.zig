const std = @import("std");
const parse = @import("parse.zig");
const meta = @import("meta.zig");

pub const Names = parse.Names;
pub const deriveParsePayloadInto = parse.deriveParsePayloadInto;
pub const ParseError = parse.ParseError;
pub const parseLeaky = parse.parseLeaky;
pub const PayloadReader = parse.PayloadReader;

pub const Tag = enum(u8) {
    const Self = @This();

    end = 0,
    byte = 1,
    short = 2,
    int = 3,
    long = 4,
    float = 5,
    double = 6,
    byte_array = 7,
    string = 8,
    list = 9,
    compound = 10,
    int_array = 11,
    long_array = 12,

    pub inline fn bytes(self: Self) [1]u8 {
        return .{@intFromEnum(self)};
    }

    pub inline fn into_u8(self: Self) u8 {
        return @intFromEnum(self);
    }

    pub fn fromByte(b: u8) error{InvalidTag}!Self {
        return if (b > @intFromEnum(Tag.long_array)) error.InvalidTag else @enumFromInt(b);
    }
};

pub inline fn asNumericPrimitive(comptime T: type) ?Tag {
    return switch (T) {
        i8 => .byte,
        i16 => .short,
        i32 => .int,
        i64 => .long,
        f32 => .float,
        f64 => .double,
        else => null,
    };
}

pub inline fn asPrimitive(comptime T: type) ?Tag {
    if (comptime asNumericPrimitive(T)) |tg| {
        return tg;
    } else if (T == []const u8) {
        return Tag.string;
    } else {
        return null;
    }
}

// type that can be used to handle list tags without allocating, if there is a comptime known
// upper bound on the length
pub fn BoundedList(comptime T: type, comptime cap: usize) type {
    const TImpl = parse.resolveImpl(T).unwrap();

    return struct {
        const Self = @This();

        buf: [cap]T = undefined,
        len: usize = 0,

        pub fn parsePayloadInto(
            self: *Self,
            reader: *PayloadReader(.list),
            alloc: std.mem.Allocator,
        ) ParseError!void {
            var elems = try reader.elements().as(TImpl.tag);

            if (reader.len > cap) {
                return error.InvalidValue;
            }

            self.len = reader.len;

            var i: usize = 0;
            while (try elems.next()) |e| : (i += 1) {
                try TImpl.ty.parsePayloadInto(&self.buf[i], e, alloc);
            }
            meta.assertFmt(i == self.len, "expected {d} list elements, only got {d}", .{ self.len, i });
        }

        pub fn slice(self: *const Self) []const T {
            return self.buf[0..self.len];
        }

        pub fn sliceMut(self: *Self) []T {
            return self.buf[0..self.len];
        }
    };
}

pub const ByteArray = Array(.byte_array);
pub const IntArray = Array(.int_array);
pub const LongArray = Array(.long_array);

/// zero copy nbt array
fn Array(comptime tag: Tag) type {
    return struct {
        const T = switch (tag) {
            .byte_array => i8,
            .int_array => i32,
            .long_array => i64,
            else => @compileError("illegal instantiation"),
        };

        const Self = @This();
        const byte_width: usize = @divExact(@bitSizeOf(T), 8);

        pub const empty = Self{};

        len: usize = 0,
        raw_bytes: []const u8 = undefined,

        pub fn parsePayloadInto(
            self: *Self,
            reader: *PayloadReader(tag),
            _: std.mem.Allocator,
        ) ParseError!void {
            self.raw_bytes = reader.raw_bytes();
            self.len = reader.len;
        }

        /// returns the i-th element of the array
        /// only call with i < self.len
        pub fn getIth(self: Self, i: usize) T {
            meta.assertFmt(i < self.len, "i={d} out of range 0..{d}", .{ i, self.len });

            const o = i * byte_width;
            const v, _ = parse.readNumber(T, self.raw_bytes[o .. o + byte_width]) catch unreachable;
            return v;
        }
    };
}

pub const Heightmap = struct {
    const Self = @This();

    arr: LongArray,

    pub fn parsePayloadInto(self: *Self, reader: *PayloadReader(.long_array), alloc: std.mem.Allocator) ParseError!void {
        try self.arr.parsePayloadInto(reader, alloc);
        if (self.arr.len != 37) return error.InvalidValue;
        // heightmap is 16*16 u9 values, packed into 64 bit integers (7 u9 values each, thus 37 longs total)
    }

    pub fn get(self: Self, block_x: u4, block_z: u4) u9 {
        const v = @as(u8, block_x) + 16 * @as(u8, block_z); // fits u8 by construction

        const idx = v / 7; // <= 36, so safe for array length 37
        const u: u64 = @bitCast(self.arr.getIth(idx));
        const shift: u6 = @intCast((v % 7) * 9); // <= 54

        return @truncate(u >> shift);
    }
};
