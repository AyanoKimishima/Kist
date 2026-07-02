const std = @import("std");

const Allocator = std.mem.Allocator;

/// Snapshot provides MVCC-style versioned reads.
/// Each snapshot captures a consistent view of the database at a point in time.
pub const Snapshot = struct {
    version: u64,
    timestamp: i64,
    allocator: Allocator,

    pub fn init(allocator: Allocator, version: u64) Snapshot {
        return Snapshot{
            .version = version,
            .timestamp = std.time.timestamp(),
            .allocator = allocator,
        };
    }
};

/// Snapshot manager tracks active snapshots and their versions.
pub const SnapshotManager = struct {
    allocator: Allocator,
    snapshots: []Snapshot,
    next_version: std.atomic.Value(u64),

    pub fn init(allocator: Allocator) SnapshotManager {
        return SnapshotManager{
            .allocator = allocator,
            .snapshots = &.{},
            .next_version = std.atomic.Value(u64).init(1),
        };
    }

    pub fn deinit(self: *SnapshotManager) void {
        self.allocator.free(self.snapshots);
    }

    /// Create a new snapshot at the current version
    pub fn createSnapshot(self: *SnapshotManager) !Snapshot {
        const version = self.next_version.fetchAdd(1, .monotonic);
        const snap = Snapshot.init(self.allocator, version);

        const new_snapshots = try self.allocator.realloc(self.snapshots, self.snapshots.len + 1);
        self.snapshots = new_snapshots;
        self.snapshots[self.snapshots.len - 1] = snap;

        return snap;
    }

    /// Release a snapshot
    pub fn releaseSnapshot(self: *SnapshotManager, version: u64) void {
        var write_idx: usize = 0;
        for (self.snapshots) |snap| {
            if (snap.version != version) {
                self.snapshots[write_idx] = snap;
                write_idx += 1;
            }
        }
        self.snapshots.len = write_idx;
    }

    /// Get the minimum active version (for determining when old SSTables can be removed)
    pub fn minVersion(self: *const SnapshotManager) ?u64 {
        if (self.snapshots.len == 0) return null;
        var min_version: u64 = std.math.maxInt(u64);
        for (self.snapshots) |snap| {
            if (snap.version < min_version) {
                min_version = snap.version;
            }
        }
        return min_version;
    }

    /// Check if a version is still needed by any active snapshot
    pub fn isVersionNeeded(self: *const SnapshotManager, version: u64) bool {
        for (self.snapshots) |snap| {
            if (snap.version >= version) return true;
        }
        return false;
    }

    /// Get the current version
    pub fn currentVersion(self: *const SnapshotManager) u64 {
        return self.next_version.load(.monotonic);
    }
};
