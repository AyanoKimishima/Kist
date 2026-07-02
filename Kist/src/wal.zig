const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

/// Write-Ahead Log for durability.
/// Format: [4 bytes: total_len][1 byte: op][4 bytes: key_len][key...][4 bytes: val_len][val...]
pub const WAL = struct {
    file: File,
    io: Io,
    dir_path: []const u8,
    allocator: Allocator,
    bytes_written: u64,

    pub const Header = extern struct {
        total_len: u32 align(1),
        op: u8 align(1),
        key_len: u32 align(1),
    };

    pub const ValHeader = extern struct {
        val_len: u32 align(1),
    };

    pub fn init(allocator: Allocator, io: Io, dir_path: []const u8) !WAL {
        // Ensure directory exists
        Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const wal_path = try std.fs.path.join(allocator, &.{ dir_path, "wal.log" });
        defer allocator.free(wal_path);

        const file = try Dir.cwd().createFile(io, wal_path, .{
            .truncate = false,
            .read = true,
        });

        const stat = try file.stat(io);

        return WAL{
            .file = file,
            .io = io,
            .dir_path = try allocator.dupe(u8, dir_path),
            .allocator = allocator,
            .bytes_written = stat.size,
        };
    }

    pub fn deinit(self: *WAL) void {
        self.file.close(self.io);
        self.allocator.free(self.dir_path);
    }

    /// Append a put entry to the WAL
    pub fn appendPut(self: *WAL, key: []const u8, value: []const u8) !void {
        const val_len: u32 = @intCast(value.len);
        try self.appendEntry(.put, key, std.mem.asBytes(&val_len));
        // Write the actual value bytes
        try self.file.writeStreamingAll(self.io, value);
        self.bytes_written += @intCast(value.len);
    }

    /// Append a delete entry to the WAL
    pub fn appendDelete(self: *WAL, key: []const u8) !void {
        const val_len: u32 = 0;
        try self.appendEntry(.delete, key, std.mem.asBytes(&val_len));
    }

    fn appendEntry(self: *WAL, op: types.OpType, key: []const u8, val_header: []const u8) !void {
        const key_len: u32 = @intCast(key.len);
        const total_len: u32 = @intCast(1 + 4 + key.len + val_header.len); // op + key_len + key + val_header

        // Write header
        try self.file.writeStreamingAll(self.io, std.mem.asBytes(&total_len));
        try self.file.writeStreamingAll(self.io, &[_]u8{@intFromEnum(op)});
        try self.file.writeStreamingAll(self.io, std.mem.asBytes(&key_len));
        try self.file.writeStreamingAll(self.io, key);
        try self.file.writeStreamingAll(self.io, val_header);

        self.bytes_written += @sizeOf(u32) + 1 + 4 + key.len + val_header.len;
    }

    /// Clear the WAL (used after memtable flush)
    pub fn clear(self: *WAL) !void {
        try self.file.setLength(self.io, 0);
        self.bytes_written = 0;
    }

    /// WAL entry for replay
    pub const Entry = struct {
        op: types.OpType,
        key: []const u8,
        value: ?[]const u8,
    };

    /// Reader for WAL replay
    pub const Reader = struct {
        file: File,
        io: Io,
        pos: u64,
        allocator: Allocator,

        pub fn init(file: File, io: Io, allocator: Allocator) Reader {
            return .{ .file = file, .io = io, .pos = 0, .allocator = allocator };
        }

        pub fn next(self: *Reader) !?Entry {
            const stat = try self.file.stat(self.io);
            if (self.pos >= stat.size) return null;

            // Read total_len
            var len_buf: [4]u8 = undefined;
            _ = try self.file.readPositionalAll(self.io, &len_buf, self.pos);
            const total_len = std.mem.readInt(u32, &len_buf, .little);
            self.pos += 4;

            if (total_len < 5) return error.Corrupted; // at least op + key_len

            // Read op
            var op_buf: [1]u8 = undefined;
            _ = try self.file.readPositionalAll(self.io, &op_buf, self.pos);
            self.pos += 1;
            const op: types.OpType = @enumFromInt(op_buf[0]);

            // Read key_len
            _ = try self.file.readPositionalAll(self.io, &len_buf, self.pos);
            const key_len = std.mem.readInt(u32, &len_buf, .little);
            self.pos += 4;

            // Read key
            const key_buf = try self.allocator.alloc(u8, key_len);
            errdefer self.allocator.free(key_buf);
            _ = try self.file.readPositionalAll(self.io, key_buf, self.pos);
            self.pos += key_len;

            // Read val_len
            _ = try self.file.readPositionalAll(self.io, &len_buf, self.pos);
            const val_len = std.mem.readInt(u32, &len_buf, .little);
            self.pos += 4;

            // Read value (if present)
            var value: ?[]const u8 = null;
            if (val_len > 0) {
                const val_buf = try self.allocator.alloc(u8, val_len);
                errdefer self.allocator.free(val_buf);
                _ = try self.file.readPositionalAll(self.io, val_buf, self.pos);
                self.pos += val_len;
                value = val_buf;
            }

            return Entry{
                .op = op,
                .key = key_buf,
                .value = value,
            };
        }
    };

    pub fn reader(self: *WAL, allocator: Allocator) Reader {
        return Reader.init(self.file, self.io, allocator);
    }
};
