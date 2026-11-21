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
    /// Word-path search scores many entries against few histories: resolve
    /// each word once (`history`, `target`), then score pairs of IDs.
    pub fn history(self: Table, previous: []const u8) u32 {
        return switch (self) {
            .full => |table| table.historyId(previous),
            .sparse => |table| table.historyId(previous),
        };
    }
    pub fn target(self: Table, word: []const u8) u32 {
        return switch (self) {
            .full => |table| table.targetId(word),
            .sparse => |table| table.targetId(word),
        };
    }
    pub fn conditional(self: Table, h: u32, w: u32) f64 {
        return switch (self) {
            .full => |table| table.conditional(h, w),
            .sparse => |table| table.conditional(h, w),
        };
    }
};

test "ID scoring equals string scoring" {
    inline for (.{ &full.fixture, &sparse.fixture }) |bytes| {
        const table = try Table.parse(bytes);
        for ([_][]const u8{ "", "你", "妳", "unseen" }) |previous| {
            for ([_][]const u8{ "你", "妳", "</s>", "absent" }) |word| {
                try std.testing.expectEqual(table.probability(previous, word), table.conditional(table.history(previous), table.target(word)));
            }
        }
    }
}
