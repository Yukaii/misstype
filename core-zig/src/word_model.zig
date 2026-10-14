//! Developer model formats share the same conditional scoring contract.
const std = @import("std");
const full = @import("word_lm.zig");
const sparse = @import("sparse_lm.zig");

pub const Table = union(enum) {
    full: full.Table,
    sparse: sparse.Table,

    pub fn parse(bytes: []const u8) !Table {
        if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "MSLM")) return .{ .sparse = try sparse.Table.parse(bytes) };
        return .{ .full = try full.Table.parse(bytes) };
    }
    pub fn probability(self: Table, previous: []const u8, word: []const u8) f64 {
        return switch (self) {
            .full => |table| table.probability(previous, word),
            .sparse => |table| table.probability(previous, word),
        };
    }
};
