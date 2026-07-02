const std = @import("std");
const sstable_mod = @import("sstable.zig");
const manifest_mod = @import("manifest.zig");

const Allocator = std.mem.Allocator;
const SSTable = sstable_mod.SSTable;
const Manifest = manifest_mod.Manifest;

/// Leveled compaction background worker.
/// Merges SSTables from level N to level N+1 when size exceeds threshold.
pub const Compaction = struct {
    allocator: Allocator,
    manifest: *Manifest,
    config: Config,
    running: bool,

    pub const Config = struct {
        l0_compaction_threshold: usize = 4,
        level_ratio: usize = 10,
        max_levels: u32 = 7,
    };

    pub fn init(allocator: Allocator, manifest: *Manifest, config: Config) Compaction {
        return Compaction{
            .allocator = allocator,
            .manifest = manifest,
            .config = config,
            .running = false,
        };
    }

    /// Check if compaction is needed
    pub fn needsCompaction(self: *const Compaction) ?u32 {
        // Check L0
        if (self.manifest.getTables(0).len > self.config.l0_compaction_threshold) {
            return 0;
        }

        // Check other levels
        var level: u32 = 0;
        while (level < self.config.max_levels - 1) : (level += 1) {
            const current_tables = self.manifest.getTables(level);
            const next_tables = self.manifest.getTables(level + 1);

            const current_size = self.totalSize(current_tables);
            const next_size = self.totalSize(next_tables);

            if (current_size > 0 and next_size > 0 and current_size * self.config.level_ratio > next_size) {
                return level;
            }
        }
        return null;
    }

    /// Perform compaction on the given level
    pub fn compact(self: *Compaction, level: u32) !void {
        if (level >= self.config.max_levels - 1) return;

        self.running = true;
        defer self.running = false;

        const source_tables = self.manifest.getTables(level);
        if (source_tables.len == 0) return;

        // Find overlapping tables in the next level
        const target_level = level + 1;
        const target_tables = self.manifest.getTables(target_level);

        // Simple merge: just merge all source tables into target level
        // In production, you'd find overlapping ranges
        var merged_entries = std.ArrayList(sstable_mod.Writer.Entry).empty;
        defer {
            for (merged_entries.items) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
            }
            merged_entries.clearAndFree(self.allocator);
        }

        // Read all source tables
        const io = try getIo();
        for (source_tables) |table_meta| {
            var sst = try SSTable.open(self.allocator, table_meta.file_path, io);
            defer sst.deinit();

            var iter = sst.iterator(io);
            defer iter.deinit();

            while (try iter.next()) |entry| {
                try merged_entries.append(self.allocator, .{
                    .key = try self.allocator.dupe(u8, entry.key),
                    .value = try self.allocator.dupe(u8, entry.value),
                });
            }
        }

        // Read overlapping target tables
        for (target_tables) |table_meta| {
            var sst = try SSTable.open(self.allocator, table_meta.file_path, io);
            defer sst.deinit();

            var iter = sst.iterator(io);
            defer iter.deinit();

            while (try iter.next()) |entry| {
                try merged_entries.append(self.allocator, .{
                    .key = try self.allocator.dupe(u8, entry.key),
                    .value = try self.allocator.dupe(u8, entry.value),
                });
            }
        }

        // Sort entries
        std.mem.sort(sstable_mod.Writer.Entry, merged_entries.items, {}, struct {
            fn lessThan(_: void, a: sstable_mod.Writer.Entry, b: sstable_mod.Writer.Entry) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lessThan);

        // Remove duplicates (keep latest)
        var write_idx: usize = 0;
        var read_idx: usize = 1;
        while (read_idx < merged_entries.items.len) : (read_idx += 1) {
            if (!std.mem.eql(u8, merged_entries.items[write_idx].key, merged_entries.items[read_idx].key)) {
                write_idx += 1;
                merged_entries.items[write_idx] = merged_entries.items[read_idx];
            }
        }
        merged_entries.items.len = write_idx + 1;

        // Write new SSTable
        const new_file_path = try std.fmt.allocPrint(self.allocator, "{s}/sst_{d}_{d}.sst", .{
            "kist_data",
            target_level,
            std.time.timestamp(),
        });
        defer self.allocator.free(new_file_path);

        var writer = SSTable.Writer.init(self.allocator, new_file_path);
        defer writer.deinit();

        for (merged_entries.items) |entry| {
            try writer.add(entry.key, entry.value);
        }

        _ = try writer.finish();

        // Update manifest
        // Remove source tables
        for (source_tables) |table_meta| {
            self.manifest.removeTable(level, table_meta.file_path);
        }

        // Remove overlapping target tables
        for (target_tables) |table_meta| {
            self.manifest.removeTable(target_level, table_meta.file_path);
        }

        // Add new table
        try self.manifest.addTable(target_level, .{
            .file_path = try self.allocator.dupe(u8, new_file_path),
            .level = target_level,
            .min_key = try self.allocator.dupe(u8, merged_entries.items[0].key),
            .max_key = try self.allocator.dupe(u8, merged_entries.items[merged_entries.items.len - 1].key),
            .file_size = 0, // TODO: get actual file size
        });
    }

    fn totalSize(self: *const Compaction, tables: []const manifest_mod.Manifest.TableMeta) u64 {
        _ = self;
        var total: u64 = 0;
        for (tables) |table| {
            total += table.file_size;
        }
        return total;
    }

    fn getIo() !std.Io {
        return error.IoNotAvailable;
    }
};

/// Background compaction worker that periodically merges SSTables.
pub const CompactionWorker = struct {
    compaction: *Compaction,
    thread: ?std.Thread,
    stop_flag: std.atomic.Value(bool),
    interval_ms: u64,

    pub fn init(compaction: *Compaction, interval_ms: u64) CompactionWorker {
        return CompactionWorker{
            .compaction = compaction,
            .thread = null,
            .stop_flag = std.atomic.Value(bool).init(false),
            .interval_ms = interval_ms,
        };
    }

    /// Start the background compaction thread
    pub fn start(self: *CompactionWorker) !void {
        self.stop_flag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, workerFn, .{self});
    }

    /// Stop the background thread
    pub fn stop(self: *CompactionWorker) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn workerFn(self: *CompactionWorker) void {
        while (!self.stop_flag.load(.acquire)) {
            // Check if compaction is needed
            if (self.compaction.needsCompaction()) |level| {
                _ = self.compaction.compact(level) catch {};
            }
            // Sleep for interval
            std.time.sleep(self.interval_ms * std.time.ns_per_ms);
        }
    }
};
