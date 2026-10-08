//! The slice of Swift `String` semantics the core relies on, over UTF-8:
//! UTF-16 offsets (the platform caret contract), Swift's lossy UTF-16
//! slicing, `Character` counts, and `isWhitespace`.
//!
//! Text is compared as UTF-8 bytes. Swift compares canonical equivalents
//! as equal; the two agree on NFC text, which is all the lexicon holds.

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

/// Approximate `String.count` (extended grapheme clusters): scalars that
/// do not extend the previous one. Covers combining marks, variation
/// selectors, ZWJ sequences, emoji modifiers and flag pairs; CJK text, the
/// only text the counts gate, is one scalar per character either way.
pub fn characterCount(text: []const u8) usize {
    var count: usize = 0;
    var it = scalars(text);
    var after_zwj = false;
    var regional_open = false;
    while (it.nextCodepoint()) |cp| {
        if (count > 0 and (after_zwj or isExtend(cp))) {
            after_zwj = cp == 0x200D;
            continue;
        }
        if (cp >= 0x1F1E6 and cp <= 0x1F1FF) {
            if (regional_open) {
                regional_open = false;
                continue;
            }
            regional_open = true;
        } else regional_open = false;
        after_zwj = false;
        count += 1;
    }
    return count;
}

/// The characters of `text` (see `characterCount`), as byte slices.
pub fn characters(gpa: Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = scalars(text);
    var start: usize = 0;
    var after_zwj = false;
    var regional_open = false;
    var first = true;
    while (true) {
        const at = it.i;
        const cp = it.nextCodepoint() orelse break;
        if (!first and (after_zwj or isExtend(cp))) {
            after_zwj = cp == 0x200D;
            continue;
        }
        if (cp >= 0x1F1E6 and cp <= 0x1F1FF) {
            if (regional_open) {
                regional_open = false;
                continue;
            }
            regional_open = true;
        } else regional_open = false;
        after_zwj = false;
        if (!first) try out.append(gpa, text[start..at]);
        start = at;
        first = false;
    }
    if (!first) try out.append(gpa, text[start..]);
    return out.toOwnedSlice(gpa);
}

fn isExtend(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xFE20 and cp <= 0xFE2F) or
        (cp >= 0x1F3FB and cp <= 0x1F3FF) or (cp >= 0xE0100 and cp <= 0xE01EF) or
        (cp >= 0xE0020 and cp <= 0xE007F) or cp == 0x200D or cp == 0x3099 or cp == 0x309A;
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
