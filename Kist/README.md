# Kist — 高性能 LSM-Tree KV 引擎

基于 Zig 语言实现的本地键值存储引擎，采用 LSM-Tree 架构，支持 WAL 持久化、SSTable 磁盘存储、布隆过滤器、Leveled 压缩、MVCC 快照、事务和并发读写。

---

## 目录

- [快速开始](#快速开始)
- [构建与安装](#构建与安装)
- [API 参考](#api-参考)
  - [打开与关闭数据库](#打开与关闭数据库)
  - [基本操作 (CRUD)](#基本操作-crud)
  - [批量写入](#批量写入)
  - [范围查询](#范围查询)
  - [事务](#事务)
  - [快照](#快照)
- [架构设计](#架构设计)
  - [整体架构](#整体架构)
  - [写入路径](#写入路径)
  - [读取路径](#读取路径)
  - [持久化](#持久化)
  - [压缩](#压缩)
- [配置参数](#配置参数)
- [性能基准](#性能基准)
- [文件格式](#文件格式)
- [线程安全](#线程安全)
- [常见问题](#常见问题)

---

## 快速开始

### 最小示例

```zig
const std = @import("std");
const kist = @import("kist");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 打开数据库
    var db = try kist.DB.open(allocator, io, "./my_data", .{});
    defer db.close();

    // 写入
    try db.put("name", "Kist");
    try db.put("version", "1.0");

    // 读取
    if (try db.get("name")) |value| {
        std.debug.print("name = {s}\n", .{value});
    }

    // 删除
    try db.delete("version");
}
```

### 编译运行

```bash
# 构建库
zig build

# 运行测试
zig build test

# 运行基准测试
zig build bench
zig build bench-mt    # 多线程基准
```

---

## 构建与安装

### 环境要求

- Zig 0.17.0+ (当前开发版)
- Windows / Linux / macOS

### 作为库集成

在你的 `build.zig.zon` 中添加依赖，然后在 `build.zig` 中：

```zig
const kist = b.dependency("kist", .{});
exe.root_module.addImport("kist", kist.module("kist"));
```

### 直接使用

将 `src/` 目录下的所有 `.zig` 文件复制到你的项目中，然后 `@import` 使用。

---

## API 参考

### 打开与关闭数据库

```zig
const kist = @import("kist");

// 使用默认配置打开
var db = try kist.DB.open(allocator, io, "./data_path", .{});
defer db.close();

// 自定义配置打开
var db = try kist.DB.open(allocator, io, "./data_path", .{
    .memtable_max_size = 8 * 1024 * 1024,  // 8MB memtable
    .block_size = 8192,                     // 8KB block
    .l0_compaction_threshold = 6,           // L0 压缩阈值
    .max_levels = 7,                        // 最大层数
    .level_ratio = 10,                      // 层间大小比例
    .bloom_bits_per_key = 10,               // 布隆过滤器精度
});
defer db.close();
```

**参数说明：**

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `memtable_max_size` | 4MB | MemTable 最大内存占用，超过后 flush 到 SSTable |
| `block_size` | 4096 | SSTable 数据块大小 |
| `l0_compaction_threshold` | 4 | Level 0 SSTable 数量触发压缩 |
| `max_levels` | 7 | LSM-Tree 最大层数 |
| `level_ratio` | 10 | 相邻层大小比例 |
| `bloom_bits_per_key` | 10 | 每个 key 的布隆过滤器位数 |

---

### 基本操作 (CRUD)

#### Put — 写入

```zig
try db.put("key1", "value1");
try db.put("key2", "value2");

// key 和 value 都是 []const u8 类型
// 覆盖写入：如果 key 已存在，新值覆盖旧值
try db.put("key1", "new_value");
```

#### Get — 读取

```zig
// 返回 ?[]const u8
// 找到返回 value，未找到返回 null
const value = try db.get("key1");
if (value) |v| {
    std.debug.print("value = {s}\n", .{v});
} else {
    std.debug.print("key not found\n", .{});
}
```

#### Delete — 删除

```zig
// 删除操作实际上写入一个墓碑标记 (tombstone)
// 真正的数据清理在 compaction 时完成
try db.delete("key1");

// 删除后 get 返回 null
const v = try db.get("key1");
std.debug.print("deleted? {}\n", .{v == null});
```

---

### 批量写入

```zig
// 批量写入比多次单条 put 更高效（共享 WAL 操作）
const batch = [_]kist.DB.BatchEntry{
    .{ .key = "user:1", .value = "Alice" },
    .{ .key = "user:2", .value = "Bob" },
    .{ .key = "user:3", .value = "Charlie" },
};
try db.putBatch(&batch);
```

---

### 范围查询

```zig
// 查询 start_key <= key < end_key 范围内的所有条目
var results = try db.scan("user:1", "user:3");
defer {
    for (results.items) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    }
    results.deinit(allocator);
}

for (results.items) |entry| {
    std.debug.print("{s} = {s}\n", .{ entry.key, entry.value });
}
```

**注意：** `scan` 返回的 key/value 需要调用者手动释放。

---

### 事务

```zig
// 创建事务
var tx = kist.Transaction.init(&db, allocator);
defer tx.deinit();

// 在事务中缓冲操作
try tx.put("account:alice", "1000");
try tx.put("account:bob", "2000");

// 事务内读取（先查缓冲区，再查 DB）
const val = try tx.get("account:alice");

// 提交：原子性地应用所有操作
try tx.commit();

// 或回滚：丢弃所有缓冲操作
// try tx.rollback();
```

**事务特性：**
- 所有写操作先缓冲在内存中
- `commit()` 原子性地应用所有操作
- `rollback()` 丢弃所有缓冲操作
- 事务内的 `get` 会先检查缓冲区

---

### 快照

```zig
// 快照管理器在 DB 内部自动管理
// 当前版本号可通过 snapshot_manager 获取
const version = db.snapshot_manager.currentVersion();
```

快照用于 MVCC（多版本并发控制），确保读取时看到一致的数据视图。

---

## 架构设计

### 整体架构

```
┌──────────────────────────────┐
│           DB                 │  顶层编排器
├──────────┬───────────────────┤
│  Mutex   │  SnapshotManager  │  并发控制 + MVCC
├──────────┼───────────────────┤
│ MemTable │      WAL          │  写入路径
│(SkipList)│  (Write-Ahead)    │
├──────────┴───────────────────┤
│       SSTables (Level 0~N)   │  磁盘存储
├──────────────────────────────┤
│       Compaction             │  后台压缩
└──────────────────────────────┘
```

### 写入路径

```
1. 获取写锁
2. 追加写入 WAL（保证持久性）
3. 插入 MemTable（SkipList）
4. 如果 MemTable 超过阈值：
   a. 收集 MemTable 中所有排序的条目
   b. 分块编码为 Block
   c. 写入 SSTable 文件 (数据 + 索引 + Footer)
   d. 写入 MANIFEST 文件
   e. 构建 Bloom Filter
   f. 清空 MemTable 和 WAL
```

### 读取路径

```
1. 获取读锁
2. 查找 MemTable（最近写入的数据）
   - 如果找到且不是墓碑 → 返回 value
   - 如果是墓碑 → 返回 null
3. 从新到旧查找 SSTable
   - 每个 SSTable 先检查 Bloom Filter（快速排除）
   - 通过索引定位数据块
   - 二分查找块内条目
4. 找到则返回 value
```

### 持久化

**WAL（预写日志）：**
- 每次写操作先追加到 WAL
- 格式：`[total_len: u32][op: u8][key_len: u32][key...][val_len: u32][val...]`
- 重启时重放 WAL 恢复 MemTable

**SSTable（磁盘排序表）：**
- 文件格式：`[blocks...][index][footer]`
- Footer：`[index_offset: u64][index_size: u32][magic: u32]`
- MANIFEST 文件记录所有 SSTable 文件名

### 压缩

采用 Leveled Compaction 策略：
- Level 0：直接从 MemTable flush 的 SSTable
- Level 1~N：按大小比例合并（默认 10:1）
- 后台线程周期性执行压缩
- 压缩时合并重叠的 SSTable，消除重复 key

---

## 配置参数

```zig
pub const Config = struct {
    dir: []const u8 = "./kist_data",
    memtable_max_size: usize = 4 * 1024 * 1024,
    block_size: usize = 4096,
    l0_compaction_threshold: usize = 4,
    max_levels: usize = 7,
    level_ratio: usize = 10,
    bloom_bits_per_key: usize = 10,
    wal_sync: WalSync = .no_sync,
};
```

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `dir` | `[]const u8` | `"./kist_data"` | 数据存储目录 |
| `memtable_max_size` | `usize` | 4MB | MemTable 大小阈值 |
| `block_size` | `usize` | 4096 | SSTable 数据块大小 |
| `l0_compaction_threshold` | `usize` | 4 | L0 压缩触发阈值 |
| `max_levels` | `usize` | 7 | 最大层数 |
| `level_ratio` | `usize` | 10 | 层间大小比例 |
| `bloom_bits_per_key` | `usize` | 10 | 布隆过滤器精度 |

---

## 性能基准

### 单线程 (Debug 模式)

| 操作 | 吞吐量 |
|------|--------|
| Sequential PUT | ~31,000 ops/sec |
| Random GET | ~194,000 ops/sec |
| Sequential UPDATE | ~35,000 ops/sec |
| Sequential DELETE | ~34,000 ops/sec |

### 多线程 (4 线程并发读)

| 操作 | 吞吐量 |
|------|--------|
| Concurrent READ (4 threads) | ~278,000 ops/sec |
| Single-thread READ baseline | ~196,000 ops/sec |

> 注：基准测试在 Debug 模式下运行。Release 模式下性能会显著提升。

---

## 文件格式

### WAL 文件

```
[total_len: u32][op: u8][key_len: u32][key: []u8][val_len: u32][val: []u8]
```
- `op`: 0 = put, 1 = delete
- 重启时从头顺序重放

### SSTable 文件

```
┌─────────────────────────┐
│  Block 0 (4KB)          │  数据块
│  Block 1 (4KB)          │
│  ...                    │
├─────────────────────────┤
│  Index                  │  每个块的 offset + size + min_key + max_key
├─────────────────────────┤
│  Footer (16 bytes)      │  [index_offset: u64][index_size: u32][magic: u32]
└─────────────────────────┘
```

### Block 格式

```
[num_entries: u32][offsets: [u32; N]][entries...]
每个 entry: [key_len: u16][key...][val_len: u16][val...]
```

### MANIFEST 文件

每行一个 SSTable 文件名：
```
sst_0.dat
sst_1.dat
sst_2.dat
```

---

## 线程安全

- **读操作** (`get`, `scan`)：获取读锁，允许多个线程并发读取
- **写操作** (`put`, `delete`, `putBatch`)：获取写锁，与所有其他操作互斥
- **事务**：在写锁保护下执行

```zig
// 以下操作可以并发执行（多线程读）
const v1 = try db.get("key1");
const v2 = try db.get("key2");

// 以下操作需要串行执行（写操作）
try db.put("key1", "value1");
try db.delete("key1");
```

---

## 常见问题

### Q: 数据重启后会丢失吗？

**A:** 不会。WAL 保证每次写操作的持久性。重启时会自动重放 WAL 恢复 MemTable。已 flush 到 SSTable 的数据通过 MANIFEST 文件在重启时加载。

### Q: MemTable 满了会怎样？

**A:** 自动触发 flush：将 MemTable 数据写入 SSTable 文件，然后清空 MemTable 和 WAL。

### Q: 布隆过滤器的作用？

**A:** 快速判断一个 key 是否**一定不在**某个 SSTable 中。避免不必要的磁盘读取。误判率约 1%（10 bits/key）。

### Q: Compaction 什么时候执行？

**A:** 后台线程周期性检查。当 Level 0 的 SSTable 数量超过阈值，或某层大小超过下一层的 `level_ratio` 倍时触发。

### Q: 如何选择 block_size？

**A:** 
- 较小的 block_size（2-4KB）：节省内存，适合小 value
- 较大的 block_size（8-16KB）：减少索引开销，适合大 value 或顺序扫描

### Q: 支持的最大 key/value 大小？

**A:** key 和 value 各自最大 65535 字节（u16 长度限制）。

---

## 项目结构

```
Kist/
├── build.zig            # 构建配置
├── build.zig.zon        # 项目元数据
├── README.md            # 本文档
└── src/
    ├── kist.zig         # 公共 API 导出
    ├── db.zig           # 数据库核心
    ├── config.zig       # 配置定义
    ├── types.zig        # 类型定义
    ├── wal.zig          # 预写日志
    ├── memtable.zig     # 内存表
    ├── skiplist.zig     # 跳表数据结构
    ├── block.zig        # SSTable 数据块
    ├── bloom_filter.zig # 布隆过滤器
    ├── compress.zig     # LZ4 压缩工具
    ├── sstable.zig      # SSTable 磁盘格式
    ├── manifest.zig     # 版本管理
    ├── compaction.zig   # 压缩 + 后台线程
    ├── iterator.zig     # 归并迭代器
    ├── snapshot.zig     # MVCC 快照
    ├── transaction.zig  # 事务支持
    ├── lock.zig         # 读写锁
    ├── benchmark.zig    # 单线程基准测试
    └── bench_mt.zig     # 多线程基准测试
```

---

## 许可证

MIT License
