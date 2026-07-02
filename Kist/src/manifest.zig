const std = @import("std");
const sstable_mod = @import("sstable.zig");

const Allocator = std.mem.Allocator;
const SSTable = sstable_mod.SSTable;

/// Manifest tracks the metadata for all SSTables across levels.
/// It's persisted as a log-structured file.
pub const Manifest = struct {
    allocator: Allocator,
    levels: []LevelMetadata,
    max_levels: u32,

    pub const LevelMetadata = struct {
        tables: []TableMeta,
    };

    pub const TableMeta = struct {
        file_path: []const u8,
        level: u32,
        min_key: []const u8,
        max_key: []const u8,
        file_size: u64,
    };

    pub fn init(allocator: Allocator, max_levels: u32) Manifest {
        const levels = allocator.alloc(LevelMetadata, max_levels) catch unreachable;
        for (levels) |*level| {
            level.* = LevelMetadata{ .tables = &.{} };
        }
        return Manifest{
            .allocator = allocator,
            .levels = levels,
            .max_levels = max_levels,
        };
    }

    pub fn deinit(self: *Manifest) void {
        for (self.levels) |level| {
            for (level.tables) |table| {
                self.allocator.free(table.file_path);
                self.allocator.free(table.min_key);
                self.allocator.free(table.max_key);
            }
            self.allocator.free(level.tables);
        }
        self.allocator.free(self.levels);
    }

    /// Add a table to a level
    pub fn addTable(self: *Manifest, level: u32, meta: TableMeta) !void {
        if (level >= self.max_levels) return error.InvalidArgument;

        var level_meta = &self.levels[level];
        const new_tables = try self.allocator.realloc(level_meta.tables, level_meta.tables.len + 1);
        level_meta.tables = new_tables;
        level_meta.tables[level_meta.tables.len - 1] = meta;
    }

    /// Remove a table from a level by file path
    pub fn removeTable(self: *Manifest, level: u32, file_path: []const u8) void {
        if (level >= self.max_levels) return;

        var level_meta = &self.levels[level];
        var write_idx: usize = 0;
        for (level_meta.tables) |table| {
            if (!std.mem.eql(u8, table.file_path, file_path)) {
                if (write_idx != write_idx) {
                    level_meta.tables[write_idx] = table;
                }
                write_idx += 1;
            } else {
                self.allocator.free(table.file_path);
                self.allocator.free(table.min_key);
                self.allocator.free(table.max_key);
            }
        }
        level_meta.tables.len = write_idx;
    }

    /// Get all tables in a level
    pub fn getTables(self: *const Manifest, level: u32) []const TableMeta {
        if (level >= self.max_levels) return &.{};
        return self.levels[level].tables;
    }

    /// Save manifest to disk
    pub fn save(self: *const Manifest, dir_path: []const u8) !void {
        const dir = std.Io.Dir.cwd();
        const io = try getIo();

        const manifest_path = try std.fmt.allocPrint(self.allocator, "{s}/MANIFEST", .{dir_path});
        defer self.allocator.free(manifest_path);

        const file = try dir.createFile(io, manifest_path, .{ .truncate = true });
        defer file.close(io);

        // Write level count
        try file.writeStreamingAll(io, std.mem.asBytes(&self.max_levels));

        // Write each level
        for (self.levels, 0..) |level, level_idx| {
            const table_count: u32 = @intCast(level.tables.len);
            try file.writeStreamingAll(io, std.mem.asBytes(&table_count));

            for (level.tables) |table| {
                const path_len: u32 = @intCast(table.file_path.len);
                const min_key_len: u32 = @intCast(table.min_key.len);
                const max_key_len: u32 = @intCast(table.max_key.len);

                try file.writeStreamingAll(io, std.mem.asBytes(&path_len));
                try file.writeStreamingAll(io, table.file_path);
                try file.writeStreamingAll(io, std.mem.asBytes(&min_key_len));
                try file.writeStreamingAll(io, table.min_key);
                try file.writeStreamingAll(io, std.mem.asBytes(&max_key_len));
                try file.writeStreamingAll(io, table.max_key);
                try file.writeStreamingAll(io, std.mem.asBytes(&table.file_size));
                _ = level_idx;
            }
        }
    }

    /// Load manifest from disk
    pub fn load(allocator: Allocator, dir_path: []const u8) !Manifest {
        const dir = std.Io.Dir.cwd();
        const io = try getIo();

        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/MANIFEST", .{dir_path});
        defer allocator.free(manifest_path);

        const file = try dir.openFile(io, manifest_path, .{ .mode = .read_only });
        defer file.close(io);

        const stat = try file.stat(io);
        var file_data = try allocator.alloc(u8, stat.size);
        defer allocator.free(file_data);

        _ = try file.readPositionalAll(io, file_data, 0);

        var pos: usize = 0;

        // Read level count
        if (pos + 4 > file_data.len) return error.Corrupted;
        const max_levels = std.mem.readInt(u32, file_data[pos..][0..4], .little);
        pos += 4;

        const manifest = Manifest.init(allocator, max_levels);

        // Read each level
        for (manifest.levels, 0..) |*level, level_idx| {
            if (pos + 4 > file_data.len) return error.Corrupted;
            const table_count = std.mem.readInt(u32, file_data[pos..][0..4], .little);
            pos += 4;

            if (table_count > 0) {
                level.tables = try allocator.alloc(TableMeta, table_count);
            }

            for (0..table_count) |i| {
                // Read path
                if (pos + 4 > file_data.len) return error.Corrupted;
                const path_len = std.mem.readInt(u32, file_data[pos..][0..4], .little);
                pos += 4;
                if (pos + path_len > file_data.len) return error.Corrupted;
                level.tables[i].file_path = try allocator.dupe(u8, file_data[pos..][0..path_len]);
                pos += path_len;

                // Read min_key
                if (pos + 4 > file_data.len) return error.Corrupted;
                const min_key_len = std.mem.readInt(u32, file_data[pos..][0..4], .little);
                pos += 4;
                if (pos + min_key_len > file_data.len) return error.Corrupted;
                level.tables[i].min_key = try allocator.dupe(u8, file_data[pos..][0..min_key_len]);
                pos += min_key_len;

                // Read max_key
                if (pos + 4 > file_data.len) return error.Corrupted;
                const max_key_len = std.mem.readInt(u32, file_data[pos..][0..4], .little);
                pos += 4;
                if (pos + max_key_len > file_data.len) return error.Corrupted;
                level.tables[i].max_key = try allocator.dupe(u8, file_data[pos..][0..max_key_len]);
                pos += max_key_len;

                // Read file_size
                if (pos + 8 > file_data.len) return error.Corrupted;
                level.tables[i].file_size = std.mem.readInt(u64, file_data[pos..][0..8], .little);
                pos += 8;
                level.tables[i].level = @intCast(level_idx);
            }
        }

        return manifest;
    }

    fn getIo() !std.Io {
        return error.IoNotAvailable;
    }
};
