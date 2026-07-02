const std = @import("std");

/// RwLock: supports one writer OR many concurrent readers.
/// Uses two atomics to prevent writer starvation:
///   state: bit 0 = writer active, bits 1..31 = reader count
///   writer_waiting: set by writer before spinning, checked by new readers
pub const RwLock = struct {
    state: std.atomic.Value(u32),
    writer_waiting: std.atomic.Value(u32),

    const WRITER_BIT: u32 = 1;

    pub const WriteHeld = struct {
        lock: *RwLock,
        pub fn release(self: WriteHeld) void {
            self.lock.writer_waiting.store(0, .release);
            self.lock.state.store(0, .release);
        }
    };

    pub const ReadHeld = struct {
        lock: *RwLock,
        pub fn release(self: ReadHeld) void {
            _ = self.lock.state.fetchSub(2, .release);
        }
    };

    pub fn init() RwLock {
        return .{
            .state = std.atomic.Value(u32).init(0),
            .writer_waiting = std.atomic.Value(u32).init(0),
        };
    }

    /// Acquire exclusive write lock
    pub fn writeLock(self: *RwLock) WriteHeld {
        // Signal that a writer is waiting — blocks new readers
        self.writer_waiting.store(1, .release);
        while (true) {
            const old = self.state.cmpxchgStrong(0, WRITER_BIT, .acquire, .monotonic);
            if (old == null) return .{ .lock = self };
            std.Thread.yield() catch {};
        }
    }

    /// Acquire shared read lock
    pub fn readLock(self: *RwLock) ReadHeld {
        while (true) {
            // If a writer is waiting, back off to let it through
            if (self.writer_waiting.load(.acquire) != 0) {
                std.Thread.yield() catch {};
                continue;
            }
            const s = self.state.load(.acquire);
            if (s & WRITER_BIT != 0) {
                std.Thread.yield() catch {};
                continue;
            }
            if (self.state.cmpxchgStrong(s, s + 2, .acquire, .monotonic) == null) {
                return .{ .lock = self };
            }
        }
    }

    pub fn tryWriteLock(self: *RwLock) ?WriteHeld {
        self.writer_waiting.store(1, .release);
        if (self.state.cmpxchgStrong(0, WRITER_BIT, .acquire, .monotonic) == null) {
            return .{ .lock = self };
        }
        self.writer_waiting.store(0, .release);
        return null;
    }

    pub fn tryReadLock(self: *RwLock) ?ReadHeld {
        if (self.writer_waiting.load(.acquire) != 0) return null;
        const s = self.state.load(.acquire);
        if (s & WRITER_BIT != 0) return null;
        if (self.state.cmpxchgStrong(s, s + 2, .acquire, .monotonic) == null) {
            return .{ .lock = self };
        }
        return null;
    }
};

test "RwLock basics" {
    var rw = RwLock.init();
    {
        const r = rw.readLock();
        r.release();
    }
    {
        const w = rw.writeLock();
        w.release();
    }
}
