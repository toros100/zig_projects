const std = @import("std");
const builtin = @import("builtin");

const Diag = struct {
    const Self = @This();
    message: []const u8,
    _: type = void,

    pub fn msg(comptime self: Self) []const u8 {
        return self.message;
    }

    pub fn init(comptime message: []const u8) Self {
        return .{ .message = message };
    }
};

/// helper type to be able to test failure without a compile error
/// TODO: would be nice to add an error union, so i can test for specific errors
pub fn ComptimeResult(comptime T: type) type {
    return union(enum) {
        const Self = @This();

        ok: T,
        err: Diag,

        pub fn initOk(comptime val: T) Self {
            return .{ .ok = val };
        }

        pub fn initErr(comptime err: []const u8) Self {
            return .{ .err = .init(err) };
        }

        pub fn asOk(comptime self: Self) error{WrongVariant}!T {
            switch (self) {
                .ok => |i| return i,
                .err => return error.WrongVariant,
            }
        }

        pub fn unwrap(comptime self: Self) T {
            switch (self) {
                .ok => |inner| return inner,
                .err => |e| @compileError(e.msg()),
            }
        }

        pub fn isOk(comptime self: Self) bool {
            return comptime (self == .ok);
        }

        pub fn isErr(comptime self: Self) bool {
            return (self == .err);
        }
    };
}

pub fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
}

fn DeclType(comptime T: type, comptime name: []const u8) type {
    if (isContainer(T) and @hasDecl(T, name)) {
        return @TypeOf(@field(T, name));
    } else {
        return void;
    }
}

pub fn getFn(comptime T: type, comptime name: []const u8) ?DeclType(T, name) {
    if (comptime !std.meta.hasFn(T, name)) return null;
    return @field(T, name);
}

test "getFn" {
    const Helper = struct {
        fn deriveSomeFn(comptime T: type) fn (*T) usize {
            const s = struct {
                fn someFn(self: *T) usize {
                    _ = self;
                    return 0;
                }
            };
            return s.someFn;
        }
    };
    const SomeType = struct {
        // getFn (or rather std.meta.hasFn) also works with functions that are stored as a const like this
        pub const someFn = Helper.deriveSomeFn(@This());
    };

    const OtherType = struct {
        pub fn someFn(self: *@This()) usize {
            _ = self;
            return 0;
        }
    };

    const Fn1 = getFn(SomeType, "someFn") orelse return error.FnNotFound;
    try std.testing.expectEqual(fn (*SomeType) usize, @TypeOf(Fn1));

    const Fn2 = getFn(OtherType, "someFn") orelse return error.FnNotFound;
    try std.testing.expectEqual(fn (*OtherType) usize, @TypeOf(Fn2));
}

pub fn getConst(comptime T: type, comptime name: []const u8) ?DeclType(T, name) {
    if (comptime !(isContainer(T) and @hasDecl(T, name))) return null;
    if (comptime !@typeInfo(@TypeOf(&@field(T, name))).pointer.attrs.@"const") return null;
    return @field(T, name);
}

test "getConst" {
    const t = std.testing;

    const S = struct {
        pub const some_const: usize = 8;
        pub var some_var: usize = 0;

        const non_pub_const: i8 = -3;

        field: usize,
    };

    try t.expect(getConst(S, "some_const") == 8);
    try t.expect(getConst(S, "some_var") == null);
    try t.expect(getConst(S, "field") == null);
    try t.expect(getConst(S, "non_pub_const") == null);
}

pub inline fn unreachableFmt(comptime fmt: []const u8, args: anytype) noreturn {
    if (builtin.mode.runtimeSafety()) {
        std.debug.panic(fmt, args);
    } else {
        unreachable;
    }
}

pub inline fn assertFmt(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (!ok) unreachableFmt(fmt, args);
}
