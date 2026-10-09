const std = @import("std");
const nbt = @import("nbt.zig");
const Tag = nbt.Tag;

// helper functions sometimes used to encode test data

inline fn tagFor(comptime T: type) ?Tag {
    if (nbt.asPrimitive(T)) |tg| {
        return tg;
    }
    return switch (@typeInfo(T)) {
        .@"struct" => |s| if (!s.is_tuple) .compound else null,
        .pointer => |p| if (p.size == .slice) .list else null,
        else => null,
    };
}

pub inline fn toNbtString(comptime lit: []const u8) []const u8 {
    return comptime blk: {
        if (lit.len > std.math.maxInt(u16)) {
            @compileError("length does not fit u16");
        }
        const l = std.mem.nativeToBig(u16, lit.len);
        break :blk std.mem.toBytes(l) ++ lit;
    };
}

pub fn primitivePayloadBytes(comptime T: type, comptime val: T) []const u8 {
    return comptime blk: {
        switch (T) {
            i8, i16, i32, i64, f32, f64 => {
                const I = std.meta.Int(.unsigned, @bitSizeOf(T));
                const as_int: I = @bitCast(val);
                break :blk &std.mem.toBytes(std.mem.nativeToBig(I, as_int));
            },
            []const u8 => break :blk toNbtString(val),
            else => @compileError("unexpected type: " ++ @typeName(T)),
        }
    };
}

pub fn encodeCompoundPayload(comptime T: type, comptime val: T) []const u8 {
    return comptime blk: {
        const FieldEnum = std.meta.FieldEnum(T);

        var acc = @as([]const u8, "");

        for (std.enums.values(FieldEnum)) |f| {
            const field_name = @tagName(f);
            acc = acc ++ encodeTag(
                @FieldType(T, field_name),
                @as([]const u8, field_name),
                @field(val, field_name),
            );
        }
        acc = acc ++ Tag.end.bytes();

        break :blk acc;
    };
}

pub fn encodeTag(
    comptime T: type,
    comptime name: []const u8,
    comptime val: T,
) []const u8 {
    @setEvalBranchQuota(10000); // TODO: come up with a meaningful quota
    return comptime blk: {
        const tg = tagFor(T) orelse @compileError("unsupported type: " ++ @typeName(T));
        break :blk @as([]const u8, &tg.bytes()) ++
            @as([]const u8, toNbtString(name)) ++
            encodePayload(T, val);
    };
}

fn encodePayload(
    comptime T: type,
    comptime val: T,
) []const u8 {
    return comptime blk: {
        if (nbt.asPrimitive(T)) |_| {
            break :blk primitivePayloadBytes(T, val);
        }

        switch (@typeInfo(T)) {
            .@"struct" => break :blk encodeCompoundPayload(T, val),
            .pointer => |p| {
                if (p.size == .slice) {
                    const ct = tagFor(p.child) orelse
                        @compileError("unsupported list element type: " ++ @typeName(p.child) ++ " outer: " ++ @typeName(T));

                    const l: i32 = @intCast(val.len);
                    if (l < 0) {
                        @compileError("list too long (length does not fit in i32)");
                    }

                    var acc: []const u8 = @as([]const u8, &ct.bytes()) ++
                        @as([]const u8, &primitivePayloadBytes(i32, l));

                    for (val) |e| {
                        acc = acc ++ encodePayload(p.child, e);
                    }

                    break :blk acc;
                } else {
                    @compileError("unsupported pointer type: " ++ @typeName(T));
                }
            },
            else => @compileError("unsupported type: " ++ @typeName(T)),
        }
    };
}
