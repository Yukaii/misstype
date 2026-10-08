//! Zhuyin keyboard tables (port of ZhuyinKeyboard / Syllable in
//! Sources/MisstypeCore/Keyboard.swift). Keys are US-ANSI unshifted labels,
//! one byte each.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Symbol keys in label order (Swift iterates `symbols.keys` only where the
/// order cannot change the result).
pub const symbol_keys = "1qaz2wsxedcrfvtgbyhnujm8ik,9ol.0p;/-5";

/// Bopomofo symbol typed by `key`, or null for non-symbol keys.
pub fn symbol(key: u8) ?[]const u8 {
    return switch (key) {
        '1' => "ㄅ",
        'q' => "ㄆ",
        'a' => "ㄇ",
        'z' => "ㄈ",
        '2' => "ㄉ",
        'w' => "ㄊ",
        's' => "ㄋ",
        'x' => "ㄌ",
        'e' => "ㄍ",
        'd' => "ㄎ",
        'c' => "ㄏ",
        'r' => "ㄐ",
        'f' => "ㄑ",
        'v' => "ㄒ",
        '5' => "ㄓ",
        't' => "ㄔ",
        'g' => "ㄕ",
        'b' => "ㄖ",
        'y' => "ㄗ",
        'h' => "ㄘ",
        'n' => "ㄙ",
        'u' => "ㄧ",
        'j' => "ㄨ",
        'm' => "ㄩ",
        '8' => "ㄚ",
        'i' => "ㄛ",
        'k' => "ㄜ",
        ',' => "ㄝ",
        '9' => "ㄞ",
        'o' => "ㄟ",
        'l' => "ㄠ",
        '.' => "ㄡ",
        '0' => "ㄢ",
        'p' => "ㄣ",
        ';' => "ㄤ",
        '/' => "ㄥ",
        '-' => "ㄦ",
        else => null,
    };
}

pub fn isSymbol(key: u8) bool {
    return symbol(key) != null;
}

/// Key that types `text` (a Bopomofo symbol), or null.
pub fn keyForSymbol(text: []const u8) ?u8 {
    for (symbol_keys) |key| {
        if (std.mem.eql(u8, symbol(key).?, text)) return key;
    }
    return null;
}

/// Tone mark typed by `key` ("" = space, the explicit first tone), or null.
pub fn tone(key: u8) ?[]const u8 {
    return switch (key) {
        '3' => "ˇ",
        '4' => "ˋ",
        '6' => "ˊ",
        '7' => "˙",
        ' ' => "",
        else => null,
    };
}

pub fn isTone(key: u8) bool {
    return tone(key) != null;
}

/// A label string that is one key byte (labels are single ASCII chars).
pub fn single(label: []const u8) ?u8 {
    return if (label.len == 1) label[0] else null;
}

pub const Syllable = struct {
    keys: []const u8,
    /// Tone KEY: null = no tone evidence; ' ' = explicit first tone.
    tone: ?u8,

    /// Symbols of the keys, then the tone mark. Keys without a symbol are
    /// dropped, as in Swift.
    pub fn reading(self: Syllable, buf: []u8) []const u8 {
        var len: usize = 0;
        for (self.keys) |key| if (symbol(key)) |s| {
            if (len + s.len > buf.len) break;
            @memcpy(buf[len..][0..s.len], s);
            len += s.len;
        };
        if (self.tone) |t| if (tone(t)) |s| {
            if (len + s.len <= buf.len) {
                @memcpy(buf[len..][0..s.len], s);
                len += s.len;
            }
        };
        return buf[0..len];
    }

    pub fn readingAlloc(self: Syllable, gpa: Allocator) ![]const u8 {
        var buf: [max_reading_bytes]u8 = undefined;
        return gpa.dupe(u8, self.reading(&buf));
    }

    /// Symbols only (Swift `base`).
    pub fn base(self: Syllable, buf: []u8) []const u8 {
        return (Syllable{ .keys = self.keys, .tone = null }).reading(buf);
    }

    pub fn eql(a: Syllable, b: Syllable) bool {
        return std.mem.eql(u8, a.keys, b.keys) and a.toneMark() == b.toneMark();
    }

    /// Tones compare by mark: '\x00' = none, ' ' = first tone.
    fn toneMark(self: Syllable) u8 {
        return self.tone orelse 0;
    }

    /// Longest reading the decoder ever builds: up to 256 keys may fuse into
    /// one unresolved syllable, 3 UTF-8 bytes per symbol plus a tone.
    pub const max_reading_bytes = 256 * 3 + 2;
};

/// The reading without tone marks (ˊˇˋ˙); `buf` must hold `text.len` bytes.
pub fn withoutTone(text: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        // ˊ U+02CA, ˇ U+02C7, ˋ U+02CB, ˙ U+02D9: all `CB xx` in UTF-8.
        if (i + 1 < text.len and text[i] == 0xCB and
            (text[i + 1] == 0x8A or text[i + 1] == 0x87 or text[i + 1] == 0x8B or text[i + 1] == 0x99))
        {
            i += 2;
            continue;
        }
        buf[len] = text[i];
        len += 1;
        i += 1;
    }
    return buf[0..len];
}

/// Bopomofo symbols confused in real typing but far apart on QWERTY:
/// medials, sibilant pairs, n/l, front/back nasals. Keys, in group order.
pub fn phoneticConfusions(key: u8) []const u8 {
    return switch (key) {
        'u' => "jm",
        'j' => "um",
        'm' => "uj", // ㄧㄨㄩ
        '5' => "y",
        'y' => "5", // ㄓㄗ
        't' => "h",
        'h' => "t", // ㄔㄘ
        'g' => "n",
        'n' => "g", // ㄕㄙ
        's' => "x",
        'x' => "s", // ㄋㄌ
        '0' => ";",
        ';' => "0", // ㄢㄤ
        'p' => "/",
        '/' => "p", // ㄣㄥ
        else => "",
    };
}

/// Zhuyin slot of a key: 0 initial (ㄅ–ㄙ), 1 medial (ㄧㄨㄩ), 2 final
/// (ㄚ–ㄦ); null for non-symbol keys.
pub fn slot(key: u8) ?u2 {
    const s = symbol(key) orelse return null;
    const scalar = std.unicode.utf8Decode(s) catch return null;
    return switch (scalar) {
        0x3105...0x3119 => 0,
        0x3127...0x3129 => 1,
        else => 2,
    };
}

/// The keys in slot order when typed out of it, at most one per slot; null
/// when already in order or not one syllable's worth of keys.
pub fn slotOrdered(keys: []const u8, out: *[3]u8) ?[]const u8 {
    if (keys.len > 3) {
        // Four or more symbol keys always repeat a slot.
        for (keys) |key| if (slot(key) == null) return null;
        return null;
    }
    var slots: [3]u2 = undefined;
    var seen = [_]bool{ false, false, false };
    for (keys, 0..) |key, i| {
        const s = slot(key) orelse return null;
        if (seen[s]) return null;
        seen[s] = true;
        slots[i] = s;
    }
    var sorted = true;
    for (1..keys.len) |i| {
        if (slots[i] < slots[i - 1]) sorted = false;
    }
    if (sorted) return null;
    var n: usize = 0;
    for (0..3) |want| {
        for (keys, 0..) |key, i| if (slots[i] == want) {
            out[n] = key;
            n += 1;
        };
    }
    return out[0..n];
}

/// Symbol keys of one slot, sorted by label.
fn keysBySlot(comptime s: u2) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "";
        var sorted: [symbol_keys.len]u8 = symbol_keys.*;
        std.mem.sort(u8, &sorted, {}, std.sort.asc(u8));
        for (sorted) |key| {
            if (slot(key) == s) out = out ++ [_]u8{key};
        }
        return out;
    }
}

const slot_keys = [3][]const u8{ keysBySlot(0), keysBySlot(1), keysBySlot(2) };

/// One key added in a slot the keys leave empty, at its slot position: the
/// readings a dropped key may have come from. Empty unless the keys are one
/// syllable in slot order. Each completion is `keys.len + 1` bytes.
pub fn slotCompletions(gpa: Allocator, keys: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (keys.len == 0 or keys.len > 3) return out.toOwnedSlice(gpa);
    var slots: [3]u2 = undefined;
    var seen = [_]bool{ false, false, false };
    for (keys, 0..) |key, i| {
        const s = slot(key) orelse return out.toOwnedSlice(gpa);
        if (seen[s]) return out.toOwnedSlice(gpa);
        if (i > 0 and s < slots[i - 1]) return out.toOwnedSlice(gpa);
        seen[s] = true;
        slots[i] = s;
    }
    for (0..3) |missing| {
        if (seen[missing]) continue;
        var position = keys.len;
        for (slots[0..keys.len], 0..) |s, i| if (s > missing) {
            position = i;
            break;
        };
        for (slot_keys[missing]) |key| {
            const completed = try gpa.alloc(u8, keys.len + 1);
            @memcpy(completed[0..position], keys[0..position]);
            completed[position] = key;
            @memcpy(completed[position + 1 ..], keys[position..]);
            try out.append(gpa, completed);
        }
    }
    return out.toOwnedSlice(gpa);
}

const Neighbors = struct { keys: [8]u8 = undefined, len: u8 = 0 };

const neighbor_table: [128]Neighbors = blk: {
    @setEvalBranchQuota(200_000);
    const rows = [_][]const u8{ "1234567890-", "qwertyuiop", "asdfghjkl;", "zxcvbnm,./" };
    const shifts = [_]f64{ 0.0, 0.25, 0.5, 0.75 };
    var x: [128]f64 = undefined;
    var y: [128]f64 = undefined;
    var has: [128]bool = @splat(false);
    for (rows, 0..) |row, r| {
        for (row, 0..) |char, c| {
            x[char] = @as(f64, @floatFromInt(c)) + shifts[r];
            y[char] = @floatFromInt(r);
            has[char] = true;
        }
    }
    var table: [128]Neighbors = @splat(.{});
    for (0..128) |key| {
        if (!has[key]) continue;
        var found: [16]struct { label: u8, distance: f64 } = undefined;
        var n = 0;
        for (0..128) |other| {
            if (!has[other] or other == key or symbol(other) == null) continue;
            const dx = x[key] - x[other];
            const dy = y[key] - y[other];
            const distance = @sqrt(dx * dx + dy * dy);
            if (distance < 1.3) {
                found[n] = .{ .label = other, .distance = distance };
                n += 1;
            }
        }
        // Sort by distance, then label.
        for (0..n) |i| {
            for (i + 1..n) |j| {
                const a = found[i];
                const b = found[j];
                if (b.distance < a.distance or (b.distance == a.distance and b.label < a.label)) {
                    found[i] = b;
                    found[j] = a;
                }
            }
        }
        for (0..n) |i| table[key].keys[i] = found[i].label;
        table[key].len = n;
    }
    break :blk table;
};

/// QWERTY neighbors of a key that type Zhuyin symbols, nearest first.
pub fn neighbors(key: u8) []const u8 {
    if (key >= 128) return "";
    const entry = &neighbor_table[key];
    return entry.keys[0..entry.len];
}

test "reading and toneless form" {
    var buf: [Syllable.max_reading_bytes]u8 = undefined;
    const ni = Syllable{ .keys = "su", .tone = '3' };
    try std.testing.expectEqualStrings("ㄋㄧˇ", ni.reading(&buf));
    const first = Syllable{ .keys = "g/", .tone = ' ' };
    try std.testing.expectEqualStrings("ㄕㄥ", first.reading(&buf));
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ㄋㄧ", withoutTone("ㄋㄧˇ", &out));
}

test "slots and neighbors" {
    var buf: [3]u8 = undefined;
    try std.testing.expectEqualStrings("1u0", slotOrdered("u10", &buf).?);
    try std.testing.expect(slotOrdered("1u0", &buf) == null);
    try std.testing.expectEqualStrings("w", neighbors('q')[0..1]);
    const completions = try slotCompletions(std.testing.allocator, "ej");
    defer {
        for (completions) |c| std.testing.allocator.free(c);
        std.testing.allocator.free(completions);
    }
    try std.testing.expectEqual(@as(usize, 13), completions.len); // finals ㄚ..ㄦ
}
