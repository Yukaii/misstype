//! MSLM v1: 32-byte MWLM-style header, sorted 16-byte word records
//! (hash/u64, unigram/f32, backoff/f32), sorted 12-byte pair records
//! (history ID/u32, target ID/u32, discounted direct probability/f32).
//! Pruned probability mass backs off; every conditional distribution sums to 1.
const std = @import("std");
const full = @import("word_lm.zig");

pub const Table = struct {
    words: []const u8,
    pairs: []const u8,
    vocabulary: usize,
    unknown: usize = 0,
    bos: usize = 0,

    fn u32at(b: []const u8, offset: usize) u32 {
        return std.mem.readInt(u32, b[offset..][0..4], .little);
    }
    fn u64at(b: []const u8, offset: usize) u64 {
        return std.mem.readInt(u64, b[offset..][0..8], .little);
    }
    fn number(b: []const u8, offset: usize) f64 {
        return @as(f32, @bitCast(u32at(b, offset)));
    }
    fn word(self: Table, id: usize) []const u8 {
        return self.words[id * 16 ..][0..16];
    }
    fn lookup(self: Table, want: u64) ?usize {
        var lo: usize = 0;
        var hi = self.vocabulary;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const have = u64at(self.word(mid), 0);
            if (have == want) return mid;
            if (have < want) lo = mid + 1 else hi = mid;
        }
        return null;
    }
    pub fn parse(b: []const u8) !Table {
        if (b.len < 32 or !std.mem.eql(u8, b[0..4], "MSLM") or u32at(b, 4) != 1) return error.BadSparseModel;
        const n: usize = u32at(b, 8);
        const m: usize = u32at(b, 12);
        const expected = 32 + @as(u64, n) * 16 + @as(u64, m) * 12;
        const discount: f64 = @bitCast(u64at(b, 24));
        if (n < 3 or expected != b.len or !std.math.isFinite(discount) or discount <= 0 or discount >= 1) return error.BadSparseModel;
        var table: Table = .{ .words = b[32 .. 32 + n * 16], .pairs = b[32 + n * 16 ..], .vocabulary = n };
        const bos = table.lookup(full.key("<s>")) orelse return error.BadSparseModel;
        _ = table.lookup(full.key("</s>")) orelse return error.BadSparseModel;
        table.unknown = table.lookup(full.key("<unk>")) orelse return error.BadSparseModel;
        table.bos = bos;
        var unigram: f64 = 0;
        var previous_hash: u64 = 0;
        var pair_at: usize = 0;
        for (0..n) |id| {
            const r = table.word(id);
            const hash = u64at(r, 0);
            const p = number(r, 8);
            const backoff = number(r, 12);
            if (id > 0 and hash <= previous_hash) return error.BadSparseModel;
            previous_hash = hash;
            if (!std.math.isFinite(p) or p < 0 or p > 1 or !std.math.isFinite(backoff) or backoff <= 0 or backoff > 1) return error.BadSparseModel;
            if ((id == bos and p != 0) or (id != bos and p == 0)) return error.BadSparseModel;
            unigram += p;
            var mass = backoff;
            var previous_target: ?u32 = null;
            while (pair_at < m) {
                const pair = table.pairs[pair_at * 12 ..][0..12];
                const h = u32at(pair, 0);
                const target = u32at(pair, 4);
                const direct = number(pair, 8);
                if (h < id or h >= n or target >= n or target == bos or !std.math.isFinite(direct) or direct <= 0 or direct > 1) return error.BadSparseModel;
                if (h != id) break;
                if (previous_target) |last| if (target <= last) return error.BadSparseModel;
                previous_target = target;
                mass += direct;
                pair_at += 1;
            }
            if (@abs(mass - 1) > 1e-5) return error.BadSparseModel;
        }
        if (pair_at != m or @abs(unigram - 1) > 1e-5) return error.BadSparseModel;
        return table;
    }
    pub fn probability(self: Table, previous: []const u8, text: []const u8) f64 {
        const h = if (previous.len == 0) self.bos else (self.lookup(full.key(previous)) orelse self.unknown);
        const w = self.lookup(full.key(text)) orelse self.unknown;
        const backoff = number(self.word(h), 12) * number(self.word(w), 8);
        const want = (@as(u64, h) << 32) | w;
        var lo: usize = 0;
        var hi = self.pairs.len / 12;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const pair = self.pairs[mid * 12 ..][0..12];
            const have = (@as(u64, u32at(pair, 0)) << 32) | u32at(pair, 4);
            if (have == want) return number(pair, 8) + backoff;
            if (have < want) lo = mid + 1 else hi = mid;
        }
        return backoff;
    }
};

pub const fixture = [_]u8{ 77, 83, 76, 77, 1, 0, 0, 0, 5, 0, 0, 0, 1, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 232, 63, 211, 237, 100, 102, 27, 62, 30, 26, 85, 85, 213, 62, 0, 0, 128, 63, 94, 83, 145, 103, 27, 232, 98, 30, 171, 170, 170, 61, 0, 0, 128, 63, 18, 76, 227, 47, 24, 138, 212, 111, 0, 0, 0, 0, 51, 51, 51, 62, 153, 234, 39, 212, 26, 1, 212, 123, 171, 170, 234, 62, 0, 0, 128, 63, 225, 185, 111, 214, 77, 224, 1, 230, 171, 170, 42, 61, 0, 0, 128, 63, 2, 0, 0, 0, 0, 0, 0, 0, 51, 51, 83, 63 };

test "sparse backoff stays normalized after dropping all other pairs" {
    const table = try Table.parse(&fixture);
    for ([_][]const u8{ "", "你", "妳", "unknown" }) |history| {
        var sum: f64 = 0;
        for ([_][]const u8{ "你", "妳", "</s>", "<unk>" }) |text| sum += table.probability(history, text);
        try std.testing.expectApproxEqAbs(@as(f64, 1), sum, 1e-6);
    }
    try std.testing.expect(table.probability("", "妳") > table.probability("", "你"));
    try std.testing.expectEqual(table.probability("unknown", "missing"), table.probability("<unk>", "<unk>"));
    try std.testing.expectError(error.BadSparseModel, Table.parse(fixture[0 .. fixture.len - 1]));
    var bad = fixture;
    // Invalid direct mass; a superficially valid header must not admit it.
    std.mem.writeInt(u32, bad[bad.len - 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
    try std.testing.expectError(error.BadSparseModel, Table.parse(&bad));
}
