const std = @import("std");
const kist = @import("kist");

const DB = kist.DB;
const Io = std.Io;
const Thread = std.Thread;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "bench_mt_data";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    std.debug.print("=== Kist Multi-Threaded Benchmark ===\n\n", .{});

    var db = try DB.open(allocator, io, dir, .{});
    defer db.close();

    const num_keys: usize = 100_000;

    // Pre-populate (single-threaded)
    std.debug.print("Pre-populating {d} keys...\n", .{num_keys});
    for (0..num_keys) |i| {
        const key = try std.fmt.allocPrint(allocator, "key_{d:0>10}", .{i});
        defer allocator.free(key);
        const val = try std.fmt.allocPrint(allocator, "value_{d}", .{i});
        defer allocator.free(val);
        try db.put(key, val);
    }
    std.debug.print("Done. Memtable has {d} entries.\n\n", .{db.memtableSize()});

    // --- Concurrent Reads (4 threads) ---
    {
        const start = Io.Timestamp.now(io, .awake);
        const num_threads: usize = 4;
        const per_thread = num_keys / num_threads;

        var threads: [4]Thread = undefined;
        for (0..num_threads) |t| {
            threads[t] = try Thread.spawn(.{}, readWorker, .{ &db, t, per_thread, allocator });
        }
        for (threads) |t| t.join();

        const duration = start.durationTo(Io.Timestamp.now(io, .awake));
        const ms = duration.toMilliseconds();
        const total = num_keys;
        const ops = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(ms)) / 1000.0);
        std.debug.print("Concurrent READ  ({d} threads): {d} ops in {d}ms ({d:.0} ops/sec)\n", .{ num_threads, total, ms, ops });
    }

    // --- Single-threaded read baseline ---
    {
        const start = Io.Timestamp.now(io, .awake);
        for (0..num_keys) |i| {
            const key = try std.fmt.allocPrint(allocator, "key_{d:0>10}", .{i});
            defer allocator.free(key);
            _ = try db.get(key);
        }
        const duration = start.durationTo(Io.Timestamp.now(io, .awake));
        const ms = duration.toMilliseconds();
        const total = num_keys;
        const ops = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(ms)) / 1000.0);
        std.debug.print("Single-thread READ baseline:     {d} ops in {d}ms ({d:.0} ops/sec)\n", .{ total, ms, ops });
    }

    std.debug.print("\n=== Multi-Threaded Benchmark Complete ===\n", .{});
}

fn readWorker(db_ptr: *DB, thread_id: usize, count: usize, alloc: std.mem.Allocator) void {
    _ = thread_id;
    for (0..count) |i| {
        const key = alloc.alloc(u8, 20) catch return;
        defer alloc.free(key);
        _ = std.fmt.bufPrint(key, "key_{d:0>10}", .{i}) catch continue;
        _ = db_ptr.get(key) catch {};
    }
}
