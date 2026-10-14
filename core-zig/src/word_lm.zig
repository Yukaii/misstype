//! Developer-only full conditional word model. Sorted, little-endian counts.
//! MWLM v1: magic, version/u32, vocabulary/u32, pairs/u32, tokens/u64,
//! discount/f64; word records (hash/u64, unigram/outgoing/distinct/u32),
//! pair records (previous/current/u64, count/u32). Includes BOS, EOS, UNK.
const std = @import("std");
const record_len = 20;
const header_len = 32;

pub fn key(word: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (word) |b| h = (h ^ b) *% 0x100000001b3;
    return h;
}

pub const Table = struct {
    words: []const u8,
    pairs: []const u8,
    vocabulary: usize,
    tokens: u64,
    discount: f64,

    fn u64at(bytes: []const u8, offset: usize) u64 {
        return std.mem.readInt(u64, bytes[offset..][0..8], .little);
    }
    fn u32at(bytes: []const u8, offset: usize) u32 {
        return std.mem.readInt(u32, bytes[offset..][0..4], .little);
    }
    pub fn parse(bytes: []const u8) !Table {
        if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..4], "MWLM") or u32at(bytes, 4) != 1) return error.BadWordModel;
        const n: usize = u32at(bytes, 8);
        const m: usize = u32at(bytes, 12);
        const discount: f64 = @bitCast(u64at(bytes, 24));
        if (n < 3 or bytes.len != header_len + (n + m) * record_len or !std.math.isFinite(discount) or discount <= 0 or discount >= 1) return error.BadWordModel;
        const table: Table = .{ .words = bytes[header_len .. header_len + n * record_len], .pairs = bytes[header_len + n * record_len ..], .vocabulary = n, .tokens = u64at(bytes, 16), .discount = discount };
        var total: u64 = 0;
        var outgoing_total: u64 = 0;
        var prev: u64 = 0;
        for (0..n) |i| {
            const r = table.words[i * record_len ..][0..record_len];
            const h = u64at(r, 0);
            if (i > 0 and h <= prev) return error.BadWordModel;
            prev = h;
            total += u32at(r, 8);
            outgoing_total += u32at(r, 12);
            if (u32at(r, 16) > u32at(r, 12)) return error.BadWordModel;
        }
        if (total != table.tokens or table.record(key("<s>")) == null or table.record(key("</s>")) == null or table.record(key("<unk>")) == null) return error.BadWordModel;
        if (u32at(table.record(key("<s>")).?, 8) != 0) return error.BadWordModel;
        var previous: u64 = 0;
        var current: u64 = 0;
        var outgoing: u64 = 0;
        var distinct: u32 = 0;
        var pair_total: u64 = 0;
        for (0..m) |i| {
            const r = table.pairs[i * record_len ..][0..record_len];
            const h = u64at(r, 0);
            const w = u64at(r, 8);
            if (u32at(r, 16) == 0 or table.record(h) == null or table.record(w) == null or w == key("<s>")) return error.BadWordModel;
            if (i > 0 and (h < previous or (h == previous and w <= current))) return error.BadWordModel;
            if (i > 0 and h != previous) {
                const history = table.record(previous).?;
                if (outgoing != u32at(history, 12) or distinct != u32at(history, 16)) return error.BadWordModel;
                outgoing = 0;
                distinct = 0;
            }
            outgoing += u32at(r, 16);
            pair_total += u32at(r, 16);
            distinct += 1;
            previous = h;
            current = w;
        }
        if (m > 0) {
            const history = table.record(previous).?;
            if (outgoing != u32at(history, 12) or distinct != u32at(history, 16)) return error.BadWordModel;
        }
        if (pair_total != outgoing_total or pair_total != table.tokens) return error.BadWordModel;
        return table;
    }
    fn record(self: Table, want: u64) ?[]const u8 {
        var lo: usize = 0;
        var hi = self.vocabulary;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = self.words[mid * record_len ..][0..record_len];
            const have = u64at(r, 0);
            if (have == want) return r;
            if (have < want) lo = mid + 1 else hi = mid;
        }
        return null;
    }
    pub fn probability(self: Table, previous: []const u8, word: []const u8) f64 {
        const target = self.record(key(word)) orelse self.record(key("<unk>")).?;
        const history = self.record(key(if (previous.len == 0) "<s>" else previous)) orelse self.record(key("<unk>")).?;
        const p = (@as(f64, @floatFromInt(u32at(target, 8))) + 1) / (@as(f64, @floatFromInt(self.tokens)) + @as(f64, @floatFromInt(self.vocabulary - 1)));
        const count: f64 = @floatFromInt(u32at(history, 12));
        if (count == 0) return p;
        const h = u64at(history, 0);
        const w = u64at(target, 0);
        var lo: usize = 0;
        var hi = self.pairs.len / record_len;
        var pair_count: f64 = 0;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = self.pairs[mid * record_len ..][0..record_len];
            const ph = u64at(r, 0);
            const pw = u64at(r, 8);
            if (ph == h and pw == w) {
                pair_count = @floatFromInt(u32at(r, 16));
                break;
            }
            if (ph < h or (ph == h and pw < w)) lo = mid + 1 else hi = mid;
        }
        return @max(0, pair_count - self.discount) / count + self.discount * @as(f64, @floatFromInt(u32at(history, 16))) / count * p;
    }
};

test "reject missing header" {
    try std.testing.expectError(error.BadWordModel, Table.parse("MWLM"));
}

// Synthetic corpus: 你 once, 妳 nine times; each sentence ends at EOS.
pub const fixture = [_]u8{ 77, 87, 76, 77, 1, 0, 0, 0, 5, 0, 0, 0, 4, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 232, 63, 211, 237, 100, 102, 27, 62, 30, 26, 9, 0, 0, 0, 9, 0, 0, 0, 1, 0, 0, 0, 94, 83, 145, 103, 27, 232, 98, 30, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 18, 76, 227, 47, 24, 138, 212, 111, 0, 0, 0, 0, 10, 0, 0, 0, 2, 0, 0, 0, 153, 234, 39, 212, 26, 1, 212, 123, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 225, 185, 111, 214, 77, 224, 1, 230, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 211, 237, 100, 102, 27, 62, 30, 26, 153, 234, 39, 212, 26, 1, 212, 123, 9, 0, 0, 0, 94, 83, 145, 103, 27, 232, 98, 30, 153, 234, 39, 212, 26, 1, 212, 123, 1, 0, 0, 0, 18, 76, 227, 47, 24, 138, 212, 111, 211, 237, 100, 102, 27, 62, 30, 26, 9, 0, 0, 0, 18, 76, 227, 47, 24, 138, 212, 111, 94, 83, 145, 103, 27, 232, 98, 30, 1, 0, 0, 0 };

test "conditional distributions normalize and unknown words back off" {
    const table = try Table.parse(&fixture);
    for ([_][]const u8{ "", "你", "妳", "unseen" }) |history| {
        var sum: f64 = 0;
        for ([_][]const u8{ "你", "妳", "</s>", "<unk>" }) |word| sum += table.probability(history, word);
        try std.testing.expectApproxEqAbs(@as(f64, 1), sum, 1e-12);
    }
    try std.testing.expect(table.probability("", "妳") > table.probability("", "你"));
    try std.testing.expectEqual(table.probability("unseen", "<unk>"), table.probability("unseen", "absent"));
    var bad = fixture;
    @memset(bad[24..32], 0);
    try std.testing.expectError(error.BadWordModel, Table.parse(&bad));
    try std.testing.expectError(error.BadWordModel, Table.parse(fixture[0 .. fixture.len - 1]));
}
