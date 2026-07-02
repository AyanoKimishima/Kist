pub const Config = struct {
    /// Directory to store all database files
    dir: []const u8 = "./kist_data",
    /// Maximum size of the in-memory MemTable before flushing to SSTable
    memtable_max_size: usize = 4 * 1024 * 1024, // 4MB
    /// Size of each data block in SSTable
    block_size: usize = 4096, // 4KB
    /// Maximum number of SSTables in Level 0 before triggering compaction
    l0_compaction_threshold: usize = 4,
    /// Maximum number of levels
    max_levels: usize = 7,
    /// Size ratio between levels (Leveled compaction)
    level_ratio: usize = 10,
    /// Bloom filter bits per key
    bloom_bits_per_key: usize = 10,
    /// WAL sync mode
    wal_sync: WalSync = .no_sync,

    pub const WalSync = enum {
        no_sync,
        every_write,
        every_second,
    };
};

pub const default_config = Config{};
