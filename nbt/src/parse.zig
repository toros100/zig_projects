const std = @import("std");
const nbt = @import("nbt.zig");
const meta = @import("meta.zig");
const lit = @import("literal.zig");

pub const ParseError = error{
    UnexpectedEof,
    UnexpectedTag,
    InvalidTag,
    InvalidLength, // i32 that is supposed to be a length is < 0 (applies to list and array tags)
    InvalidList, // element tag Tag.end but length != 0
    UnknownField, // currently not used (would be used when disallowing unknown fields)
    DuplicateField,
    MissingField,
    InvalidValue, // generic error, can be used for user-defined parsePayloadInto impl if nothing else fits
} || std.mem.Allocator.Error;

test "PayloadReader interface" {
    // methods that should exist on every implementation of PayloadReader (builtin)
    inline for (comptime std.enums.values(nbt.Tag)) |t| {
        if (t != .end) {
            const reader = &PayloadReader(t);

            const init_fn_ty = fn (*PayloadReader(t), []const u8) ParseError!void;

            const finish_fn_ty = fn (*PayloadReader(t)) ParseError!usize;

            // initializes the reader with data
            // may not read any of its own fields before writing to them, may not assume that fields
            // have their default value (restore defaults on init)
            if (!(init_fn_ty == @TypeOf(reader.init))) @compileError(@typeName(reader.*) ++
                " should have method `init` with type " ++ @typeName(init_fn_ty));

            // tries to consume the entire payload, returns the total number of bytes read
            // (trivial for anything other than list or compound tags)
            if (!(finish_fn_ty == @TypeOf(reader.finish))) @compileError(@typeName(reader.*) ++
                " should have method `finish` with type " ++ @typeName(finish_fn_ty));
        }
    }
}

pub fn PayloadReader(tag: nbt.Tag) type {
    return switch (tag) {
        .end => @compileError("illegal instantiation"),
        .byte => NumberReader(i8), // (that is what byte means in NBT)
        .short => NumberReader(i16),
        .int => NumberReader(i32),
        .long => NumberReader(i64),
        .float => NumberReader(f32),
        .double => NumberReader(f64),
        .string => StringReader,
        .compound => CompoundReader,
        .byte_array => ArrayReader(i8),
        .int_array => ArrayReader(i32),
        .long_array => ArrayReader(i64),
        .list => ListReader,
    };
}

/// the `end` variant will never be active
pub const AnyPayloadReader = union(nbt.Tag) {
    end,
    byte: PayloadReader(.byte),
    short: PayloadReader(.short),
    int: PayloadReader(.int),
    long: PayloadReader(.long),
    float: PayloadReader(.float),
    double: PayloadReader(.double),
    byte_array: PayloadReader(.byte_array),
    string: PayloadReader(.string),
    list: PayloadReader(.list),
    compound: PayloadReader(.compound),
    int_array: PayloadReader(.int_array),
    long_array: PayloadReader(.long_array),

    pub fn as(self: *@This(), comptime tag: nbt.Tag) error{UnexpectedTag}!*PayloadReader(tag) {
        if (self.* != tag) return error.UnexpectedTag;
        return &@field(self.*, @tagName(tag));
    }
};

fn NumberReader(T: type) type {
    return struct {
        const Self = @This();
        const byte_width: usize = @divExact(@bitSizeOf(T), 8);
        const I = switch (T) {
            i8, i16, i32, i64 => T,
            f32, f64 => std.meta.Int(.unsigned, @bitSizeOf(T)),
            else => @compileError("unexpected type: " ++ @typeName(T)),
        };

        src: *const [Self.byte_width]u8 = undefined,

        fn init(self: *Self, src: []const u8) ParseError!void {
            if (src.len < Self.byte_width) {
                return error.UnexpectedEof;
            }
            self.src = src[0..Self.byte_width];
        }

        fn finish(_: *Self) ParseError!usize {
            return Self.byte_width;
        }

        pub fn get(self: Self) T {
            return @bitCast(std.mem.readInt(I, self.src, .big));
        }
    };
}

test "NumberReader" {
    const ts = [_]type{ i8, i16, i32, i64, f32, f64 };

    inline for (ts) |T| {
        const v = @as(T, 7);
        var r: NumberReader(T) = .{};
        try r.init(lit.primitivePayloadBytes(T, v));
        try std.testing.expectEqual(v, r.get());
        try std.testing.expectEqual(@divExact(@bitSizeOf(T), 8), try r.finish());
    }
}

fn ArrayReader(comptime T: type) type {
    switch (T) {
        i8, i32, i64 => {},
        else => @compileError("illegal instantiation"),
    }

    return struct {
        const Self = @This();
        const byte_width: usize = @divExact(@bitSizeOf(T), 8);

        src: []const u8 = undefined,

        /// length of the array (in terms of its element type, not bytes)
        len: usize = 0,

        fn init(self: *Self, src: []const u8) ParseError!void {
            const length = try readI32Length(src);

            if (src.len < 4 + byte_width * length) {
                return error.UnexpectedEof;
            }

            self.src = src[4 .. 4 + byte_width * length];
            self.len = length;
        }

        fn finish(self: *Self) ParseError!usize {
            return self.src.len + 4;
        }

        /// returns the i-th element of the array
        /// only call with i < self.len
        pub fn getIth(self: Self, i: usize) T {
            meta.assertFmt(i < self.len, "i={d} out of range 0..{d}", .{ i, self.len });
            const o = i * byte_width;
            const v, _ = readNumber(T, self.src[o .. o + byte_width]) catch unreachable;
            return v;
        }

        /// returns the raw bytes of the array, NOT including the 4 byte length prefix
        pub fn raw_bytes(self: Self) []const u8 {
            return self.src;
        }
    };
}

test "ArrayReader" {
    const t = std.testing;
    const len = 10;
    comptime var byte_array_data: []const u8 = lit.primitivePayloadBytes(i32, len);
    comptime var int_array_data: []const u8 = byte_array_data;
    comptime var long_array_data: []const u8 = byte_array_data;

    inline for (0..len) |i| {
        byte_array_data = byte_array_data ++ comptime lit.primitivePayloadBytes(i8, i);
        int_array_data = int_array_data ++ comptime lit.primitivePayloadBytes(i32, i);
        long_array_data = long_array_data ++ comptime lit.primitivePayloadBytes(i64, i);
    }

    try t.expectEqual(4 + len * 1, byte_array_data.len);

    var ba_reader = ArrayReader(i8){};
    try ba_reader.init(byte_array_data);
    var ia_reader = ArrayReader(i32){};
    try ia_reader.init(int_array_data);
    var la_reader = ArrayReader(i64){};
    try la_reader.init(long_array_data);

    try t.expectEqual(len, ba_reader.len);
    try t.expectEqual(len, ia_reader.len);
    try t.expectEqual(len, la_reader.len);

    try t.expectEqualSlices(u8, byte_array_data[4..], ba_reader.raw_bytes());
    try t.expectEqualSlices(u8, int_array_data[4..], ia_reader.raw_bytes());
    try t.expectEqualSlices(u8, long_array_data[4..], la_reader.raw_bytes());

    for (0..len) |i| {
        try t.expectEqual(@as(i8, @intCast(i)), ba_reader.getIth(i));
        try t.expectEqual(@as(i32, @intCast(i)), ia_reader.getIth(i));
        try t.expectEqual(@as(i64, @intCast(i)), la_reader.getIth(i));
    }
}

pub const StringReader = struct {
    const Self = @This();

    str: []const u8 = undefined,

    fn init(self: *Self, src: []const u8) ParseError!void {
        const res, _ = try readNbtString(src);
        self.str = res;
    }

    fn finish(self: *Self) ParseError!usize {
        return self.str.len + 2;
    }

    pub fn get(self: Self) []const u8 {
        return self.str;
    }
};

/// lower bound on the size of a valid payload in bytes
fn payloadByteSizeLB(tag: nbt.Tag) usize {
    return switch (tag) {
        .end => 0,
        .byte => 1,
        .short => 2,
        .int => 4,
        .long => 8,
        .float => 4,
        .double => 8,
        .byte_array => 4, // i32 length
        .string => 2,
        .list => 5, // element tag + i32 length
        .compound => 1, // end tag
        .int_array => 4, // i32 length
        .long_array => 4, // i32 length
    };
}

pub const ListReader = struct {
    const Self = @This();

    src: []const u8 = undefined,
    off: usize = 0,
    remaining: usize = 0,
    elements_tag: nbt.Tag = undefined,
    elements_taken: bool = false,
    element_pending: bool = false,

    len: usize = 0,

    fn init(self: *Self, src: []const u8) ParseError!void {
        const t = try readTag(src);
        self.off = 1;
        const length = try readI32Length(src[self.off..]);
        self.off += 4;

        if (t == .end and length > 0) return error.InvalidList;

        // cheap sanity check, could prevent absurdly large allocations for bad data in implList
        if (src.len - self.off < length *| payloadByteSizeLB(t)) return error.UnexpectedEof;
        // saturating mul is actually important, for example if the length is 2^31 - 1, the LB is >= 2
        // and it is running on a 32 bit platform
        //
        // (i know there are a lot of places in the code where i do not handle overflows explicitly.
        // it made sense to me to think about it here, because this is already dealing with a
        // pathological case and implList is the only place where my "derived" impl will actually
        // allocate, based on the len reported by ListReader)

        self.elements_tag = t;
        self.remaining = length;
        self.len = length;
        self.src = src;
        self.elements_taken = false;
        self.element_pending = false;
    }

    /// returns a struct that can be used to read the elements of the list
    /// may only be called once
    pub fn elements(self: *Self) ElementsReader {
        meta.assertFmt(!self.elements_taken, "ListReader.elements called more than once", .{});
        self.elements_taken = true;
        return switch (self.elements_tag) {
            .end => ElementsReader.end,
            inline else => |t| @unionInit(
                ElementsReader,
                @tagName(t),
                .{ .list = self },
            ),
        };
    }

    /// called by the ElementsReader to get the bytes for the next element, if any
    fn nextElementData(self: *Self) ?[]const u8 {
        if (self.remaining == 0) return null;

        // since we can't in general know the length of the elements bytes, we have to pass
        // the entire slice starting from a particular offset
        std.debug.assert(self.off <= self.src.len);
        meta.assertFmt(
            !self.element_pending,
            "internal error: nextElementData called while there was a pending element ",
            .{},
        );

        self.element_pending = true;
        return self.src[self.off..];
    }

    fn finish(self: *Self) ParseError!usize {
        self.off += try skipNPayloads(self.elements_tag, self.remaining, self.src[self.off..]);
        return self.off;
    }

    /// called by the ElementsReader to advance the offset of the ListReader
    fn finishElement(self: *Self, n: usize) void {
        std.debug.assert(self.off + n <= self.src.len);
        std.debug.assert(self.remaining > 0);
        self.off += n;
        self.remaining -= 1;
        self.element_pending = false;
    }
};

pub const ElementsReader = union(nbt.Tag) {
    end, // no elements
    byte: ElementsOf(.byte),
    short: ElementsOf(.short),
    int: ElementsOf(.int),
    long: ElementsOf(.long),
    float: ElementsOf(.float),
    double: ElementsOf(.double),
    byte_array: ElementsOf(.byte_array),
    string: ElementsOf(.string),
    list: ElementsOf(.list),
    compound: ElementsOf(.compound),
    int_array: ElementsOf(.int_array),
    long_array: ElementsOf(.long_array),

    /// it might be a good idea to check the lists length before using this method
    /// e.g., if you are expecting a list with element tag Tag.byte, if the list has length 0,
    /// it might have element tag Tag.end instead
    pub fn as(self: @This(), comptime tag: nbt.Tag) error{UnexpectedTag}!ElementsOf(tag) {
        if (self != tag) return error.UnexpectedTag;
        return @field(self, @tagName(tag));
    }
};

fn ElementsOf(comptime tag: nbt.Tag) type {
    return struct {
        const Self = @This();

        list: *ListReader,
        reader: PayloadReader(tag) = undefined,
        reader_active: bool = false,
        err: ?ParseError = null,

        pub fn next(self: *Self) ParseError!?*PayloadReader(tag) {
            if (self.err) |e| {
                return e;
            }
            if (self.reader_active) {
                const n = try self.reader.finish();
                self.list.finishElement(n);
                self.reader_active = false;
            }
            if (self.list.nextElementData()) |s| {
                self.reader.init(s) catch |e| {
                    self.err = e;
                    return e;
                };
                self.reader_active = true;
                return &self.reader;
            } else {
                return null;
            }
        }
    };
}
test "ListReader" {
    const t = std.testing;

    const inputs = [_][]const u8{
        "hello",
        "these",
        "are",
        "a",
        "bunch",
        "of",
        "strings",
    };

    const len = inputs.len;

    comptime var input_data: []const u8 = &nbt.Tag.string.bytes() ++ lit.primitivePayloadBytes(i32, len);

    inline for (inputs) |i| {
        input_data = input_data ++ lit.toNbtString(i);
    }

    var lr = ListReader{};
    try lr.init(input_data);

    var strings = switch (lr.elements()) {
        .string => |s| s,
        else => return error.WrongElementTag,
    };

    var idx: usize = 0;
    while (try strings.next()) |s| {
        try t.expect(idx < len);
        try t.expectEqualStrings(inputs[idx], s.get());
        idx += 1;
    }
    try t.expectEqual(len, idx);
}

const ChildData = struct {
    tag: nbt.Tag,
    name: []const u8,
    data: []const u8,
};

pub const CompoundReader = struct {
    const Self = @This();
    src: []const u8 = undefined,
    reached_end: bool = false,
    off: usize = 0,
    pending_child_off: usize = 0,
    err: ?ParseError = null,

    fn init(self: *Self, src: []const u8) ParseError!void {
        if (src.len == 0) return error.UnexpectedEof;
        self.off = 0;
        self.err = null;
        self.src = src;
        self.reached_end = false;
        self.pending_child_off = 0;
    }

    fn finish(self: *Self) ParseError!usize {
        if (self.reached_end) return self.off;
        const n = try skipCompoundPayload(self.src[self.off..]);
        self.off += n;
        self.reached_end = true;
        return self.off;
    }

    pub fn children(self: *Self) ChildReader {
        return .{ .parent = self };
    }

    fn nextChildDataInner(self: *Self) ParseError!?ChildData {
        var pending_child_off: usize = 0;
        const tag = try readTag(self.src[self.off..]);
        pending_child_off += 1;

        if (tag == .end) {
            self.reached_end = true;
            self.off += 1;
            return null;
        }

        const name, const n = try readNbtString(self.src[self.off + pending_child_off ..]);
        pending_child_off += n;

        self.pending_child_off = pending_child_off;

        return .{
            .tag = tag,
            .name = name,
            .data = self.src[self.off + pending_child_off ..],
        };
    }

    // will never return Tag.end
    fn nextChildData(self: *Self) ParseError!?ChildData {
        if (self.err) |e| return e;
        if (self.reached_end) return null;

        meta.assertFmt(
            self.pending_child_off == 0,
            "internal error: self.pending_child_off is {d} > 0 in nextChildData, " ++
                "finishChild not called for previous child",
            .{self.pending_child_off},
        );

        return self.nextChildDataInner() catch |e| {
            self.err = e;
            return e;
        };
    }

    fn finishChild(self: *Self, n: usize) void {
        meta.assertFmt(
            self.pending_child_off > 0,
            "internal error: self.pending_child_off == 0 in finishChild",
            .{},
        );

        std.debug.assert(self.off + n + self.pending_child_off <= self.src.len);

        self.off += n + self.pending_child_off;
        self.pending_child_off = 0;
    }
};

test "CompoundReader" {
    const t = std.testing;

    const Nested = struct {
        a: i32,
    };

    const SomeStruct = struct {
        x: i32,
        name: []const u8,
        cool: i8,
        inner: Nested,
    };

    const val = SomeStruct{
        .x = 7,
        .name = "wow",
        .cool = -1,
        .inner = Nested{ .a = 100 },
    };

    const data = lit.encodeCompoundPayload(SomeStruct, val);

    try t.expectEqual(nbt.Tag.end.into_u8(), data[data.len - 1]);

    var reader = CompoundReader{};

    try reader.init(data);

    var children = reader.children();

    const first_ch = try children.next() orelse return error.MissingChild;
    try t.expectEqualStrings("x", first_ch.name);
    try t.expectEqual(7, first_ch.reader.int.get());

    const second_ch = try children.next() orelse return error.MissingChild;
    try t.expectEqualStrings("name", second_ch.name);
    try t.expectEqualStrings("wow", first_ch.reader.string.get());

    const third_ch = try children.next() orelse return error.MissingChild;
    try t.expectEqualStrings("cool", third_ch.name);
    try t.expectEqual(-1, first_ch.reader.byte.get());

    const fourth_ch = try children.next() orelse return error.MissingChild;
    try t.expectEqualStrings("inner", fourth_ch.name);
    var inner_children = fourth_ch.reader.compound.children();

    const first_inner_ch = try inner_children.next() orelse return error.MissingChild;
    try t.expectEqualStrings("a", first_inner_ch.name);
    try t.expectEqual(100, first_inner_ch.reader.int.get());

    if (try children.next()) |_| {
        return error.ExtraChild;
    }
}

pub const Child = struct {
    name: []const u8,
    reader: *AnyPayloadReader,
};

pub const ChildReader = struct {
    const Self = @This();
    parent: *CompoundReader,
    reader: AnyPayloadReader = undefined,
    reader_active: bool = false,
    err: ?ParseError = null,

    /// gets the next child tag, if any
    /// WARN: the reader contained in Child is only valid until the next call of next
    pub fn next(self: *Self) ParseError!?Child {
        if (self.err) |e| return e;
        return self.nextInner() catch |e| {
            self.err = e;
            return e;
        };
    }

    fn nextInner(self: *Self) ParseError!?Child {
        if (self.reader_active) {
            const n = switch (self.reader) {
                .end => meta.unreachableFmt("self.reader on ChildReader was Tag.end variant", .{}),
                inline else => |*r| try r.finish(),
            };

            self.parent.finishChild(n);
            self.reader_active = false;
        }

        const c = try self.parent.nextChildData() orelse return null;

        switch (c.tag) {
            .end => meta.unreachableFmt("CompoundReader.nextChildData returned Tag.end variant", .{}),
            inline else => |t| {
                self.reader = @unionInit(AnyPayloadReader, @tagName(t), undefined);
                try @field(self.reader, @tagName(t)).init(c.data);
                self.reader_active = true;
                return .{ .name = c.name, .reader = &self.reader };
            },
        }
    }
};

fn tagFor(comptime T: type, comptime Impl: type) ?nbt.Tag {
    if (meta.getFn(Impl, "parsePayloadInto")) |f| {
        inline for (comptime std.enums.values(nbt.Tag)) |tg| {
            if (tg != .end and @TypeOf(f) == fn (*T, *PayloadReader(tg), std.mem.Allocator) ParseError!void) {
                return tg;
            }
        }
        @compileError("CUM" ++ @typeName(@TypeOf(f)));
    }

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

/// used to generate a method parsePayloadInto on a struct
/// cf. chunk_test.zig for usage
pub fn deriveParsePayloadInto(comptime T: type) fn (
    *T,
    *PayloadReader(nbt.Tag.compound),
    std.mem.Allocator,
) ParseError!void {
    return deriveStructImpl(T).unwrap().ty.parsePayloadInto;
}

// TODO: use to ignore fields for parsing
pub fn Ignore(comptime T: type) type {
    return std.enums.EnumFieldStruct(std.meta.FieldEnum(T), bool, false);
}

fn getIgnoredFields(comptime T: type) Ignore(T) {
    if (meta.getConst(T, "nbt_ignore")) |c| {
        if (@TypeOf(c) != Ignore(T)) @compileError(std.fmt.comptimePrint(
            "expected {s}.nbt_ignore to be of type {s} but found {s}",
            .{
                @typeName(T),
                @typeName(Ignore(T)),
                @typeName(@TypeOf(c)),
            },
        ));
        return c;
    } else {
        return Ignore(T){};
    }
}

test "getIgnoredFields" {
    const S = struct {
        x: i8,
        a: std.mem.Allocator,

        pub const nbt_ignore: Ignore(@This()) = .{ .a = true };

        // TODO: remove ignored fields from Rename
        pub const nbt_names: Rename(@This()) = .{ .a = "x", .x = "x" };
    };
    const ig = getIgnoredFields(S);
    try std.testing.expect(ig.a == true);
    try std.testing.expect(ig.x == false);
}

/// used to map struct field names to nbt tag names for parsing
pub fn Rename(comptime T: type) type {
    return std.enums.EnumFieldStruct(
        std.meta.FieldEnum(T),
        ?[]const u8,
        // necessary coercion, otherwise the null is taken as "?Data" (no default value),
        @as(?[]const u8, null),
    );
}

pub fn Names(comptime T: type) type {
    return struct {
        const Self = @This();

        names: std.enums.EnumArray(std.meta.FieldEnum(T), []const u8),
        static_map: std.StaticStringMap(std.meta.FieldEnum(T)),

        fn get(self: Self, tag: std.meta.FieldEnum(T)) []const u8 {
            return self.names.get(tag);
        }

        pub fn init(comptime rename: Rename(T)) Self {
            return comptime Self.tryInit(rename).unwrap();
        }

        fn initDefault() Self {
            return comptime blk: {
                const F = std.meta.FieldEnum(T);
                var field_names = std.enums.EnumArray(F, []const u8).initUndefined();

                for (std.enums.values(F)) |f| {
                    const name = @tagName(f);

                    // technically need to check (m)UTF-8 here too
                    if (name.len > std.math.maxInt(u16)) @compileError(std.fmt.comptimePrint(
                        "{s}: name '{s}...' is too long (max. 65535 bytes)",
                        .{ @typeName(T), name[0..64] },
                    ));
                    field_names.set(f, name);
                }

                // names unique by construction
                break :blk .{
                    .names = field_names,
                    .static_map = Self.initMap(field_names),
                };
            };
        }

        fn initMap(comptime arr: std.enums.EnumArray(
            std.meta.FieldEnum(T),
            []const u8,
        )) std.StaticStringMap(std.meta.FieldEnum(T)) {
            const fields = std.enums.values(std.meta.FieldEnum(T));

            comptime var pairs: [fields.len]struct { []const u8, std.meta.FieldEnum(T) } = undefined;

            for (fields, 0..) |f, i| pairs[i] = .{ arr.get(f), f };

            return .initComptime(pairs);
        }

        fn tryInit(comptime rename: Rename(T)) meta.ComptimeResult(Self) {
            const F = std.meta.FieldEnum(T);
            var field_names = std.enums.EnumArray(F, []const u8).initUndefined();

            for (std.enums.values(F)) |f| {
                const name = @field(rename, @tagName(f)) orelse @tagName(f);
                field_names.set(f, name);
            }

            const vals = std.enums.values(F);

            for (vals, 0..) |a, i| {

                // technically need to check (m)UTF8 here too
                // (and ideally the truncation for display should be at a UTF8 boundary)
                if (field_names.get(a).len > std.math.maxInt(u16)) return .initErr(std.fmt.comptimePrint(
                    "{s}: name '{s}...' is too long (max. 65535 bytes)",
                    .{ @typeName(T), field_names.get(a)[0..64] },
                ));

                for (vals[i + 1 ..]) |b| {
                    if (std.mem.eql(u8, field_names.get(a), field_names.get(b))) {
                        return .initErr(std.fmt.comptimePrint(
                            "{s}: fields '{s}' and '{s}' both map to NBT name '{s}'",
                            .{ @typeName(T), @tagName(a), @tagName(b), field_names.get(a) },
                        ));
                    }
                }
            }

            return .initOk(.{
                .names = field_names,
                .static_map = Self.initMap(field_names),
            });
        }

        fn stringToFieldEnum(self: Self, str: []const u8) ?std.meta.FieldEnum(T) {
            return self.static_map.get(str);
        }
    };
}

test "Names" {
    const t = std.testing;

    const SomeStruct = struct {
        hello: i8,
        world: []const u8,
    };

    {
        const res = comptime Names(SomeStruct).tryInit(.{
            .hello = "world",
        });

        // duplicate name "world"
        try t.expect(res.isErr());
    }

    {
        const res = comptime Names(SomeStruct).tryInit(.{
            .hello = "HELLO",
            .world = "WORLD",
        });

        try t.expect(res.isOk());

        const names = res.unwrap();

        // renaming worked, duplicate checking is done after all names are resolved, so if a field
        // is renamed, the old value can still be used as the new name of another field
        try t.expectEqualStrings("HELLO", names.get(.hello));
        try t.expectEqualStrings("WORLD", names.get(.world));

        const F = std.meta.FieldEnum(SomeStruct);

        // mapping names back to fields
        try t.expectEqual(
            @field(F, "world"),
            names.stringToFieldEnum("WORLD") orelse return error.TestFailed,
        );
        try t.expectEqual(
            @field(F, "hello"),
            names.stringToFieldEnum("HELLO") orelse return error.TestFailed,
        );
    }
}

const FieldInfo = struct {
    name: []const u8,
    impl: ParseImpl,
};

fn deriveStructImpl(comptime T: type) meta.ComptimeResult(ParseImpl) {
    const info = @typeInfo(T);

    if (info != .@"struct" or (info == .@"struct" and info.@"struct".is_tuple))
        return .initErr(std.fmt.comptimePrint(
            "unsupported type {s}, should be a non-tuple struct",
            .{@typeName(T)},
        ));

    const FieldEnum = std.meta.FieldEnum(T);

    // checking for declared field name overrides, otherwise taking default names
    // (which are just the zig struct names)
    const field_names = meta.getConst(T, "nbt_names") orelse Names(T).initDefault();
    _ = comptime field_names;

    comptime var field_impls_var = std.EnumArray(
        FieldEnum,
        ParseImpl,
    ).initUndefined();

    for (std.enums.values(FieldEnum)) |f| {
        const r = resolveImpl(@FieldType(T, @tagName(f)));
        switch (r) {
            .ok => |rr| field_impls_var.set(f, rr),
            .err => return r,
        }
    }

    const field_impls = field_impls_var;

    return .initOk(.{
        .ty = struct {
            pub fn parsePayloadInto(
                dst: *T,
                reader: *PayloadReader(nbt.Tag.compound),
                alloc: std.mem.Allocator,
            ) ParseError!void {
                var result: T = undefined;
                var seen = std.EnumSet(FieldEnum).initEmpty();

                var children = reader.children();

                while (try children.next()) |c| {
                    const field = field_names.stringToFieldEnum(c.name) orelse continue;

                    if (@typeInfo(FieldEnum).@"enum".fields.len > 0) {
                        // guarding against `error: unreachable else prong; all cases already handled`
                        // cf test "deriveParsePayloadInto with no fields"
                        switch (field) {
                            inline else => |f| {
                                const FieldImpl = field_impls.get(f);

                                if (seen.contains(field)) return error.DuplicateField;

                                const field_reader = try c.reader.as(FieldImpl.tag);

                                try FieldImpl.ty.parsePayloadInto(
                                    &@field(result, @tagName(f)),
                                    field_reader,
                                    alloc,
                                );

                                seen.insert(field);
                            },
                        }
                    }
                }

                inline for (comptime std.enums.values(FieldEnum)) |f| {
                    if (!seen.contains(f)) {
                        const fi = std.meta.fieldInfo(T, f);
                        if (fi.defaultValue()) |d| {
                            @field(result, @tagName(f)) = d;
                        } else {
                            return error.MissingField;
                        }
                    }
                }

                dst.* = result;
            }
        },
        .tag = .compound,
    });
}

test "deriveParsePayloadInto with no fields" {
    const t = std.testing;

    const S = struct {
        pub const parsePayloadInto = deriveParsePayloadInto(@This());
    };

    // S has no fields, but deriving parsePayloadInto should still work
    // this effectively expects to find SOME well-formed compound tag, which is discarded

    const Outer = struct {
        x: i8,
        some_inner_compound: S,
        z: i32,

        pub const parsePayloadInto = deriveParsePayloadInto(@This());
    };

    // just used for data generation
    const Data = struct {
        z: i32 = -100,
        x: i8 = 3,
        some_inner_compound: struct {
            a: []const u8 = "hello",
            long: i64 = 12345,
        } = .{},
    };
    const data = lit.encodeTag(Data, "root", .{});

    const res = try parseLeaky(Outer, std.testing.allocator, data);
    try t.expectEqualStrings("root", res.name);
    try t.expectEqual(data.len, res.bytes_read);
    try t.expectEqual(res.val.x, 3);
    try t.expectEqual(res.val.z, -100);
    try t.expectEqual(res.val.some_inner_compound, S{});

    // now we know that the data we parsed into the struct "Outer" was a compound tag
    // and had a child compound tag named "some_compound" with arbitrary (but well-formed) content

    // if the there is no such child tag, the parse fails:

    const Data2 = struct {
        z: i32 = -100,
        x: i8 = 3,
    };

    const data2 = lit.encodeTag(Data2, "root", .{});

    try t.expectError(nbt.ParseError.MissingField, parseLeaky(
        Outer,
        std.testing.allocator,
        data2,
    ));
}

fn requireImpl(comptime T: type) meta.ComptimeResult(ParseImpl) {
    if (meta.getFn(T, "parsePayloadInto")) |f| {
        inline for (comptime std.enums.values(nbt.Tag)) |tg| {
            if (tg != .end and @TypeOf(f) == fn (*T, *PayloadReader(tg), std.mem.Allocator) ParseError!void) {
                return .initOk(.{ .ty = T, .tag = tg });
            }
        }
        return .initErr(std.fmt.comptimePrint("expected {s}.parsePayloadInto to be of type fn " ++
            "(*{s}, nbt.PayloadReader(t), std.mem.Allocator) nbt.ParseError!void with t != Tag.end but found {s}", .{
            @typeName(T),
            @typeName(T),
            @typeName(@TypeOf(f)),
        }));
    } else {
        return .initErr(std.fmt.comptimePrint("expected {s}.parsePayloadInto to be of type fn " ++
            "(*{s}, nbt.PayloadReader(t), std.mem.Allocator) nbt.ParseError!void with t != Tag.end but found no " ++
            "(pub) function with that name", .{
            @typeName(T),
            @typeName(T),
        }));
    }
}

const ParseImpl = struct {
    // type that has a function parsePayloadInto(..., *PayloadReader(tag), ...)
    ty: type,
    // the actual tag value matching the signature of the above fn (never Tag.end)
    tag: nbt.Tag,
};

pub fn resolveImpl(comptime T: type) meta.ComptimeResult(ParseImpl) {
    if (meta.isContainer(T)) return requireImpl(T);

    switch (T) {
        i8, i16, i32, i64, f32, f64, []const u8 => return implPrimitive(T),
        else => {
            const info = @typeInfo(T);
            if (info == .pointer and info.pointer.size == .slice) {
                return implList(T);
            }
        },
    }
    return .initErr("unsupported type: " ++ @typeName(T));
}

fn implPrimitive(comptime T: type) meta.ComptimeResult(ParseImpl) {
    switch (T) {
        i8, i16, i32, i64, f32, f64, []const u8 => |Ty| {
            const tag: nbt.Tag = switch (Ty) {
                i8 => .byte,
                i16 => .short,
                i32 => .int,
                i64 => .long,
                f32 => .float,
                f64 => .double,
                []const u8 => .string,
                else => @compileError("internal error: " ++ @typeName(T) ++ " is not a primitive"),
            };

            return .initOk(.{
                .ty = struct {
                    pub fn parsePayloadInto(
                        dst: *T,
                        reader: *PayloadReader(tag),
                        _: std.mem.Allocator,
                    ) ParseError!void {
                        // works uniformly for all primitives right now
                        dst.* = reader.get();
                    }
                },
                .tag = tag,
            });
        },
        else => @compileError("internal error: " ++ @typeName(T) ++ " is not a primitive"),
    }
}

fn implList(comptime T: type) meta.ComptimeResult(ParseImpl) {
    const info = @typeInfo(T);
    if ((info != .pointer) or (info == .pointer and info.pointer.size != .slice))
        @compileError("internal error: " ++ @typeName(T) ++ " is not a slice type");
    return .initOk(.{
        .ty = struct {
            const ElemImpl = resolveImpl(@typeInfo(T).pointer.child).unwrap();
            pub fn parsePayloadInto(dst: *T, reader: *PayloadReader(.list), allocator: std.mem.Allocator) ParseError!void {
                const el = reader.elements();

                if (el == .end) return; // list must be empty

                var elems = try el.as(ElemImpl.tag);

                var d = try allocator.alloc(@typeInfo(T).pointer.child, reader.len);

                var idx: usize = 0;
                while (try elems.next()) |c| : (idx += 1) {
                    try ElemImpl.ty.parsePayloadInto(&d[idx], c, allocator);
                }

                dst.* = d;
            }
        },
        .tag = .list,
    });
}

pub fn parseLeaky(comptime T: type, alloc: std.mem.Allocator, src: []const u8) !struct {
    name: []const u8,
    val: T,
    bytes_read: usize,
} {
    const t = comptime tagFor(T, T) orelse @compileError(@typeName(T) ++
        " does not have required stuff");

    if (try readTag(src) != t) return error.UnexpectedTag;

    var off: usize = 1;
    const name, const n = try readNbtString(src[off..]);
    off += n;

    var reader = PayloadReader(t){};

    try reader.init(src[off..]);

    var val: T = undefined;

    try val.parsePayloadInto(&reader, alloc);

    off += try reader.finish();

    return .{ .name = name, .val = val, .bytes_read = off };
}

test "parseLeaky" {
    const t = std.testing;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const SomeCompound = struct {
        x: i8 = 0,
        name: []const u8 = "",

        pub fn parsePayloadInto(self: *@This(), reader: *PayloadReader(.compound), _: std.mem.Allocator) ParseError!void {
            var children = reader.children();
            while (try children.next()) |c| {
                if (std.mem.eql(u8, c.name, "x")) self.x = (try c.reader.as(.byte)).get();
                if (std.mem.eql(u8, c.name, "name")) self.name = (try c.reader.as(.string)).get();
            }
        }
    };

    const val = SomeCompound{
        .x = 17,
        .name = "ziggy",
    };

    const data = lit.encodeTag(SomeCompound, "root", val);

    const res = try parseLeaky(SomeCompound, alloc, data);

    try t.expectEqualStrings("root", res.name);
    try t.expectEqualDeep(val, res.val);
}

pub fn readTag(src: []const u8) ParseError!nbt.Tag {
    return if (src.len == 0)
        error.UnexpectedEof
    else
        nbt.Tag.fromByte(src[0]);
}

/// reads a nbt string (u16 length prefix l, then l bytes)
/// returns the string and the number of bytes read
/// WARN: not checked for (m)UTF-8
pub fn readNbtString(src: []const u8) ParseError!struct { []const u8, usize } {
    if (src.len < 2) {
        return error.UnexpectedEof;
    }

    const len = @as(usize, std.mem.readInt(u16, src[0..2], std.builtin.Endian.big));

    return if (src.len < 2 + len) error.UnexpectedEof else .{ src[2 .. 2 + len], 2 + len };
}

/// reads an i32 for usage as a length (lists, arrays)
/// WARN: returned usize is the length, remember to advance 4 bytes on success
pub fn readI32Length(src: []const u8) ParseError!usize {
    const l, _ = try readNumber(i32, src);
    if (l < 0) {
        return ParseError.InvalidLength;
    }
    return @intCast(l);
}

/// reads a numeric payload, returns the value and the number of bytes read
pub fn readNumber(comptime T: type, src: []const u8) ParseError!struct { T, usize } {
    const I = switch (T) {
        i8, i16, i32, i64 => T,
        f32, f64 => std.meta.Int(.unsigned, @bitSizeOf(T)),
        else => @compileError("unexpected type: " ++ @typeName(T)),
    };

    const byte_width: usize = @divExact(@bitSizeOf(T), 8);

    if (src.len < byte_width) {
        return error.UnexpectedEof;
    }

    const val: T = @bitCast(std.mem.readInt(I, src[0..byte_width], .big));
    return .{ val, byte_width };
}

fn skipString(src: []const u8) ParseError!usize {
    if (src.len < 2) {
        return error.UnexpectedEof;
    }
    const len = @as(usize, std.mem.readInt(u16, src[0..2], std.builtin.Endian.big));
    return skipN(2 + len, src);
}

fn hasFixedSizePayload(tag: nbt.Tag) ?usize {
    return switch (tag) {
        .byte => 1,
        .short => 2,
        .int => 4,
        .long => 8,
        .float => 4,
        .double => 8,
        else => null,
    };
}

pub fn skipListPayload(src: []const u8) ParseError!usize {
    const elem = try readTag(src);
    const len = try readI32Length(src[1..]);

    if (elem == .end) return if (len > 0) ParseError.InvalidList else 5;

    var off: usize = 5;
    off += try skipNPayloads(elem, len, src[off..]);
    return off;
}

pub fn skipNPayloads(tag: nbt.Tag, n: usize, src: []const u8) ParseError!usize {
    std.debug.assert(n <= std.math.maxInt(i32));

    if (hasFixedSizePayload(tag)) |s| {
        return skipN(n * s, src);
    } else {
        var off: usize = 0;
        for (0..n) |_| {
            off += try skipPayload(tag, src[off..]);
        }
        return off;
    }
}

fn skipN(n: usize, src: []const u8) ParseError!usize {
    return if (src.len < n) error.UnexpectedEof else n;
}

fn skipCompoundPayload(src: []const u8) ParseError!usize {
    var off: usize = 0;
    while (true) {
        const tag = try readTag(src[off..]);
        off += 1;
        if (tag == .end) break;
        off += try skipString(src[off..]);
        off += try skipPayload(tag, src[off..]);
    }

    return off;
}

/// skips the payload associated with tag, returns the number of bytes skipped
/// WARN: should not be called with Tag.end
fn skipPayload(tag: nbt.Tag, src: []const u8) ParseError!usize {
    return switch (tag) {
        .byte => skipN(1, src),
        .short => skipN(2, src),
        .int => skipN(4, src),
        .long => skipN(8, src),
        .float => skipN(4, src),
        .double => skipN(8, src),
        .list => skipListPayload(src),
        inline .byte_array, .int_array, .long_array => |t| blk: {
            const len = try readI32Length(src);
            const off = 4;

            const elem_tag: nbt.Tag = switch (t) {
                .byte_array => .byte,
                .int_array => .int,
                .long_array => .long,
                else => unreachable,
            };

            break :blk off + try skipNPayloads(elem_tag, len, src[off..]);
        },
        .string => skipString(src),
        .compound => skipCompoundPayload(src),
        .end => meta.unreachableFmt("skipPayload called with Tag.end", .{}),
    };
}
