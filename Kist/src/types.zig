const std = @import("std");

pub const OpType = enum(u8) {
    put = 0,
    delete = 1,
};

pub const KVEntry = struct {
    key: []const u8,
    value: ?[]const u8,
    op: OpType,

    pub fn isDeleted(self: KVEntry) bool {
        return self.op == .delete;
    }
};

pub const DBError = error{
    IOError,
    OutOfMemory,
    KeyNotFound,
    Corrupted,
    InvalidArgument,
    DBClosed,
    TxConflict,
    TxNotActive,
};

pub const ValueType = enum(u8) {
    string = 0,
    bytes = 1,
};
