const std = @import("std");
const wal_mod = @import("wal.zig");
const memtable_mod = @import("memtable.zig");
const types = @import("types.zig");
const config_mod = @import("config.zig");
const snapshot_mod = @import("snapshot.zig");
const lock_mod = @import("lock.zig");
const block_mod = @import("block.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const MemTable = memtable_mod.MemTable;
const WAL = wal_mod.WAL;
const SnapshotManager = snapshot_mod.SnapshotManager;
const RwLock = lock_mod.RwLock;
const Block = block_mod.Block;

/// In-memory SSTable index (loaded from disk on startup / flush).
pub const MemSSTable = struct {
    file_path: []const u8,
    blocks: []BlockData,
    bloom_bits: []u8, // bloom filter bits
    bloom_num_hashes: u32,
    allocator: Allocator,

    pub const BlockData = struct {
        offset: u64,
        size: u32,
        min_key: []const u8,
        max_key: []const u8,
        data: []u8, // raw block bytes
    };

    pub fn deinit(self: *MemSSTable) void {
        for (self.blocks) |b| {
            self.allocator.free(b.data);
            self.allocator.free(b.min_key);
            self.allocator.free(b.max_key);
        }
        self.allocator.free(self.blocks);
        self.allocator.free(self.bloom_bits);
        self.allocator.free(self.file_path);
    }

    /// Check if key might be in this SSTable using bloom filter
    pub fn bloomMightContain(self: *const MemSSTable, key: []const u8) bool {
        if (self.bloom_bits.len == 0) return true;
        const num_bits: u32 = @intCast(self.bloom_bits.len * 8);
        const h1 = bloomHash1(key);
        const h2 = bloomHash2(key);
        var i: u32 = 0;
        while (i < self.bloom_num_hashes) : (i += 1) {
            const bit_pos = (h1 +% i *% h2) % num_bits;
            const byte_idx = bit_pos / 8;
            const bit_idx = bit_pos % 8;
            if (self.bloom_bits[byte_idx] & (@as(u8, 1) << @intCast(bit_idx)) == 0) {
                return false;
            }
        }
        return true;
    }

    /// Look up a key in this SSTable (scans blocks in reverse for latest value)
    pub fn get(self: *const MemSSTable, key: []const u8) !?[]const u8 {
        // Fast bloom filter check
        if (!self.bloomMightContain(key)) return null;

        // Scan blocks from last to first (newest data first)
        var i: usize = self.blocks.len;
        while (i > 0) {
            i -= 1;
            const b = self.blocks[i];

            // Skip blocks whose key range doesn't contain our key
            if (compareBytes(key, b.min_key) < 0) continue;
            if (compareBytes(key, b.max_key) > 0) continue;

            // Decode the block and search
            var block = Block.decode(b.data);
            const idx = block.lowerBound(key);
            if (idx < block.num_entries) {
                const entry = block.get(idx) orelse continue;
                if (std.mem.eql(u8, entry.key, key)) {
                    return entry.value;
                }
            }
        }
        return null;
    }
};

/// Top-level database orchestrator.
pub const DB = struct {
    allocator: Allocator,
    io: Io,
    config: config_mod.Config,
    wal: WAL,
    memtable: MemTable,
    /// SSTables sorted by level, newest first within each level
    sstables: std.ArrayList(MemSSTable),
    dir_path: []const u8,
    closed: bool,
    replay_bufs: std.ArrayList([]const u8),
    snapshot_manager: SnapshotManager,
    rwlock: RwLock,
    /// Sequence counter for SSTable file naming
    next_sst_id: u64,

    pub fn open(allocator: Allocator, io: Io, dir_path: []const u8, cfg: config_mod.Config) !DB {
        var w = try WAL.init(allocator, io, dir_path);
        errdefer w.deinit();

        var mt = MemTable.init(allocator, cfg.memtable_max_size);
        errdefer mt.deinit();

        var db = DB{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .wal = w,
            .memtable = mt,
            .sstables = std.ArrayList(MemSSTable).empty,
            .dir_path = try allocator.dupe(u8, dir_path),
            .closed = false,
            .replay_bufs = std.ArrayList([]const u8).empty,
            .snapshot_manager = SnapshotManager.init(allocator),
            .rwlock = RwLock.init(),
            .next_sst_id = 0,
        };

        // Replay WAL to restore memtable state
        try db.replayWal();

        // Load SSTables from disk
        try db.loadSSTables();

        return db;
    }

    pub fn openDefault(allocator: Allocator, io: Io, dir_path: []const u8) !DB {
        return DB.open(allocator, io, dir_path, config_mod.default_config);
    }

    pub fn close(self: *DB) void {
        if (self.closed) return;
        self.closed = true;
        self.wal.deinit();
        self.memtable.deinit();
        for (self.sstables.items) |*sst| {
            sst.deinit();
        }
        self.sstables.deinit(self.allocator);
        self.snapshot_manager.deinit();
        for (self.replay_bufs.items) |buf| {
            self.allocator.free(buf);
        }
        self.replay_bufs.deinit(self.allocator);
        self.allocator.free(self.dir_path);
    }

    /// Put a key-value pair
    pub fn put(self: *DB, key: []const u8, value: []const u8) !void {
        if (self.closed) return error.DBClosed;

        const held = self.rwlock.writeLock();
        defer held.release();

        try self.wal.appendPut(key, value);
        _ = try self.memtable.put(key, value);

        if (self.memtable.isFull()) {
            try self.flushMemTable();
        }
    }

    pub const BatchEntry = struct {
        key: []const u8,
        value: []const u8,
    };

    /// Put multiple key-value pairs in a single batch (one WAL write).
    pub fn putBatch(self: *DB, entries: []const BatchEntry) !void {
        if (self.closed) return error.DBClosed;

        const held = self.rwlock.writeLock();
        defer held.release();

        for (entries) |entry| {
            try self.wal.appendPut(entry.key, entry.value);
            _ = try self.memtable.put(entry.key, entry.value);
        }

        if (self.memtable.isFull()) {
            try self.flushMemTable();
        }
    }

    /// Get value by key — checks memtable first, then SSTables (newest first)
    pub fn get(self: *DB, key: []const u8) !?[]const u8 {
        if (self.closed) return error.DBClosed;

        const held = self.rwlock.readLock();
        defer held.release();

        // 1. Check MemTable (most recent)
        if (self.memtable.get(key)) |value| {
            if (value.len == 0) return null; // tombstone
            return value;
        }

        // 2. Check SSTables (newest first)
        var i: usize = self.sstables.items.len;
        while (i > 0) {
            i -= 1;
            if (try self.sstables.items[i].get(key)) |value| {
                if (value.len == 0) return null; // tombstone
                return value;
            }
        }

        return null;
    }

    /// Delete a key
    pub fn delete(self: *DB, key: []const u8) !void {
        if (self.closed) return error.DBClosed;

        const held = self.rwlock.writeLock();
        defer held.release();

        try self.wal.appendDelete(key);
        _ = self.memtable.delete(key);

        if (self.memtable.isFull()) {
            try self.flushMemTable();
        }
    }

    /// Range scan: returns all entries where start_key <= key < end_key.
    /// Caller must free the result with allocator.
    pub fn scan(self: *DB, start_key: []const u8, end_key: []const u8) !std.ArrayList(ScanEntry) {
        if (self.closed) return error.DBClosed;

        const held = self.rwlock.readLock();
        defer held.release();

        var results = std.ArrayList(ScanEntry).empty;

        // Collect from memtable
        var mt_iter = self.memtable.lowerBound(start_key);
        while (mt_iter.next()) |entry| {
            if (entry.value.len > 0) { // skip tombstones
                if (compareBytes(entry.key, end_key) >= 0) break;
                try results.append(self.allocator, .{
                    .key = try self.allocator.dupe(u8, entry.key),
                    .value = try self.allocator.dupe(u8, entry.value),
                });
            }
        }

        // Collect from SSTables (newest first), dedup by key
        var si: usize = self.sstables.items.len;
        while (si > 0) {
            si -= 1;
            const sst = &self.sstables.items[si];
            for (sst.blocks) |block_data| {
                if (compareBytes(block_data.max_key, start_key) < 0) continue;
                if (compareBytes(block_data.min_key, end_key) >= 0) continue;

                var block = Block.decode(block_data.data);
                const start_idx = block.lowerBound(start_key);
                var idx = start_idx;
                while (idx < block.num_entries) {
                    const entry = block.get(idx) orelse break;
                    if (compareBytes(entry.key, end_key) >= 0) break;
                    idx += 1;

                    if (entry.value.len == 0) continue; // tombstone

                    // Skip if already in results (newer source)
                    var already_exists = false;
                    for (results.items) |r| {
                        if (std.mem.eql(u8, r.key, entry.key)) {
                            already_exists = true;
                            break;
                        }
                    }
                    if (!already_exists) {
                        try results.append(self.allocator, .{
                            .key = try self.allocator.dupe(u8, entry.key),
                            .value = try self.allocator.dupe(u8, entry.value),
                        });
                    }
                }
            }
        }

        return results;
    }

    pub const ScanEntry = struct {
        key: []const u8,
        value: []const u8,
    };

    /// Flush memtable to SSTable on disk and load into memory
    fn flushMemTable(self: *DB) !void {
        if (self.memtable.count() == 0) return;

        // Collect sorted entries from memtable
        var entries = std.ArrayList(block_mod.Block.Entry).empty;
        defer {
            entries.deinit(self.allocator);
        }

        var iter = self.memtable.iterator();
        while (iter.next()) |entry| {
            try entries.append(self.allocator, .{
                .key = entry.key,
                .value = entry.value,
            });
        }

        if (entries.items.len == 0) return;

        // Build SSTable file
        const sst_id = self.next_sst_id;
        self.next_sst_id += 1;
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/sst_{d}.dat", .{ self.dir_path, sst_id });

        // Ensure directory exists
        std.Io.Dir.cwd().createDirPath(self.io, self.dir_path) catch {};

        var file = try std.Io.Dir.cwd().createFile(self.io, file_path, .{ .truncate = true, .read = true });
        defer file.close(self.io);

        // Write blocks
        const block_size = self.config.block_size;
        var file_offset: u64 = 0;
        var block_list = std.ArrayList(MemSSTable.BlockData).empty;

        var block_entries = std.ArrayList(block_mod.Block.Entry).empty;
        var current_min_key: ?[]const u8 = null;

        for (entries.items) |entry| {
            if (current_min_key == null) current_min_key = entry.key;

            try block_entries.append(self.allocator, entry);

            // Estimate block size
            var size: usize = 0;
            for (block_entries.items) |e| {
                size += 2 + e.key.len + 2 + e.value.len;
            }

            if (size >= block_size) {
                // Flush block
                const block = try Block.encode(self.allocator, block_entries.items);
                defer self.allocator.free(block.data);

                try file.writeStreamingAll(self.io, block.data);

                try block_list.append(self.allocator, .{
                    .offset = file_offset,
                    .size = @intCast(block.data.len),
                    .min_key = try self.allocator.dupe(u8, current_min_key.?),
                    .max_key = try self.allocator.dupe(u8, entry.key),
                    .data = try self.allocator.dupe(u8, block.data),
                });

                file_offset += block.data.len;
                block_entries.clearRetainingCapacity();
                current_min_key = null;
            }
        }

        // Flush remaining entries
        if (block_entries.items.len > 0) {
            const block = try Block.encode(self.allocator, block_entries.items);
            defer self.allocator.free(block.data);

            try file.writeStreamingAll(self.io, block.data);

            try block_list.append(self.allocator, .{
                .offset = file_offset,
                .size = @intCast(block.data.len),
                .min_key = try self.allocator.dupe(u8, current_min_key.?),
                .max_key = try self.allocator.dupe(u8, entries.items[entries.items.len - 1].key),
                .data = try self.allocator.dupe(u8, block.data),
            });
        }

        block_entries.deinit(self.allocator);

        // Build bloom filter
        const num_keys = entries.items.len;
        const bloom_num_bits: u32 = @intCast(num_keys * 10); // 10 bits per key
        const bloom_num_bytes = (bloom_num_bits + 7) / 8;
        var bloom_bits = try self.allocator.alloc(u8, bloom_num_bytes);
        @memset(bloom_bits, 0);

        const bloom_num_hashes: u32 = @max(1, @min((bloom_num_bits * 69 / 100) / @max(1, num_keys), 30));

        for (entries.items) |entry| {
            const h1 = bloomHash1(entry.key);
            const h2 = bloomHash2(entry.key);
            var hi: u32 = 0;
            while (hi < bloom_num_hashes) : (hi += 1) {
                const bit_pos = (h1 +% hi *% h2) % bloom_num_bits;
                const byte_idx = bit_pos / 8;
                const bit_idx = bit_pos % 8;
                bloom_bits[byte_idx] |= @as(u8, 1) << @intCast(bit_idx);
            }
        }

        // Write index: for each block, write offset + size + min_key + max_key
        const index_offset = file_offset;
        for (block_list.items) |b| {
            try file.writeStreamingAll(self.io, std.mem.asBytes(&b.offset));
            try file.writeStreamingAll(self.io, std.mem.asBytes(&b.size));
            const min_key_len: u16 = @intCast(b.min_key.len);
            const max_key_len: u16 = @intCast(b.max_key.len);
            try file.writeStreamingAll(self.io, std.mem.asBytes(&min_key_len));
            try file.writeStreamingAll(self.io, b.min_key);
            try file.writeStreamingAll(self.io, std.mem.asBytes(&max_key_len));
            try file.writeStreamingAll(self.io, b.max_key);
        }
        // Compute index size
        var computed_index_size: u64 = 0;
        for (block_list.items) |b| {
            computed_index_size += 8 + 4 + 2 + b.min_key.len + 2 + b.max_key.len;
        }

        // Write footer: [index_offset: u64][index_size: u32][magic: u32]
        try file.writeStreamingAll(self.io, std.mem.asBytes(&index_offset));
        const index_size_u32: u32 = @intCast(computed_index_size);
        try file.writeStreamingAll(self.io, std.mem.asBytes(&index_size_u32));
        const magic: u32 = 0x4B535442; // "KSTB"
        try file.writeStreamingAll(self.io, std.mem.asBytes(&magic));

        // Add to SSTable list
        try self.sstables.append(self.allocator, MemSSTable{
            .file_path = file_path,
            .blocks = try block_list.toOwnedSlice(self.allocator),
            .bloom_bits = bloom_bits,
            .bloom_num_hashes = bloom_num_hashes,
            .allocator = self.allocator,
        });

        // Record in manifest
        const sst_filename = try std.fmt.allocPrint(self.allocator, "sst_{d}.dat", .{sst_id});
        defer self.allocator.free(sst_filename);
        try self.appendManifest(sst_filename);

        // Clear memtable and WAL
        try self.wal.clear();
        self.memtable.clear();
    }

    /// Load SSTable files listed in the MANIFEST file.
    fn loadSSTables(self: *DB) !void {
        const manifest_path = try std.fmt.allocPrint(self.allocator, "{s}/MANIFEST", .{self.dir_path});
        defer self.allocator.free(manifest_path);

        const file = std.Io.Dir.cwd().openFile(self.io, manifest_path, .{ .mode = .read_only }) catch return; // no manifest = fresh db
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        if (stat.size == 0) return;

        const content = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(content);
        _ = try file.readPositionalAll(self.io, content, 0);

        // Parse manifest: each line is a filename
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\r', '\n' });
            if (trimmed.len == 0) continue;
            if (!std.mem.startsWith(u8, trimmed, "sst_")) continue;

            const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_path, trimmed });
            const sst_file = std.Io.Dir.cwd().openFile(self.io, file_path, .{ .mode = .read_only }) catch {
                self.allocator.free(file_path);
                continue;
            };
            defer sst_file.close(self.io);

            const sst_stat = try sst_file.stat(self.io);
            if (sst_stat.size < 16) {
                self.allocator.free(file_path);
                continue;
            }

            // Read footer (last 16 bytes): [index_offset: u64][index_size: u32][magic: u32]
            var footer_buf: [16]u8 = undefined;
            _ = try sst_file.readPositionalAll(self.io, &footer_buf, sst_stat.size - 16);
            const index_offset = std.mem.readInt(u64, footer_buf[0..8], .little);
            const index_size = std.mem.readInt(u32, footer_buf[8..12], .little);
            const magic = std.mem.readInt(u32, footer_buf[12..16], .little);
            if (magic != 0x4B535442) {
                self.allocator.free(file_path);
                continue;
            }

            // Read index
            var index_data = try self.allocator.alloc(u8, index_size);
            defer self.allocator.free(index_data);
            _ = try sst_file.readPositionalAll(self.io, index_data, index_offset);

            // Parse index entries
            var block_list = std.ArrayList(MemSSTable.BlockData).empty;
            var pos: usize = 0;
            while (pos + 14 <= index_data.len) {
                const block_offset = std.mem.readInt(u64, index_data[pos..][0..8], .little);
                pos += 8;
                const block_size_u32 = std.mem.readInt(u32, index_data[pos..][0..4], .little);
                pos += 4;
                const min_key_len = std.mem.readInt(u16, index_data[pos..][0..2], .little);
                pos += 2;
                if (pos + min_key_len > index_data.len) break;
                const min_key = try self.allocator.dupe(u8, index_data[pos..][0..min_key_len]);
                pos += min_key_len;

                if (pos + 2 > index_data.len) {
                    self.allocator.free(min_key);
                    break;
                }
                const max_key_len = std.mem.readInt(u16, index_data[pos..][0..2], .little);
                pos += 2;
                if (pos + max_key_len > index_data.len) {
                    self.allocator.free(min_key);
                    break;
                }
                const max_key = try self.allocator.dupe(u8, index_data[pos..][0..max_key_len]);
                pos += max_key_len;

                // Read block data from file
                const block_data = try self.allocator.alloc(u8, block_size_u32);
                _ = try sst_file.readPositionalAll(self.io, block_data, block_offset);

                try block_list.append(self.allocator, .{
                    .offset = block_offset,
                    .size = block_size_u32,
                    .min_key = min_key,
                    .max_key = max_key,
                    .data = block_data,
                });
            }

            if (block_list.items.len == 0) {
                block_list.deinit(self.allocator);
                self.allocator.free(file_path);
                continue;
            }

            // Build bloom filter from all keys
            var total_keys: usize = 0;
            for (block_list.items) |b| {
                const blk = Block.decode(b.data);
                total_keys += blk.num_entries;
            }

            const bloom_num_bits: u32 = @intCast(total_keys * 10);
            const bloom_num_bytes_calc = (bloom_num_bits + 7) / 8;
            var bloom_bits = try self.allocator.alloc(u8, bloom_num_bytes_calc);
            @memset(bloom_bits, 0);
            const bloom_num_hashes: u32 = @max(1, @min((bloom_num_bits * 69 / 100) / @max(1, total_keys), 30));

            for (block_list.items) |b| {
                const blk = Block.decode(b.data);
                var idx: u32 = 0;
                while (idx < blk.num_entries) {
                    const be = blk.get(idx) orelse break;
                    idx += 1;
                    const h1 = bloomHash1(be.key);
                    const h2 = bloomHash2(be.key);
                    var hi: u32 = 0;
                    while (hi < bloom_num_hashes) : (hi += 1) {
                        const bit_pos = (h1 +% hi *% h2) % bloom_num_bits;
                        bloom_bits[bit_pos / 8] |= @as(u8, 1) << @intCast(bit_pos % 8);
                    }
                }
            }

            // Parse sst_N.dat to extract N for next_sst_id
            const name_no_ext = trimmed[4 .. trimmed.len - 4]; // strip "sst_" and ".dat"
            if (std.fmt.parseInt(u64, name_no_ext, 10)) |id| {
                if (id >= self.next_sst_id) self.next_sst_id = id + 1;
            } else |_| {
                // Non-numeric filename in MANIFEST — skip silently
            }

            try self.sstables.append(self.allocator, MemSSTable{
                .file_path = file_path,
                .blocks = try block_list.toOwnedSlice(self.allocator),
                .bloom_bits = bloom_bits,
                .bloom_num_hashes = bloom_num_hashes,
                .allocator = self.allocator,
            });
        }
    }

    /// Append an SSTable filename to the MANIFEST file.
    fn appendManifest(self: *DB, filename: []const u8) !void {
        const manifest_path = try std.fmt.allocPrint(self.allocator, "{s}/MANIFEST", .{self.dir_path});
        defer self.allocator.free(manifest_path);

        const file = try std.Io.Dir.cwd().createFile(self.io, manifest_path, .{ .truncate = false });
        defer file.close(self.io);

        try file.writeStreamingAll(self.io, filename);
        try file.writeStreamingAll(self.io, "\n");
    }

    /// Replay WAL to restore state on startup
    fn replayWal(self: *DB) !void {
        var reader = self.wal.reader(self.allocator);
        while (try reader.next()) |entry| {
            try self.replay_bufs.append(self.allocator, entry.key);
            if (entry.value) |value| {
                try self.replay_bufs.append(self.allocator, value);
            }
            switch (entry.op) {
                .put => {
                    if (entry.value) |value| {
                        _ = try self.memtable.put(entry.key, value);
                    }
                },
                .delete => {
                    _ = self.memtable.delete(entry.key);
                },
            }
        }
    }

    pub fn memtableSize(self: *const DB) usize {
        return self.memtable.count();
    }

    pub fn sstableCount(self: *const DB) usize {
        return self.sstables.items.len;
    }
};

// Tests
test "DB open and close" {
    const allocator = std.testing.allocator;
    const dir = "test_db_open_close";
    var io = Io.Threaded.init(allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteTree(io.io(), dir) catch {};
    {
        var db = try DB.open(allocator, io.io(), dir, .{});
        defer db.close();
    }
}

test "DB put and get" {
    const allocator = std.testing.allocator;
    const dir = "test_db_put_get";
    var io = Io.Threaded.init(allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteTree(io.io(), dir) catch {};
    {
        var db = try DB.open(allocator, io.io(), dir, .{});
        defer db.close();
        try db.put("hello", "world");
        try db.put("foo", "bar");
        try std.testing.expectEqualStrings("world", (try db.get("hello")).?);
        try std.testing.expectEqualStrings("bar", (try db.get("foo")).?);
        try std.testing.expect((try db.get("missing")) == null);
    }
}

test "DB delete" {
    const allocator = std.testing.allocator;
    const dir = "test_db_delete";
    var io = Io.Threaded.init(allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteTree(io.io(), dir) catch {};
    {
        var db = try DB.open(allocator, io.io(), dir, .{});
        defer db.close();
        try db.put("key1", "value1");
        try std.testing.expect((try db.get("key1")) != null);
        try db.delete("key1");
        try std.testing.expect((try db.get("key1")) == null);
    }
}

test "DB WAL recovery" {
    const allocator = std.testing.allocator;
    const dir = "test_db_wal_recovery";
    var io = Io.Threaded.init(allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteTree(io.io(), dir) catch {};
    {
        var db = try DB.open(allocator, io.io(), dir, .{});
        defer db.close();
        try db.put("persist1", "data1");
        try db.put("persist2", "data2");
    }
    {
        var db = try DB.open(allocator, io.io(), dir, .{});
        defer db.close();
        try std.testing.expectEqualStrings("data1", (try db.get("persist1")).?);
        try std.testing.expectEqualStrings("data2", (try db.get("persist2")).?);
    }
}

test "DB putBatch" {
    const allocator = std.testing.allocator;
    const dir = "test_db_batch";
    var io = Io.Threaded.init(allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteTree(io.io(), dir) catch {};
    {
        var db = try DB.open(allocator, io.io(), dir, .{});
        defer db.close();
        const batch = [_]DB.BatchEntry{
            .{ .key = "a", .value = "1" },
            .{ .key = "b", .value = "2" },
            .{ .key = "c", .value = "3" },
        };
        try db.putBatch(&batch);
        try std.testing.expectEqualStrings("1", (try db.get("a")).?);
        try std.testing.expectEqualStrings("2", (try db.get("b")).?);
        try std.testing.expectEqualStrings("3", (try db.get("c")).?);
    }
}

test "DB scan" {
    const allocator = std.testing.allocator;
    const dir = "test_db_scan";
    var io = Io.Threaded.init(allocator, .{});
    defer io.deinit();
    defer std.Io.Dir.cwd().deleteTree(io.io(), dir) catch {};
    {
        var db = try DB.open(allocator, io.io(), dir, .{});
        defer db.close();
        try db.put("a", "1");
        try db.put("b", "2");
        try db.put("c", "3");
        try db.put("d", "4");

        var results = try db.scan("b", "d");
        defer {
            for (results.items) |entry| {
                allocator.free(entry.key);
                allocator.free(entry.value);
            }
            results.deinit(allocator);
        }

        try std.testing.expectEqual(@as(usize, 2), results.items.len);
        try std.testing.expectEqualStrings("b", results.items[0].key);
        try std.testing.expectEqualStrings("c", results.items[1].key);
    }
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

fn bloomHash1(key: []const u8) u32 {
    var h: u32 = 2166136261;
    for (key) |b| {
        h ^= b;
        h *%= 16777619;
    }
    return h;
}

fn bloomHash2(key: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (key) |b| {
        h ^= b;
        h *%= 0x01000193;
    }
    return h;
}
