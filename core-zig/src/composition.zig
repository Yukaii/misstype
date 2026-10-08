//! The raw key buffer of one composition (port of `Composition` in
//! Sources/MisstypeCore/Keyboard.swift). Keys are the evidence: symbols and
//! tones by label, Latin letters typed as text, and CJK punctuation.

const std = @import("std");
const keyboard = @import("keyboard.zig");
const punctuation = @import("punctuation.zig");
const Syllable = keyboard.Syllable;
const Allocator = std.mem.Allocator;

/// One raw key. Swift stores strings: a label ("s", "3", " "), "L:x" for a
/// Latin letter, or a punctuation literal.
pub const Key = union(enum) {
    /// Zhuyin symbol or tone key, or ' ' (Space).
    key: u8,
    /// Latin text typed inside the composition (one ASCII char).
    latin: u8,
    /// CJK punctuation (index into `punctuation.literals`).
    literal: punctuation.Literal,

    pub fn eql(a: Key, b: Key) bool {
        return std.meta.eql(a, b);
    }

    pub fn isSymbol(self: Key) bool {
        return self == .key and keyboard.isSymbol(self.key);
    }

    pub fn isTone(self: Key) bool {
        return self == .key and keyboard.isTone(self.key);
    }

    pub fn isSpace(self: Key) bool {
        return self == .key and self.key == ' ';
    }

    pub fn literalText(self: Key) ?[]const u8 {
        return if (self == .literal) punctuation.literals[self.literal] else null;
    }

    /// A Latin letter or digit (not Latin punctuation): part of a word.
    pub fn isLatinWord(self: Key) bool {
        return self == .latin and std.ascii.isAlphanumeric(self.latin);
    }

    /// The text this key contributes to `rawPhonetic`.
    pub fn phonetic(self: Key, buf: *[1]u8) []const u8 {
        return switch (self) {
            .latin => |c| blk: {
                buf[0] = c;
                break :blk buf;
            },
            .literal => |i| punctuation.literals[i],
            .key => |k| keyboard.symbol(k) orelse keyboard.tone(k) orelse blk: {
                buf[0] = k;
                break :blk buf;
            },
        };
    }
};

/// ASCII punctuation that is plain text inside a Latin run although the key
/// is a Zhuyin letter (ㄡㄝㄤㄥㄦ).
pub fn isLatinPunctuation(c: u8) bool {
    return switch (c) {
        '.', ',', ';', '/', '-' => true,
        else => false,
    };
}

pub const Segment = union(enum) {
    syllable: Syllable,
    /// A punctuation literal or a separator space.
    punct: []const u8,
    latin: []const u8,
};

pub const Parsed = struct {
    complete: []Syllable,
    pending: []const u8,
};

pub const max_keys = 256;

pub const Composition = struct {
    raw_keys: std.ArrayList(Key) = .empty,
    /// Insertion point (raw key index) for `atCaret` edits; null = the end.
    caret: ?usize = null,

    pub fn deinit(self: *Composition, gpa: Allocator) void {
        self.raw_keys.deinit(gpa);
    }

    pub fn keys(self: *const Composition) []const Key {
        return self.raw_keys.items;
    }

    pub fn isEmpty(self: *const Composition) bool {
        return self.raw_keys.items.len == 0;
    }

    fn fixCaret(self: *Composition) void {
        if (self.caret) |at| if (at >= self.raw_keys.items.len) {
            self.caret = null;
        };
    }

    /// Put the insertion point before raw key `index` (null or past the
    /// last key = the end).
    pub fn moveCaret(self: *Composition, index: ?usize) void {
        const at = index orelse {
            self.caret = null;
            return;
        };
        self.caret = if (at < self.raw_keys.items.len) at else null;
    }

    /// The keys before the caret.
    pub fn beforeCaret(self: *const Composition) []const Key {
        const at = self.caret orelse return self.raw_keys.items;
        return self.raw_keys.items[0..at];
    }

    /// Caret edits run on the keys before the caret: `splitAtCaret` takes
    /// the keys after it off (caret cleared), the edit runs as if at the
    /// end, and `joinTail` puts them back with the caret before them.
    pub fn splitAtCaret(self: *Composition, gpa: Allocator) !?[]Key {
        const at = self.caret orelse return null;
        const tail = try gpa.dupe(Key, self.raw_keys.items[at..]);
        self.raw_keys.shrinkRetainingCapacity(at);
        self.caret = null;
        return tail;
    }

    pub fn joinTail(self: *Composition, gpa: Allocator, tail: ?[]Key) !void {
        const rest = tail orelse return;
        defer gpa.free(rest);
        const end = self.raw_keys.items.len;
        try self.raw_keys.appendSlice(gpa, rest);
        self.caret = if (rest.len == 0) null else end;
    }

    pub fn rawPhonetic(self: *const Composition, gpa: Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.raw_keys.items) |key| {
            var buf: [1]u8 = undefined;
            try out.appendSlice(gpa, key.phonetic(&buf));
        }
        return out.toOwnedSlice(gpa);
    }

    /// Complete syllables (terminated by a tone, punctuation, Latin or a
    /// mid-composition caret) and the trailing unfinished symbol keys.
    pub fn parsed(self: *const Composition, gpa: Allocator) !Parsed {
        var complete: std.ArrayList(Syllable) = .empty;
        var pending: std.ArrayList(u8) = .empty;
        for (self.raw_keys.items, 0..) |key, index| {
            if (self.caret == index and pending.items.len > 0) {
                try complete.append(gpa, .{ .keys = try pending.toOwnedSlice(gpa), .tone = null });
            }
            if (key == .latin or key == .literal) {
                if (pending.items.len > 0) {
                    try complete.append(gpa, .{ .keys = try pending.toOwnedSlice(gpa), .tone = null });
                }
                continue;
            }
            if (keyboard.isTone(key.key)) {
                if (pending.items.len > 0) {
                    try complete.append(gpa, .{ .keys = try pending.toOwnedSlice(gpa), .tone = key.key });
                }
            } else {
                try pending.append(gpa, key.key);
            }
        }
        return .{ .complete = try complete.toOwnedSlice(gpa), .pending = try pending.toOwnedSlice(gpa) };
    }

    pub fn pendingKeys(self: *const Composition, gpa: Allocator) ![]const u8 {
        return (try self.parsed(gpa)).pending;
    }

    /// Ordered terminated runs with punctuation and Latin positions kept.
    /// Trailing unfinished symbol keys are excluded (see `parsed`).
    pub fn segments(self: *const Composition, gpa: Allocator) ![]Segment {
        var out: std.ArrayList(Segment) = .empty;
        var pending: std.ArrayList(u8) = .empty;
        var latin: std.ArrayList(u8) = .empty;
        const S = struct {
            fn flushPending(o: *std.ArrayList(Segment), p: *std.ArrayList(u8), a: Allocator) !void {
                if (p.items.len > 0) {
                    try o.append(a, .{ .syllable = .{ .keys = try p.toOwnedSlice(a), .tone = null } });
                }
            }
            fn flushLatin(o: *std.ArrayList(Segment), l: *std.ArrayList(u8), a: Allocator) !void {
                if (l.items.len > 0) try o.append(a, .{ .latin = try l.toOwnedSlice(a) });
            }
        };
        for (self.raw_keys.items, 0..) |key, index| {
            if (self.caret == index) try S.flushPending(&out, &pending, gpa);
            switch (key) {
                .latin => |c| {
                    try S.flushPending(&out, &pending, gpa);
                    try latin.append(gpa, c);
                },
                .literal => |i| {
                    try S.flushPending(&out, &pending, gpa);
                    try S.flushLatin(&out, &latin, gpa);
                    try out.append(gpa, .{ .punct = punctuation.literals[i] });
                },
                .key => |k| {
                    if (k == ' ') {
                        try S.flushLatin(&out, &latin, gpa);
                        if (pending.items.len > 0) {
                            try out.append(gpa, .{ .syllable = .{ .keys = try pending.toOwnedSlice(gpa), .tone = ' ' } });
                        } else {
                            try out.append(gpa, .{ .punct = " " });
                        }
                    } else if (keyboard.isTone(k)) {
                        if (pending.items.len > 0) {
                            try S.flushLatin(&out, &latin, gpa);
                            try out.append(gpa, .{ .syllable = .{ .keys = try pending.toOwnedSlice(gpa), .tone = k } });
                        }
                    } else {
                        try S.flushLatin(&out, &latin, gpa);
                        try pending.append(gpa, k);
                    }
                },
            }
        }
        // Trailing Latin is emitted (commit reads segments + pending).
        try S.flushLatin(&out, &latin, gpa);
        pending.deinit(gpa);
        return out.toOwnedSlice(gpa);
    }

    pub fn append(self: *Composition, gpa: Allocator, key: u8) !bool {
        if (self.raw_keys.items.len >= max_keys or (!keyboard.isSymbol(key) and !keyboard.isTone(key))) return false;
        if (keyboard.isTone(key) and !self.pendingNonEmpty()) return false;
        try self.raw_keys.append(gpa, .{ .key = key });
        return true;
    }

    /// `parsed.pending` is non-empty (computed without allocating).
    pub fn pendingNonEmpty(self: *const Composition) bool {
        var pending: usize = 0;
        for (self.raw_keys.items, 0..) |key, index| {
            if (self.caret == index) pending = 0;
            switch (key) {
                .latin, .literal => pending = 0,
                .key => |k| {
                    if (keyboard.isTone(k)) pending = 0 else pending += 1;
                },
            }
        }
        return pending > 0;
    }

    pub fn appendLiteral(self: *Composition, gpa: Allocator, text: []const u8) !bool {
        const index = punctuation.literalIndex(text) orelse return false;
        if (self.raw_keys.items.len >= max_keys) return false;
        try self.raw_keys.append(gpa, .{ .literal = index });
        return true;
    }

    /// Swap the trailing punctuation literal (symbol menu).
    pub fn replaceLastLiteral(self: *Composition, gpa: Allocator, text: []const u8) !bool {
        _ = gpa;
        const items = self.raw_keys.items;
        if (items.len == 0 or items[items.len - 1] != .literal) return false;
        const index = punctuation.literalIndex(text) orelse return false;
        items[items.len - 1] = .{ .literal = index };
        return true;
    }

    pub fn appendSpace(self: *Composition, gpa: Allocator) !bool {
        if (self.raw_keys.items.len >= max_keys) return false;
        try self.raw_keys.append(gpa, .{ .key = ' ' });
        return true;
    }

    pub fn backspace(self: *Composition) void {
        _ = self.raw_keys.pop();
        self.fixCaret();
    }

    /// Append one Latin character (ASCII letter or digit, or Latin
    /// punctuation) into the running composition.
    pub fn appendLatin(self: *Composition, gpa: Allocator, text: []const u8) !bool {
        if (self.raw_keys.items.len >= max_keys or text.len != 1) return false;
        const c = text[0];
        if (c >= 0x80 or !(std.ascii.isAlphanumeric(c) or isLatinPunctuation(c))) return false;
        try self.raw_keys.append(gpa, .{ .latin = c });
        return true;
    }

    /// Re-read the trailing Zhuyin keys (after the last Latin letter or
    /// punctuation) as the Latin letters they physically were. Space stays
    /// the separator.
    pub fn convertTailToLatin(self: *Composition) bool {
        const items = self.raw_keys.items;
        var start = items.len;
        while (start > 0) {
            const key = items[start - 1];
            if (key == .latin or key == .literal) break;
            start -= 1;
        }
        if (start >= items.len) return false;
        for (items[start..]) |*key| {
            if (!key.isSpace()) {
                const physical_key = key.key;
                key.* = .{ .latin = physical_key };
            }
        }
        return true;
    }

    /// Erase the last user-perceived unit: a whole syllable when nothing is
    /// pending, else the last raw key.
    pub fn erase(self: *Composition) void {
        if (!self.pendingNonEmpty()) self.deleteLastSyllable() else self.backspace();
    }

    /// Symbol keys of the syllable body closed by a trailing tone key.
    pub fn trailingBodyLen(self: *const Composition) usize {
        const items = self.raw_keys.items;
        if (items.len == 0 or !items[items.len - 1].isTone()) return 0;
        var n: usize = 0;
        var i = items.len - 1;
        while (i > 0) {
            i -= 1;
            if (!items[i].isSymbol()) break;
            n += 1;
        }
        return n;
    }

    /// The symbol keys of the trailing body (see `trailingBodyLen`).
    pub fn trailingBody(self: *const Composition, buf: []u8) []const u8 {
        const n = self.trailingBodyLen();
        const items = self.raw_keys.items;
        const start = items.len - 1 - n;
        for (items[start .. items.len - 1], 0..) |key, i| buf[i] = key.key;
        return buf[0..n];
    }

    /// Erase a trailing tone and only the last `count` symbol keys of its
    /// body; the rest stays as pending keys.
    pub fn eraseTailSyllable(self: *Composition, count: usize) void {
        if (count == 0 or count >= self.trailingBodyLen()) return;
        self.raw_keys.shrinkRetainingCapacity(self.raw_keys.items.len - (count + 1));
        self.fixCaret();
    }

    /// Replace a trailing tone terminator with a new tone key.
    pub fn retoneLast(self: *Composition, gpa: Allocator, tone_key: u8) !bool {
        _ = gpa;
        const items = self.raw_keys.items;
        if (!keyboard.isTone(tone_key) or items.len == 0 or self.pendingNonEmpty() or
            !items[items.len - 1].isTone()) return false;
        items[items.len - 1] = .{ .key = tone_key };
        return true;
    }

    /// Trailing Latin run verbatim ("" when the tail holds none).
    pub fn trailingLatin(keys_: []const Key, buf: []u8) []const u8 {
        var i = keys_.len;
        while (i > 0 and keys_[i - 1] == .latin) i -= 1;
        for (keys_[i..], 0..) |key, j| buf[j] = key.latin;
        return buf[0 .. keys_.len - i];
    }

    pub fn hasTrailingLatin(keys_: []const Key) bool {
        return keys_.len > 0 and keys_[keys_.len - 1] == .latin;
    }

    /// Delete back to the previous syllable boundary.
    pub fn deleteLastSyllable(self: *Composition) void {
        const list = &self.raw_keys;
        if (list.items.len == 0) return;
        const last = list.items[list.items.len - 1];
        if (last == .literal or last == .latin) {
            _ = list.pop();
            self.fixCaret();
            return;
        }
        if (last.isTone()) _ = list.pop();
        while (list.items.len > 0) {
            const key = list.items[list.items.len - 1];
            if (key.isTone() or key == .literal or key == .latin) break;
            _ = list.pop();
        }
        self.fixCaret();
    }

    /// Drop raw keys [start, end); the caret stays before whatever followed.
    pub fn removeKeys(self: *Composition, start_: usize, end_: usize) void {
        const len = self.raw_keys.items.len;
        const start = @min(start_, len);
        const end = @min(end_, len);
        if (start >= end) return;
        const at = self.caret;
        self.raw_keys.replaceRangeAssumeCapacity(start, end - start, &.{});
        self.fixCaret();
        if (at) |caret| {
            const count = end - start;
            self.moveCaret(if (caret > start) @max(start, caret - count) else caret);
        }
    }

    /// Option+Backspace: a Latin word with the spaces after it, else the
    /// last syllable.
    pub fn deleteLastWord(self: *Composition) void {
        const items = self.raw_keys.items;
        var start = items.len;
        while (start > 0 and items[start - 1].isSpace()) start -= 1;
        if (start == 0 or !items[start - 1].isLatinWord()) {
            self.deleteLastSyllable();
            return;
        }
        while (start > 0 and items[start - 1].isLatinWord()) start -= 1;
        self.raw_keys.shrinkRetainingCapacity(start);
        self.fixCaret();
    }

    /// Drop the first `count` raw keys (a head that was committed).
    pub fn dropHead(self: *Composition, count: usize) void {
        const n = @min(count, self.raw_keys.items.len);
        self.raw_keys.replaceRangeAssumeCapacity(0, n, &.{});
        self.fixCaret();
    }

    pub fn clear(self: *Composition) void {
        self.raw_keys.clearRetainingCapacity();
        self.caret = null;
    }

    /// Trailing unfinished symbols for preview (stops at tones,
    /// punctuation and Latin).
    pub fn pendingText(self: *const Composition, gpa: Allocator) ![]const u8 {
        const items = self.raw_keys.items;
        var i = items.len;
        while (i > 0 and items[i - 1].isSymbol()) i -= 1;
        var out: std.ArrayList(u8) = .empty;
        for (items[i..]) |key| try out.appendSlice(gpa, keyboard.symbol(key.key).?);
        return out.toOwnedSlice(gpa);
    }
};

const testing = std.testing;

fn typed(gpa: Allocator, text: []const u8) !Composition {
    var c: Composition = .{};
    for (text) |k| {
        if (k == ' ') {
            _ = try c.appendSpace(gpa);
        } else {
            _ = try c.append(gpa, k);
        }
    }
    return c;
}

test "convert tail to Latin preserves physical keys and separators" {
    var composition: Composition = .{};
    defer composition.deinit(std.testing.allocator);
    try composition.raw_keys.appendSlice(std.testing.allocator, &.{ .{ .latin = 'A' }, .{ .key = 's' }, .{ .key = 'u' }, .{ .key = '3' }, .{ .key = ' ' } });
    try std.testing.expect(composition.convertTailToLatin());
    try std.testing.expectEqual(Key{ .latin = 'A' }, composition.raw_keys.items[0]);
    try std.testing.expectEqual(Key{ .latin = 's' }, composition.raw_keys.items[1]);
    try std.testing.expectEqual(Key{ .latin = 'u' }, composition.raw_keys.items[2]);
    try std.testing.expectEqual(Key{ .latin = '3' }, composition.raw_keys.items[3]);
    try std.testing.expectEqual(Key{ .key = ' ' }, composition.raw_keys.items[4]);
}

test "parse and segments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try typed(a, "su3cl");
    const p = try c.parsed(a);
    try testing.expectEqual(@as(usize, 1), p.complete.len);
    try testing.expectEqualStrings("cl", p.pending);
    _ = try c.appendLiteral(a, "，");
    _ = try c.appendLatin(a, "A");
    const segs = try c.segments(a);
    try testing.expectEqual(@as(usize, 4), segs.len);
    try testing.expectEqualStrings("A", segs[3].latin);
    try testing.expectEqualStrings("ㄋㄧˇㄏㄠ，A", try c.rawPhonetic(a));
}

test "caret edits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try typed(a, "su3a87");
    c.moveCaret(3);
    const tail = try c.splitAtCaret(a);
    _ = try c.append(a, 'c');
    try c.joinTail(a, tail);
    try testing.expectEqual(@as(?usize, 4), c.caret);
    try testing.expectEqualStrings("ㄋㄧˇㄏㄇㄚ˙", try c.rawPhonetic(a));
}
