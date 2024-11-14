//! This module handles the generation of Zig code for repeated enum fields in Protocol Buffers.
//! Repeated enum fields can appear zero or more times in a message and support packing optimization.
//! When packed, multiple enum values are encoded together in a single length-delimited field.
//! The module supports both packed and unpacked representations for backward compatibility.

//               .'\   /`.
//             .'.-.`-'.-.`.
//        ..._:   .-. .-.   :_...
//      .'    '-.(o ) (o ).-'    `.
//     :  _    _ _`~(_)~`_ _    _  :
//    :  /:   ' .-=_   _=-. `   ;\  :
//    :   :|-.._  '     `  _..-|:   :
//     :   `:| |`:-:-.-:-:'| |:'   :
//      `.   `.| | | | | | |.'   .'
//        `.   `-:_| | |_:-'   .'
//          `-._   ````    _.-'
//              ``-------''
//
// Created by ab, 11.11.2024

const std = @import("std");
const naming = @import("naming.zig");
const fields =  @import("../../../parser/main.zig").fields;
const FieldType =  @import("../../../parser/main.zig").FieldType;
const Option =  @import("../../../parser/main.zig").Option;

/// Represents a repeated enum field in Protocol Buffers.
/// Handles both packed and unpacked encoding formats, with specialized
/// reader implementation to support both formats transparently.
pub const ZigRepeatableEnumField = struct {
    // Memory management
    allocator: std.mem.Allocator,

    // Owned struct
    writer_struct_name: []const u8,
    reader_struct_name: []const u8,

    // Field properties
    target_type: FieldType, // Type information from protobuf
    resolved_enum: ?[]const u8 = null, // Full name of the enum type in Zig

    // Generated names for field access
    writer_field_name: []const u8, // Name in writer struct
    reader_field_name: []const u8, // Internal name in reader struct
    reader_method_name: []const u8, // Public getter method name

    // Reader implementation details
    reader_offsets_name: []const u8, // Name for offset storage array
    reader_wires_name: []const u8, // Name for wire type storage array

    // Wire format metadata
    wire_const_full_name: []const u8, // Full qualified wire constant name
    wire_const_name: []const u8, // Short wire constant name
    wire_index: i32, // Field number in protocol

    /// Initialize a new ZigRepeatableEnumField with the given parameters
    pub fn init(
        allocator: std.mem.Allocator,
        field_name: []const u8,
        field_type: FieldType,
        field_index: i32,
        wire_prefix: []const u8,
        names: *std.ArrayList([]const u8),
        writer_struct_name: []const u8,
        reader_struct_name: []const u8,
    ) !ZigRepeatableEnumField {
        // Generate field name for the writer struct
        const name = try naming.structFieldName(allocator, field_name, names);

        // Generate wire format constant names
        const wirePostfixed = try std.mem.concat(allocator, u8, &[_][]const u8{ field_name, "Wire" });
        defer allocator.free(wirePostfixed);
        const wireConstName = try naming.constName(allocator, wirePostfixed, names);
        const wireName = try std.mem.concat(allocator, u8, &[_][]const u8{
            wire_prefix,
            ".",
            wireConstName,
        });

        // Generate reader method name
        const reader_prefixed = try std.mem.concat(allocator, u8, &[_][]const u8{ "get_", field_name });
        defer allocator.free(reader_prefixed);
        const readerMethodName = try naming.structMethodName(allocator, reader_prefixed, names);

        // Generate internal reader names
        const reader_field = try std.mem.concat(allocator, u8, &[_][]const u8{ "_", name });
        const reader_offsets = try std.mem.concat(allocator, u8, &[_][]const u8{ "_", name, "_offsets" });
        const reader_wires = try std.mem.concat(allocator, u8, &[_][]const u8{ "_", name, "_wires" });

        return ZigRepeatableEnumField{
            .allocator = allocator,
            .target_type = field_type,
            .writer_field_name = name,
            .reader_field_name = reader_field,
            .reader_method_name = readerMethodName,
            .reader_offsets_name = reader_offsets,
            .reader_wires_name = reader_wires,
            .wire_const_full_name = wireName,
            .wire_const_name = wireConstName,
            .wire_index = field_index,
            .writer_struct_name = writer_struct_name,
            .reader_struct_name = reader_struct_name,
        };
    }

    /// Set the resolved enum type name after type resolution phase
    pub fn resolve(self: *ZigRepeatableEnumField, resolvedEnum: []const u8) !void {
        if (self.resolved_enum) |e| {
            self.allocator.free(e);
        }
        self.resolved_enum = try self.allocator.dupe(u8, resolvedEnum);
    }

    /// Clean up allocated memory
    pub fn deinit(self: *ZigRepeatableEnumField) void {
        if (self.resolved_enum) |e| {
            self.allocator.free(e);
        }
        self.allocator.free(self.writer_field_name);
        self.allocator.free(self.reader_field_name);
        self.allocator.free(self.reader_method_name);
        self.allocator.free(self.reader_offsets_name);
        self.allocator.free(self.reader_wires_name);
        self.allocator.free(self.wire_const_full_name);
        self.allocator.free(self.wire_const_name);
    }

    /// Generate wire format constant declaration
    pub fn createWireConst(self: *const ZigRepeatableEnumField) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "const {s}: gremlin.ProtoWireNumber = {d};", .{ self.wire_const_name, self.wire_index });
    }

    /// Generate writer struct field declaration
    pub fn createWriterStructField(self: *const ZigRepeatableEnumField) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}: ?[]const {s} = null,", .{ self.writer_field_name, self.resolved_enum.? });
    }

    /// Generate size calculation code for serialization.
    /// Handles special cases for empty arrays, single values, and packed encoding.
    pub fn createSizeCheck(self: *const ZigRepeatableEnumField) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\if (self.{s}) |arr| {{
            \\    if (arr.len == 0) {{
            \\    }} else if (arr.len == 1) {{
            \\        res += gremlin.sizes.sizeWireNumber({s}) + gremlin.sizes.sizeI32(@intFromEnum(arr[0]));
            \\    }} else {{
            \\        var packed_size: usize = 0;
            \\        for (arr) |v| {{
            \\            packed_size += gremlin.sizes.sizeI32(@intFromEnum(v));
            \\        }}
            \\        res += gremlin.sizes.sizeWireNumber({s}) + gremlin.sizes.sizeUsize(packed_size) + packed_size;
            \\    }}
            \\}}
        , .{
            self.writer_field_name,
            self.wire_const_full_name,
            self.wire_const_full_name,
        });
    }

    /// Generate serialization code.
    /// Uses packed encoding for multiple values for efficiency.
    pub fn createWriter(self: *const ZigRepeatableEnumField) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\if (self.{s}) |arr| {{
            \\    if (arr.len == 0) {{
            \\    }} else if (arr.len == 1) {{
            \\        target.appendInt32({s}, @intFromEnum(arr[0]));
            \\    }} else {{
            \\        var packed_size: usize = 0;
            \\        for (arr) |v| {{
            \\            packed_size += gremlin.sizes.sizeI32(@intFromEnum(v));
            \\        }}
            \\        target.appendBytesTag({s}, packed_size);
            \\        for (arr) |v| {{
            \\            target.appendInt32WithoutTag(@intFromEnum(v));
            \\        }}
            \\    }}
            \\}}
        , .{
            self.writer_field_name,
            self.wire_const_full_name,
            self.wire_const_full_name,
        });
    }

    /// Generate reader struct field declaration.
    /// Uses separate arrays for offsets and wire types to support both encoding formats.
    pub fn createReaderStructField(self: *const ZigRepeatableEnumField) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\{s}: ?std.ArrayList(usize) = null,
            \\{s}: ?std.ArrayList(gremlin.ProtoWireType) = null,
        , .{
            self.reader_offsets_name,
            self.reader_wires_name,
        });
    }

    /// Generate deserialization case statement.
    /// Stores offset and wire type information for later processing.
    pub fn createReaderCase(self: *const ZigRepeatableEnumField) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\{s} => {{
            \\    if (res.{s} == null) {{
            \\        res.{s} = std.ArrayList(usize).init(allocator);
            \\        res.{s} = std.ArrayList(gremlin.ProtoWireType).init(allocator);
            \\    }}
            \\    try res.{s}.?.append(offset);
            \\    try res.{s}.?.append(tag.wire);
            \\    if (tag.wire == gremlin.ProtoWireType.bytes) {{
            \\        const length_result = try buf.readVarInt(offset);
            \\        offset += length_result.size + length_result.value;
            \\    }} else {{
            \\        const result = try buf.readInt32(offset);
            \\        offset += result.size;
            \\    }}
            \\}},
        , .{
            self.wire_const_full_name,
            self.reader_offsets_name,
            self.reader_offsets_name,
            self.reader_wires_name,
            self.reader_offsets_name,
            self.reader_wires_name,
        });
    }

    /// Generate getter method that constructs enum array from stored offsets.
    /// Handles both packed and unpacked formats transparently.
    pub fn createReaderMethod(self: *const ZigRepeatableEnumField) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\pub fn {s}(self: *const {s}, allocator: std.mem.Allocator) gremlin.Error![]{s} {{
            \\    if (self.{s}) |offsets| {{
            \\        if (offsets.items.len == 0) return &[_]{s}{{}};
            \\
            \\        var result = std.ArrayList({s}).init(allocator);
            \\        errdefer result.deinit();
            \\
            \\        for (offsets.items, self.{s}.?.items) |start_offset, wire_type| {{
            \\            if (wire_type == .bytes) {{
            \\                const length_result = try self.buf.readVarInt(start_offset);
            \\                var offset = start_offset + length_result.size;
            \\                const end_offset = offset + length_result.value;
            \\
            \\                while (offset < end_offset) {{
            \\                    const value_result = try self.buf.readInt32(offset);
            \\                    try result.append(@enumFromInt(value_result.value));
            \\                    offset += value_result.size;
            \\                }}
            \\            }} else {{
            \\                const value_result = try self.buf.readInt32(start_offset);
            \\                try result.append(@enumFromInt(value_result.value));
            \\            }}
            \\        }}
            \\        return result.toOwnedSlice();
            \\    }}
            \\    return &[_]{s}{{}};
            \\}}
        , .{ self.reader_method_name, self.reader_struct_name, self.resolved_enum.?, self.reader_offsets_name, self.resolved_enum.?, self.resolved_enum.?, self.reader_wires_name, self.resolved_enum.? });
    }

    /// Generate cleanup code for reader's temporary storage
    pub fn createReaderDeinit(self: *const ZigRepeatableEnumField) ![]const u8 {
        return std.fmt.allocPrint(self.allocator,
            \\if (self.{s}) |arr| {{
            \\    arr.deinit();
            \\}}
            \\if (self.{s}) |arr| {{
            \\    arr.deinit();
            \\}}
        , .{
            self.reader_offsets_name,
            self.reader_wires_name,
        });
    }

    /// Indicates whether the reader needs an allocator (always true for repeated fields)
    pub fn readerNeedsAllocator(_: *const ZigRepeatableEnumField) bool {
        return true;
    }
};

test "basic repeatable enum field" {
    const ScopedName =  @import("../../../parser/main.zig").ScopedName;
    const ParserBuffer =  @import("../../../parser/main.zig").ParserBuffer;

    var scope = try ScopedName.init(std.testing.allocator, "");
    defer scope.deinit();

    var buf = ParserBuffer.init("repeated TestEnum enum_field = 1;");
    var f = try fields.NormalField.parse(std.testing.allocator, scope, &buf);
    defer f.deinit();

    var names = std.ArrayList([]const u8).init(std.testing.allocator);
    defer names.deinit();

    var zig_field = try ZigRepeatableEnumField.init(
        std.testing.allocator,
        f.f_name,
        f.f_type,
        f.index,
        "TestWire",
        &names,
        "TestWriter",
        "TestReader",
    );
    try zig_field.resolve("messages.TestEnum");
    defer zig_field.deinit();

    // Test wire constant
    const wire_const_code = try zig_field.createWireConst();
    defer std.testing.allocator.free(wire_const_code);
    try std.testing.expectEqualStrings("const ENUM_FIELD_WIRE: gremlin.ProtoWireNumber = 1;", wire_const_code);

    // Test writer field
    const writer_field_code = try zig_field.createWriterStructField();
    defer std.testing.allocator.free(writer_field_code);
    try std.testing.expectEqualStrings("enum_field: ?[]const messages.TestEnum = null,", writer_field_code);

    // Test size check
    const size_check_code = try zig_field.createSizeCheck();
    defer std.testing.allocator.free(size_check_code);
    try std.testing.expectEqualStrings(
        \\if (self.enum_field) |arr| {
        \\    if (arr.len == 0) {
        \\    } else if (arr.len == 1) {
        \\        res += gremlin.sizes.sizeWireNumber(TestWire.ENUM_FIELD_WIRE) + gremlin.sizes.sizeI32(@intFromEnum(arr[0]));
        \\    } else {
        \\        var packed_size: usize = 0;
        \\        for (arr) |v| {
        \\            packed_size += gremlin.sizes.sizeI32(@intFromEnum(v));
        \\        }
        \\        res += gremlin.sizes.sizeWireNumber(TestWire.ENUM_FIELD_WIRE) + gremlin.sizes.sizeUsize(packed_size) + packed_size;
        \\    }
        \\}
    , size_check_code);

    // Test writer
    const writer_code = try zig_field.createWriter();
    defer std.testing.allocator.free(writer_code);
    try std.testing.expectEqualStrings(
        \\if (self.enum_field) |arr| {
        \\    if (arr.len == 0) {
        \\    } else if (arr.len == 1) {
        \\        target.appendInt32(TestWire.ENUM_FIELD_WIRE, @intFromEnum(arr[0]));
        \\    } else {
        \\        var packed_size: usize = 0;
        \\        for (arr) |v| {
        \\            packed_size += gremlin.sizes.sizeI32(@intFromEnum(v));
        \\        }
        \\        target.appendBytesTag(TestWire.ENUM_FIELD_WIRE, packed_size);
        \\        for (arr) |v| {
        \\            target.appendInt32WithoutTag(@intFromEnum(v));
        \\        }
        \\    }
        \\}
    , writer_code);

    // Test reader field
    const reader_field_code = try zig_field.createReaderStructField();
    defer std.testing.allocator.free(reader_field_code);
    try std.testing.expectEqualStrings(
        \\_enum_field_offsets: ?std.ArrayList(usize) = null,
        \\_enum_field_wires: ?std.ArrayList(gremlin.ProtoWireType) = null,
    , reader_field_code);

    // Test reader case
    const reader_case_code = try zig_field.createReaderCase();
    defer std.testing.allocator.free(reader_case_code);
    try std.testing.expectEqualStrings(
        \\TestWire.ENUM_FIELD_WIRE => {
        \\    if (res._enum_field_offsets == null) {
        \\        res._enum_field_offsets = std.ArrayList(usize).init(allocator);
        \\        res._enum_field_wires = std.ArrayList(gremlin.ProtoWireType).init(allocator);
        \\    }
        \\    try res._enum_field_offsets.?.append(offset);
        \\    try res._enum_field_wires.?.append(tag.wire);
        \\    if (tag.wire == gremlin.ProtoWireType.bytes) {
        \\        const length_result = try buf.readVarInt(offset);
        \\        offset += length_result.size + length_result.value;
        \\    } else {
        \\        const result = try buf.readInt32(offset);
        \\        offset += result.size;
        \\    }
        \\},
    , reader_case_code);

    // Test reader method
    const reader_method_code = try zig_field.createReaderMethod();
    defer std.testing.allocator.free(reader_method_code);
    try std.testing.expectEqualStrings(
        \\pub fn getEnumField(self: *const TestReader, allocator: std.mem.Allocator) gremlin.Error![]messages.TestEnum {
        \\    if (self._enum_field_offsets) |offsets| {
        \\        if (offsets.items.len == 0) return &[_]messages.TestEnum{};
        \\
        \\        var result = std.ArrayList(messages.TestEnum).init(allocator);
        \\        errdefer result.deinit();
        \\
        \\        for (offsets.items, self._enum_field_wires.?.items) |start_offset, wire_type| {
        \\            if (wire_type == .bytes) {
        \\                const length_result = try self.buf.readVarInt(start_offset);
        \\                var offset = start_offset + length_result.size;
        \\                const end_offset = offset + length_result.value;
        \\
        \\                while (offset < end_offset) {
        \\                    const value_result = try self.buf.readInt32(offset);
        \\                    try result.append(@enumFromInt(value_result.value));
        \\                    offset += value_result.size;
        \\                }
        \\            } else {
        \\                const value_result = try self.buf.readInt32(start_offset);
        \\                try result.append(@enumFromInt(value_result.value));
        \\            }
        \\        }
        \\        return result.toOwnedSlice();
        \\    }
        \\    return &[_]messages.TestEnum{};
        \\}
    , reader_method_code);

    // Test deinit
    const deinit_code = try zig_field.createReaderDeinit();
    defer std.testing.allocator.free(deinit_code);
    try std.testing.expectEqualStrings(
        \\if (self._enum_field_offsets) |arr| {
        \\    arr.deinit();
        \\}
        \\if (self._enum_field_wires) |arr| {
        \\    arr.deinit();
        \\}
    , deinit_code);
}
