const std = @import("std");
const Allocator = std.mem.Allocator;

/// A data block in an SSTable.
///
/// Format:
///   [num_entries: u32]
///   [offsets: [u32; num_entries]]   — byte offset of each entry
///   [entries...]                     — each entry:
///       [key_len: u16][key...][val_len: u16][val...]
pub const Block = struct {
    data: []u8,
    offsets: []u32,
    num_entries: u32,

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    /// Encode sorted entries into a block.
    pub fn encode(allocator: Allocator, entries: []const Entry) !Block {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        const num_entries: u32 = @intCast(entries.len);
        try buf.appendSlice(allocator, std.mem.asBytes(&num_entries));

        const offsets_start = buf.items.len;
        try buf.ensureTotalCapacityPrecise(allocator, offsets_start + entries.len * @sizeOf(u32));
        buf.items.len = buf.items.len + entries.len * @sizeOf(u32);

        var entry_offsets = std.ArrayList(u32).empty;
        defer entry_offsets.deinit(allocator);

        for (entries) |entry| {
            try entry_offsets.append(allocator, @intCast(buf.items.len));
            const key_len: u16 = @intCast(entry.key.len);
            const val_len: u16 = @intCast(entry.value.len);
            try buf.appendSlice(allocator, std.mem.asBytes(&key_len));
            try buf.appendSlice(allocator, entry.key);
            try buf.appendSlice(allocator, std.mem.asBytes(&val_len));
            try buf.appendSlice(allocator, entry.value);
        }

        for (entry_offsets.items, 0..) |off, i| {
            const pos = offsets_start + i * @sizeOf(u32);
            @memcpy(buf.items[pos..][0..4], std.mem.asBytes(&off));
        }

        const owned = try buf.toOwnedSlice(allocator);
        const off_ptr: [*]u32 = @alignCast(@ptrCast(owned[offsets_start..].ptr));

        return Block{
            .data = owned,
            .offsets = off_ptr[0..num_entries],
            .num_entries = num_entries,
        };
    }

    /// Decode a block from raw bytes (borrows data).
    pub fn decode(data: []u8) Block {
        if (data.len < @sizeOf(u32)) {
            return Block{ .data = data, .offsets = &.{}, .num_entries = 0 };
        }
        const n = std.mem.readInt(u32, data[0..4], .little);
        const off_ptr: [*]u32 = @alignCast(@ptrCast(data[4..].ptr));
        return Block{ .data = data, .offsets = off_ptr[0..n], .num_entries = n };
    }

    /// Get entry at index.
    pub fn get(self: *const Block, index: u32) ?Entry {
        if (index >= self.num_entries) return null;
        var pos: usize = self.offsets[index];

        if (pos + 2 > self.data.len) return null;
        const key_len = std.mem.readInt(u16, self.data[pos..][0..2], .little);
        pos += 2;
        if (pos + key_len > self.data.len) return null;
        const key = self.data[pos..][0..key_len];
        pos += key_len;

        if (pos + 2 > self.data.len) return null;
        const val_len = std.mem.readInt(u16, self.data[pos..][0..2], .little);
        pos += 2;
        if (pos + val_len > self.data.len) return null;
        const val = self.data[pos..][0..val_len];

        return Entry{ .key = key, .value = val };
    }

    /// Binary search for first entry >= target.
    pub fn lowerBound(self: *const Block, target: []const u8) u32 {
        var lo: u32 = 0;
        var hi: u32 = self.num_entries;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = self.get(mid) orelse break;
            if (compareBytes(e.key, target) < 0) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    fn compareBytes(a: []const u8, b: []const u8) i32 {
        const min_len = @min(a.len, b.len);
        for (0..min_len) |i| {
            if (a[i] < b[i]) return -1;
            if (a[i] > b[i]) return 1;
        }
        if (a.len < b.len) return -1;
        if (a.len > b.len) return 1;
        return 0;
    }
};

test "Block encode and decode" {
    const allocator = std.testing.allocator;
    const entries = [_]Block.Entry{
        .{ .key = "apple", .value = "red" },
        .{ .key = "banana", .value = "yellow" },
        .{ .key = "cherry", .value = "dark red" },
    };
    var block = try Block.encode(allocator, &entries);
    defer allocator.free(block.data);
    try std.testing.expectEqual(@as(u32, 3), block.num_entries);
    const e0 = block.get(0).?;
    try std.testing.expectEqualStrings("apple", e0.key);
    try std.testing.expectEqualStrings("red", e0.value);
}

test "Block lowerBound" {
    const allocator = std.testing.allocator;
    const entries = [_]Block.Entry{
        .{ .key = "apple", .value = "1" },
        .{ .key = "banana", .value = "2" },
        .{ .key = "cherry", .value = "3" },
    };
    var block = try Block.encode(allocator, &entries);
    defer allocator.free(block.data);
    try std.testing.expectEqual(@as(u32, 0), block.lowerBound("aaa"));
    try std.testing.expectEqual(@as(u32, 0), block.lowerBound("apple"));
    try std.testing.expectEqual(@as(u32, 1), block.lowerBound("avocado"));
    try std.testing.expectEqual(@as(u32, 1), block.lowerBound("banana"));
    try std.testing.expectEqual(@as(u32, 2), block.lowerBound("cherry"));
    try std.testing.expectEqual(@as(u32, 3), block.lowerBound("zzz"));
}
