//! Homophone word-bigram table (experiment; docs/project-outline.md, finding
//! of 2026-10-12). A read-only, sorted array of 8-byte entries searched in
//! place: no parsing, no allocation, resident size is the file size.
//!
//! File: "MSHB", u32 version (1), u32 count, u32 units-per-nat, then `count`
//! little-endian u64 entries sorted ascending. Entry = key40 << 8 | value,
//! value an i8 in 1/units nats, key40 the top 40 bits of FNV-1a-64 over
//! `previous 0xFF current`. `tools/homophone_bigram.py export` writes it.

const std = @import("std");

pub const magic = "MSHB";
pub const version: u32 = 1;
const header_len = 16;

pub const Table = struct {
    entries: []const u8,
    count: usize,
    /// Value units per nat (4 means 0.25-nat steps).
    units: f64,

    pub const empty: Table = .{ .entries = &.{}, .count = 0, .units = 1 };

    /// `bytes` must outlive the table. Anything malformed is rejected so a
    /// truncated download degrades to "no table", not to garbage bonuses.
    pub fn parse(bytes: []const u8) !Table {
        if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..4], magic)) return error.BadHomophoneTable;
        if (std.mem.readInt(u32, bytes[4..8], .little) != version) return error.BadHomophoneTable;
        const count: usize = std.mem.readInt(u32, bytes[8..12], .little);
        const units = std.mem.readInt(u32, bytes[12..16], .little);
        if (units == 0 or bytes.len != header_len + count * 8) return error.BadHomophoneTable;
        return .{ .entries = bytes[header_len..], .count = count, .units = @floatFromInt(units) };
    }

    pub fn key(previous: []const u8, current: []const u8) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for (previous) |b| h = (h ^ b) *% 0x100000001b3;
        h = (h ^ 0xff) *% 0x100000001b3;
        for (current) |b| h = (h ^ b) *% 0x100000001b3;
        return h >> 24;
    }

    /// Bonus in nats for `previous` followed by `current`; 0 when unlisted.
    pub fn bonus(self: Table, previous: []const u8, current: []const u8) f64 {
        if (self.count == 0) return 0;
        const want = key(previous, current);
        var lo: usize = 0;
        var hi: usize = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = std.mem.readInt(u64, self.entries[mid * 8 ..][0..8], .little);
            const have = entry >> 8;
            if (have == want) {
                const value: i8 = @bitCast(@as(u8, @truncate(entry)));
                return @as(f64, @floatFromInt(value)) / self.units;
            }
            if (have < want) lo = mid + 1 else hi = mid;
        }
        return 0;
    }
};

test "table round trip and rejection" {
    const a = std.testing.allocator;
    const pairs = [_]struct { []const u8, []const u8, i8 }{
        .{ "一串", "字", 8 },
        .{ "各自", "的", -3 },
    };
    var entries: [2]u64 = undefined;
    for (pairs, 0..) |p, i| entries[i] = (Table.key(p[0], p[1]) << 8) | @as(u64, @as(u8, @bitCast(p[2])));
    std.mem.sort(u64, &entries, {}, std.sort.asc(u64));
    var bytes = try a.alloc(u8, header_len + entries.len * 8);
    defer a.free(bytes);
    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u32, bytes[4..8], version, .little);
    std.mem.writeInt(u32, bytes[8..12], entries.len, .little);
    std.mem.writeInt(u32, bytes[12..16], 4, .little);
    for (entries, 0..) |e, i| std.mem.writeInt(u64, bytes[header_len + i * 8 ..][0..8], e, .little);

    const table = try Table.parse(bytes);
    try std.testing.expectEqual(@as(f64, 2.0), table.bonus("一串", "字"));
    try std.testing.expectEqual(@as(f64, -0.75), table.bonus("各自", "的"));
    try std.testing.expectEqual(@as(f64, 0), table.bonus("一串", "自"));
    try std.testing.expectError(error.BadHomophoneTable, Table.parse(bytes[0 .. bytes.len - 1]));
    try std.testing.expectEqual(@as(f64, 0), Table.empty.bonus("一串", "字"));
}
