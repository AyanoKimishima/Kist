const std = @import("std");
const kist = @import("kist");

const DB = kist.DB;
const Io = std.Io;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "bench_data";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};

    std.debug.print("=== Kist KV Engine Benchmark ===\n\n", .{});

    // Open database
    var db = try DB.open(allocator, io, dir, .{});
    defer db.close();

    // Benchmark sequential puts
    const num_keys = 100_000;
    {
        const start = Io.Timestamp.now(io, .awake);
        for (0..num_keys) |i| {
            const key = try std.fmt.allocPrint(allocator, "key_{d:0>10}", .{i});
            defer allocator.free(key);
            const val = try std.fmt.allocPrint(allocator, "value_{d}", .{i});
            defer allocator.free(val);
            try db.put(key, val);
        }
        const duration = start.durationTo(Io.Timestamp.now(io, .awake));
        const elapsed_ms = duration.toMilliseconds();
        const ops_per_sec = @as(f64, @floatFromInt(num_keys)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0);
        std.debug.print("Sequential PUT: {d} ops in {d}ms ({d:.0} ops/sec)\n", .{ num_keys, elapsed_ms, ops_per_sec });
    }

    // Benchmark random gets
    {
        const start = Io.Timestamp.now(io, .awake);
        var found: usize = 0;
        for (0..num_keys) |i| {
            const key = try std.fmt.allocPrint(allocator, "key_{d:0>10}", .{i});
            defer allocator.free(key);
            if (try db.get(key)) |_| {
                found += 1;
            }
        }
        const duration = start.durationTo(Io.Timestamp.now(io, .awake));
        const elapsed_ms = duration.toMilliseconds();
        const ops_per_sec = @as(f64, @floatFromInt(num_keys)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0);
        std.debug.print("Random GET: {d}/{d} found in {d}ms ({d:.0} ops/sec)\n", .{ found, num_keys, elapsed_ms, ops_per_sec });
    }

    // Benchmark updates
    {
        const start = Io.Timestamp.now(io, .awake);
        for (0..num_keys) |i| {
            const key = try std.fmt.allocPrint(allocator, "key_{d:0>10}", .{i});
            defer allocator.free(key);
            const val = try std.fmt.allocPrint(allocator, "updated_{d}", .{i});
            defer allocator.free(val);
            try db.put(key, val);
        }
        const duration = start.durationTo(Io.Timestamp.now(io, .awake));
        const elapsed_ms = duration.toMilliseconds();
        const ops_per_sec = @as(f64, @floatFromInt(num_keys)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0);
        std.debug.print("Sequential UPDATE: {d} ops in {d}ms ({d:.0} ops/sec)\n", .{ num_keys, elapsed_ms, ops_per_sec });
    }

    // Benchmark deletes
    {
        const start = Io.Timestamp.now(io, .awake);
        for (0..num_keys / 2) |i| {
            const key = try std.fmt.allocPrint(allocator, "key_{d:0>10}", .{i});
            defer allocator.free(key);
            try db.delete(key);
        }
        const duration = start.durationTo(Io.Timestamp.now(io, .awake));
        const elapsed_ms = duration.toMilliseconds();
        const ops_per_sec = @as(f64, @floatFromInt(num_keys / 2)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0);
        std.debug.print("Sequential DELETE: {d} ops in {d}ms ({d:.0} ops/sec)\n", .{ num_keys / 2, elapsed_ms, ops_per_sec });
    }

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}
