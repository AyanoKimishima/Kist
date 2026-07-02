const std = @import("std");

/// Simple block compression using a LZ4-inspired scheme.
/// Format: [compressed_flag: u8][raw_or_compressed_len: u32][data...]
///   flag=0: uncompressed, data is raw
///   flag=1: compressed with simple LZ4-like encoding
///
/// The LZ4-like encoding:
///   Literal byte: copy directly
///   Match: [match_header: u8][offset_lo: u8][length: u8]
///     match_header high nibble = offset high bits
///     length: 4..19 (encoded as nibble - 3)
///
/// This is a simplified version — good enough for repetitive SSTable data.
pub const Compressor = struct {
    /// Attempt to compress data. Returns compressed bytes if smaller, else null.
    pub fn compress(allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
        if (data.len < 64) return null; // don't bother compressing small blocks

        var compressed = std.ArrayList(u8).empty;
        errdefer compressed.deinit(allocator);

        try compressed.append(allocator, 1); // compressed flag
        // Reserve 4 bytes for compressed length (filled later)
        try compressed.appendNTimes(allocator, 0, 4);

        var pos: usize = 0;
        while (pos < data.len) {
            // Try to find a match
            const match = findMatch(data, pos);
            if (match) |m| {
                // Encode match
                const match_len = @min(m.length, 19); // max length fits in 4 bits + 3
                const offset = m.offset;
                const match_header: u8 = @intCast(((offset >> 8) & 0x0F) << 4 | (match_len - 3));
                const offset_lo: u8 = @intCast(offset & 0xFF);
                try compressed.append(allocator, match_header);
                try compressed.append(allocator, offset_lo);
                pos += match_len;
            } else {
                // Literal byte
                try compressed.append(allocator, data[pos]);
                pos += 1;
            }
        }

        // Only use compressed version if it's actually smaller
        if (compressed.items.len >= data.len + 5) {
            compressed.deinit(allocator);
            return null;
        }

        // Write compressed length
        const comp_len: u32 = @intCast(compressed.items.len - 5); // minus flag + 4 len bytes
        @memcpy(compressed.items[1..5], std.mem.asBytes(&comp_len));

        return try compressed.toOwnedSlice(allocator);
    }

    /// Decompress data. If data is uncompressed (flag=0), returns a copy.
    pub fn decompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        if (data.len < 5) return try allocator.dupe(u8, data);

        const flag = data[0];
        const raw_len = std.mem.readInt(u32, data[1..5], .little);

        if (flag == 0) {
            // Uncompressed
            return try allocator.dupe(u8, data[5 .. 5 + raw_len]);
        }

        // Decompress LZ4-like
        var output = try std.ArrayList(u8).initCapacity(allocator, raw_len + 256);
        errdefer output.deinit(allocator);

        var in_pos: usize = 5;
        const in_end = 5 + raw_len;

        while (in_pos < in_end and output.items.len < raw_len) {
            const byte = data[in_pos];
            in_pos += 1;

            const high = (byte >> 4) & 0x0F;
            const low = byte & 0x0F;

            if (high == 0) {
                // Literal
                if (in_pos < in_end) {
                    try output.append(allocator, data[in_pos]);
                    in_pos += 1;
                }
            } else {
                // Match
                if (in_pos >= in_end) break;
                const offset_lo = data[in_pos];
                in_pos += 1;
                const offset: u16 = @as(u16, high) << 8 | offset_lo;
                const length: u16 = low + 3;

                const match_start = output.items.len - @as(usize, offset);
                var i: u16 = 0;
                while (i < length and match_start + @as(usize, i) < output.items.len) : (i += 1) {
                    try output.append(allocator, output.items[match_start + i]);
                }
            }
        }

        return try output.toOwnedSlice(allocator);
    }

    fn findMatch(data: []const u8, pos: usize) ?Match {
        if (pos < 1) return null;
        const max_offset = @min(pos, 4095); // 12-bit offset
        const max_len = @min(data.len - pos, 19);

        var best: ?Match = null;
        var start = if (pos > max_offset) pos - max_offset else 0;

        while (start < pos) : (start += 1) {
            var len: usize = 0;
            while (len < max_len and data[start + len] == data[pos + len]) {
                len += 1;
            }
            if (len >= 4) { // minimum match length
                const match_len = @min(len, 19);
                if (best == null or match_len > best.?.length) {
                    best = Match{
                        .offset = @intCast(pos - start),
                        .length = @intCast(match_len),
                    };
                }
            }
        }
        return best;
    }

    const Match = struct {
        offset: u16,
        length: u16,
    };
};

test "Compressor round-trip" {
    const allocator = std.testing.allocator;

    // Repetitive data compresses well
    const original = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
    const compressed = try Compressor.compress(allocator, original);
    if (compressed) |comp| {
        defer allocator.free(comp);
        const decompressed = try Compressor.decompress(allocator, comp);
        defer allocator.free(decompressed);
        try std.testing.expectEqualStrings(original, decompressed);
    }

    // Small data stays uncompressed
    const small = "hello";
    const small_comp = try Compressor.compress(allocator, small);
    try std.testing.expect(small_comp == null);
}
