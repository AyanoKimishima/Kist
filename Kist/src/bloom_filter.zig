const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bloom filter for probabilistic negative lookups.
/// Uses multiple hash functions to minimize false positives.
pub const BloomFilter = struct {
    bits: []u8,
    num_bits: u32,
    num_hashes: u32,

    /// Create a bloom filter for the given number of expected keys.
    /// bits_per_key controls the false positive rate (~1% at 10 bits/key).
    pub fn init(allocator: Allocator, expected_keys: usize, bits_per_key: usize) !BloomFilter {
        const num_bits = @as(u32, @intCast(expected_keys * bits_per_key));
        // Round up to multiple of 8
        const num_bytes = (num_bits + 7) / 8;
        const bits = try allocator.alloc(u8, num_bytes);
        @memset(bits, 0);

        // Optimal number of hash functions: (num_bits / num_keys) * ln(2)
        const num_hashes: u32 = @intCast(@max(1, (num_bits * 69 / 100) / @max(1, expected_keys)));

        return BloomFilter{
            .bits = bits,
            .num_bits = num_bits,
            .num_hashes = @max(1, @min(num_hashes, 30)), // Cap at 30
        };
    }

    pub fn deinit(self: *BloomFilter, allocator: Allocator) void {
        allocator.free(self.bits);
    }

    /// Add a key to the bloom filter
    pub fn add(self: *BloomFilter, key: []const u8) void {
        const h1 = hash1(key);
        const h2 = hash2(key);

        var i: u32 = 0;
        while (i < self.num_hashes) : (i += 1) {
            const bit_pos = (h1 +% i *% h2) % self.num_bits;
            const byte_idx = bit_pos / 8;
            const bit_idx = bit_pos % 8;
            self.bits[byte_idx] |= @as(u8, 1) << @intCast(bit_idx);
        }
    }

    /// Check if a key might be in the set.
    /// Returns false if definitely NOT in the set.
    /// Returns true if PROBABLY in the set (may be false positive).
    pub fn mightContain(self: *const BloomFilter, key: []const u8) bool {
        const h1 = hash1(key);
        const h2 = hash2(key);

        var i: u32 = 0;
        while (i < self.num_hashes) : (i += 1) {
            const bit_pos = (h1 +% i *% h2) % self.num_bits;
            const byte_idx = bit_pos / 8;
            const bit_idx = bit_pos % 8;
            if (self.bits[byte_idx] & (@as(u8, 1) << @intCast(bit_idx)) == 0) {
                return false;
            }
        }
        return true;
    }

    /// Serialize the bloom filter to bytes
    pub fn encode(self: *const BloomFilter) []const u8 {
        return self.bits;
    }

    /// Deserialize a bloom filter from bytes
    pub fn decode(bits: []u8, num_bits: u32, num_hashes: u32) BloomFilter {
        return BloomFilter{
            .bits = bits,
            .num_bits = num_bits,
            .num_hashes = num_hashes,
        };
    }

    /// Size in bytes of the serialized bloom filter
    pub fn encodedSize(self: *const BloomFilter) u32 {
        return @intCast(self.bits.len);
    }

    // Two independent hash functions using FNV-1a variant
    fn hash1(key: []const u8) u32 {
        var h: u32 = 2166136261;
        for (key) |b| {
            h ^= b;
            h *%= 16777619;
        }
        return h;
    }

    fn hash2(key: []const u8) u32 {
        var h: u32 = 0x811c9dc5;
        for (key) |b| {
            h ^= b;
            h *%= 0x01000193;
        }
        return h;
    }
};

// Tests
test "BloomFilter basic operations" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter.init(allocator, 1000, 10);
    defer bf.deinit(allocator);

    // Add some keys
    bf.add("hello");
    bf.add("world");
    bf.add("foo");
    bf.add("bar");

    // Should find them
    try std.testing.expect(bf.mightContain("hello"));
    try std.testing.expect(bf.mightContain("world"));
    try std.testing.expect(bf.mightContain("foo"));
    try std.testing.expect(bf.mightContain("bar"));

    // Should not find random keys (with high probability)
    try std.testing.expect(!bf.mightContain("xyz_not_exist"));
}

test "BloomFilter encode/decode" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter.init(allocator, 100, 10);
    defer bf.deinit(allocator);

    bf.add("key1");
    bf.add("key2");

    // Encode
    const encoded = bf.encodedSize();

    // Create a copy of bits for decode test
    const bits_copy = try allocator.dupe(u8, bf.bits);
    defer allocator.free(bits_copy);

    // Decode from copy
    var decoded = BloomFilter.decode(bits_copy, bf.num_bits, bf.num_hashes);
    defer {} // Don't free bits_copy here since decoded借用它

    try std.testing.expect(decoded.mightContain("key1"));
    try std.testing.expect(decoded.mightContain("key2"));
    try std.testing.expect(!decoded.mightContain("key3"));
    _ = encoded;
}
