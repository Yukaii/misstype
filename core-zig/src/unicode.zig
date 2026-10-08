//! The slice of Swift `String` semantics the core relies on, over UTF-8:
//! UTF-16 offsets (the platform caret contract), Swift's lossy UTF-16
//! slicing, `Character` counts, and `isWhitespace`.
//!
//! Extended grapheme boundaries and canonical equivalence use pinned utf8proc.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// UTF-16 code units of valid UTF-8 text: one per scalar, two above U+FFFF.
pub fn utf16Len(text: []const u8) u32 {
    var units: u32 = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) units += 1; // lead byte
        if (byte >= 0xF0) units += 1; // 4-byte sequence: surrogate pair
    }
    return units;
}

/// Byte offset of UTF-16 offset `units` (clamped to the end). An offset
/// inside a surrogate pair rounds down to the scalar's start.
pub fn byteOffset(text: []const u8, units: usize) usize {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const width = seqLen(text[i]);
        const scalar_units: usize = if (width == 4) 2 else 1;
        if (seen + scalar_units > units) return i;
        seen += scalar_units;
        i += width;
    }
    return text.len;
}

/// Swift `String(decoding: Array(text.utf16)[start..<end], as: UTF16.self)`:
/// a range that cuts a surrogate pair yields U+FFFD for the lone half.
/// Allocates only when the range cuts a pair.
pub fn utf16Slice(gpa: Allocator, text: []const u8, start: usize, end: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var unit: usize = 0;
    var i: usize = 0;
    var from: ?usize = null;
    var to: usize = text.len;
    var lossy = false;
    while (i < text.len) {
        const width = seqLen(text[i]);
        const units: usize = if (width == 4) 2 else 1;
        // This scalar covers units [unit, unit + units).
        const lo = @max(unit, start);
        const hi = @min(unit + units, end);
        if (lo < hi) {
            if (hi - lo < units) lossy = true;
            if (from == null) from = i;
        } else if (from != null and unit >= end) {
            to = i;
            break;
        }
        unit += units;
        i += width;
    }
    const first = from orelse return "";
    if (!lossy) return text[first..to];
    // Rare: rebuild with replacement characters.
    unit = 0;
    i = 0;
    while (i < text.len) {
        const width = seqLen(text[i]);
        const units: usize = if (width == 4) 2 else 1;
        const lo = @max(unit, start);
        const hi = @min(unit + units, end);
        if (lo < hi) {
            // A lone surrogate half decodes to U+FFFD, once per half.
            if (hi - lo == units) {
                try out.appendSlice(gpa, text[i .. i + width]);
            } else {
                try out.appendSlice(gpa, "\u{FFFD}");
            }
        }
        unit += units;
        i += width;
    }
    return out.toOwnedSlice(gpa);
}

/// UTF-16 unit at `index` (Swift `text.utf16[index]`), or null past the end.
pub fn utf16Unit(text: []const u8, index: usize) ?u16 {
    var unit: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const width = seqLen(text[i]);
        const scalar = std.unicode.utf8Decode(text[i .. i + width]) catch 0xFFFD;
        if (width == 4) {
            const v = scalar - 0x10000;
            if (unit == index) return @intCast(0xD800 + (v >> 10));
            if (unit + 1 == index) return @intCast(0xDC00 + (v & 0x3FF));
            unit += 2;
        } else {
            if (unit == index) return @intCast(scalar);
            unit += 1;
        }
        i += width;
    }
    return null;
}

pub fn seqLen(lead: u8) usize {
    return std.unicode.utf8ByteSequenceLength(lead) catch 1;
}

/// Scalars of `text` (ASCII/UTF-8 iterator helper).
pub fn scalars(text: []const u8) std.unicode.Utf8Iterator {
    return .{ .bytes = text, .i = 0 };
}

/// Extended grapheme clusters, using the pinned, statically linked utf8proc.
/// This covers UAX #29 (including Hangul, Indic conjuncts, emoji and controls).
extern "c" fn utf8proc_grapheme_break_stateful(i32, i32, *i32) bool;

pub fn characterCount(text: []const u8) usize {
    var count: usize = 0;
    var it = scalars(text);
    var previous: ?u21 = null;
    var state: i32 = 0;
    while (it.nextCodepoint()) |cp| {
        if (previous == null or utf8proc_grapheme_break_stateful(previous.?, cp, &state)) count += 1;
        previous = cp;
    }
    return count;
}

pub fn characters(gpa: Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = scalars(text);
    var start: usize = 0;
    var previous: ?u21 = null;
    var state: i32 = 0;
    while (true) {
        const at = it.i;
        const cp = it.nextCodepoint() orelse break;
        if (previous) |last| {
            if (utf8proc_grapheme_break_stateful(last, cp, &state)) {
                try out.append(gpa, text[start..at]);
                start = at;
            }
        }
        previous = cp;
    }
    if (previous != null) try out.append(gpa, text[start..]);
    return out.toOwnedSlice(gpa);
}

/// Unicode White_Space (Swift `Character.isWhitespace`).
pub fn isWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// `text` without trailing whitespace characters (Swift: `while
/// text.last?.isWhitespace == true { removeLast() }`).
pub fn trimTrailingWhitespace(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0) {
        var start = end - 1;
        while (start > 0 and text[start] & 0xC0 == 0x80) start -= 1;
        const cp = std.unicode.utf8Decode(text[start..end]) catch return text[0..end];
        if (!isWhitespace(cp)) break;
        end = start;
    }
    return text[0..end];
}

pub fn lessThan(a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const testing = std.testing;

test "utf16 helpers" {
    try testing.expectEqual(@as(u32, 4), utf16Len("a你𠀀"));
    try testing.expectEqual(@as(usize, 4), byteOffset("a你𠀀", 2));
    try testing.expectEqualStrings("你", try utf16Slice(testing.allocator, "a你b", 1, 2));
    const lossy = try utf16Slice(testing.allocator, "𠀀x", 0, 1);
    defer testing.allocator.free(lossy);
    try testing.expectEqualStrings("\u{FFFD}", lossy);
    try testing.expectEqual(@as(?u16, 0xD840), utf16Unit("𠀀", 0));
    try testing.expectEqual(@as(?u16, 0x4F60), utf16Unit("a你", 1));
}

test "characters" {
    try testing.expectEqual(@as(usize, 2), characterCount("你好"));
    try testing.expectEqual(@as(usize, 1), characterCount("e\u{301}"));
    try testing.expectEqualStrings("你", trimTrailingWhitespace("你 \u{3000}"));
}

test "extended grapheme boundaries match control, Hangul, Indic and emoji fixtures" {
    for ([_][]const u8{ "\r\n", "각", "क्ष", "का", "\u{0600}A", "🇹🇼", "👨‍👩‍👧‍👦", "👍🏽" }) |text| {
        try testing.expectEqual(@as(usize, 1), characterCount(text));
        const chars = try characters(testing.allocator, text);
        defer testing.allocator.free(chars);
        try testing.expectEqual(@as(usize, 1), chars.len);
        try testing.expectEqualStrings(text, chars[0]);
    }
    try testing.expectEqual(@as(usize, 2), characterCount("a\u{200d}b"));
}

extern "c" fn utf8proc_map([*]const u8, isize, *?[*]u8, c_int) isize;
/// Swift String equality without changing either spelling's raw evidence.
pub fn equal(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    // The shipping lexicon is overwhelmingly ASCII and unified CJK; these
    // scalars have no canonical decomposition and cannot reorder.
    if (canonicalStable(a) and canonicalStable(b)) return false;
    var left: ?[*]u8 = null;
    var right: ?[*]u8 = null;
    const options = 2 | 8; // UTF8PROC_STABLE | UTF8PROC_COMPOSE
    const left_len = utf8proc_map(a.ptr, @intCast(a.len), &left, options);
    defer if (left) |p| std.c.free(p);
    const right_len = utf8proc_map(b.ptr, @intCast(b.len), &right, options);
    defer if (right) |p| std.c.free(p);
    return left_len >= 0 and left_len == right_len and std.mem.eql(u8, left.?[0..@intCast(left_len)], right.?[0..@intCast(right_len)]);
}
test "canonical equality preserves original spelling" {
    try std.testing.expect(equal("é", "e\u{301}"));
    try std.testing.expect(equal("각", "각"));
    try std.testing.expect(!equal("你", "尼"));
}

fn canonicalStable(text: []const u8) bool {
    var it = scalars(text);
    while (it.nextCodepoint()) |cp| {
        if (cp < 128 or (cp >= 0x3400 and cp <= 0x4dbf) or (cp >= 0x4e00 and cp <= 0x9fff) or (cp >= 0x20000 and cp <= 0x323af and !(cp >= 0x2f800 and cp <= 0x2fa1f))) continue;
        return false;
    }
    return true;
}

/// Canonical-equivalence hash for learned text, preserving insertion spelling.
pub const StringContext = struct {
    pub fn hash(_: @This(), text: []const u8) u32 {
        if (canonicalStable(text)) return @truncate(std.hash.Wyhash.hash(0, text));
        var normalized: ?[*]u8 = null;
        const len = utf8proc_map(text.ptr, @intCast(text.len), &normalized, 2 | 8);
        defer if (normalized) |p| std.c.free(p);
        if (len < 0) return @truncate(std.hash.Wyhash.hash(0, text));
        return @truncate(std.hash.Wyhash.hash(0, normalized.?[0..@intCast(len)]));
    }
    pub fn eql(_: @This(), a: []const u8, b: []const u8, _: usize) bool {
        return equal(a, b);
    }
};
