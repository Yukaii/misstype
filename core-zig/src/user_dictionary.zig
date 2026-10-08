//! The user's own dictionary: added words and hidden built-in words (port
//! of Sources/MisstypeCore/UserDictionary.swift). vChewing userdata format:
//! `text reading [weight]`, `!text reading` hides a built-in word.

const std = @import("std");
const keyboard = @import("keyboard.zig");
const unicode = @import("unicode.zig");
const lexicon = @import("lexicon.zig");
const Allocator = std.mem.Allocator;

pub const default_weight = 0.0;
pub const max_syllables = 8;
pub const min_syllables = 2;
pub const max_text_length = 32;

pub const Entry = struct {
    reading: []const u8,
    text: []const u8,
    weight: f64 = default_weight,
};

pub const Problem = struct { line: usize, message: []const u8 };

pub const UserDictionary = struct {
    gpa: Allocator,
    added: std.ArrayList(Entry) = .empty,
    excluded: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: Allocator) UserDictionary {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *UserDictionary) void {
        for (self.added.items) |e| self.freeEntry(e);
        for (self.excluded.items) |e| self.freeEntry(e);
        self.added.deinit(self.gpa);
        self.excluded.deinit(self.gpa);
    }

    fn freeEntry(self: *UserDictionary, e: Entry) void {
        self.gpa.free(e.reading);
        self.gpa.free(e.text);
    }

    pub fn clone(self: *const UserDictionary) !UserDictionary {
        var out = UserDictionary.init(self.gpa);
        errdefer out.deinit();
        for (self.added.items) |e| try out.added.append(self.gpa, try self.dupeEntry(e));
        for (self.excluded.items) |e| try out.excluded.append(self.gpa, try self.dupeEntry(e));
        return out;
    }

    fn dupeEntry(self: *const UserDictionary, e: Entry) !Entry {
        return .{ .reading = try self.gpa.dupe(u8, e.reading), .text = try self.gpa.dupe(u8, e.text), .weight = e.weight };
    }

    pub fn isEmpty(self: *const UserDictionary) bool {
        return self.added.items.len == 0 and self.excluded.items.len == 0;
    }

    fn find(list: []const Entry, reading: []const u8, text: []const u8) ?usize {
        for (list, 0..) |e, i| {
            if (std.mem.eql(u8, e.reading, reading) and std.mem.eql(u8, e.text, text)) return i;
        }
        return null;
    }

    pub fn contains(self: *const UserDictionary, reading: []const u8, text: []const u8) bool {
        return find(self.added.items, reading, text) != null;
    }

    pub fn isExcluded(self: *const UserDictionary, reading: []const u8, text: []const u8) bool {
        return find(self.excluded.items, reading, text) != null;
    }

    fn removeAll(self: *UserDictionary, list: *std.ArrayList(Entry), reading: []const u8, text: []const u8) bool {
        var removed = false;
        while (find(list.items, reading, text)) |i| {
            self.freeEntry(list.orderedRemove(i));
            removed = true;
        }
        return removed;
    }

    /// Adds (or re-weights) a word; lifts a matching exclusion.
    pub fn add(self: *UserDictionary, reading: []const u8, text: []const u8, weight: f64) !bool {
        if (validate(reading, text) != null) return false;
        _ = self.removeAll(&self.excluded, reading, text);
        if (find(self.added.items, reading, text)) |i| {
            self.added.items[i].weight = weight;
        } else {
            try self.added.append(self.gpa, try self.dupeEntry(.{ .reading = reading, .text = text, .weight = weight }));
        }
        return true;
    }

    pub fn remove(self: *UserDictionary, reading: []const u8, text: []const u8) bool {
        return self.removeAll(&self.added, reading, text);
    }

    /// Hides a built-in word (and drops a user-added word of the pair).
    pub fn exclude(self: *UserDictionary, reading: []const u8, text: []const u8) !bool {
        if (validate(reading, text) != null) return false;
        _ = self.removeAll(&self.added, reading, text);
        if (!self.isExcluded(reading, text)) {
            try self.excluded.append(self.gpa, try self.dupeEntry(.{ .reading = reading, .text = text, .weight = 0 }));
        }
        return true;
    }

    pub fn unexclude(self: *UserDictionary, reading: []const u8, text: []const u8) bool {
        return self.removeAll(&self.excluded, reading, text);
    }

    /// The decoder's view of the overlay (slices into this dictionary).
    pub fn words(self: *const UserDictionary, gpa: Allocator) !struct { added: []lexicon.UserWord, excluded: []lexicon.UserWord } {
        const added = try gpa.alloc(lexicon.UserWord, self.added.items.len);
        for (self.added.items, added) |e, *w| w.* = .{ .reading = e.reading, .text = e.text, .weight = e.weight };
        const excluded = try gpa.alloc(lexicon.UserWord, self.excluded.items.len);
        for (self.excluded.items, excluded) |e, *w| w.* = .{ .reading = e.reading, .text = e.text, .weight = e.weight };
        return .{ .added = added, .excluded = excluded };
    }

    // MARK: - Text format

    /// Canonical file text: header, additions, then exclusions.
    pub fn serialized(self: *const UserDictionary, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(gpa, "# Misstype user dictionary (vChewing format): text reading [weight]; \"!\" hides a built-in word.");
        for (self.added.items) |e| {
            try out.print(gpa, "\n{s} {s}", .{ e.text, e.reading });
            if (e.weight != default_weight) {
                try out.append(gpa, ' ');
                try appendSwiftDouble(&out, gpa, e.weight);
            }
        }
        for (self.excluded.items) |e| try out.print(gpa, "\n!{s} {s}", .{ e.text, e.reading });
        try out.append(gpa, '\n');
        return out.toOwnedSlice(gpa);
    }

    /// Parses file text; bad lines are skipped (counted in `problems`).
    pub fn parse(gpa: Allocator, source: []const u8, problems: ?*std.ArrayList(Problem)) !UserDictionary {
        var dict = UserDictionary.init(gpa);
        errdefer dict.deinit();
        var lines = std.mem.splitScalar(u8, source, '\n');
        var number: usize = 0;
        while (lines.next()) |raw| {
            number += 1;
            const line = std.mem.trim(u8, raw, "\r");
            if (std.mem.trim(u8, line, " \t").len == 0 or std.mem.startsWith(u8, line, "#")) continue;
            const is_exclusion = std.mem.startsWith(u8, line, "!");
            var fields: [4][]const u8 = undefined;
            var count: usize = 0;
            var it = std.mem.tokenizeAny(u8, if (is_exclusion) line[1..] else line, " \t");
            while (it.next()) |f| {
                if (count < 4) fields[count] = f;
                count += 1;
            }
            if (count < 2 or count > 3) {
                try report(gpa, problems, number, "expected text reading [weight]");
                continue;
            }
            if (isReadingLike(fields[0]) and !isReadingLike(fields[1])) std.mem.swap([]const u8, &fields[0], &fields[1]);
            const text = fields[0];
            const reading = fields[1];
            if (validate(reading, text)) |message| {
                try report(gpa, problems, number, message);
                continue;
            }
            var weight: f64 = default_weight;
            if (count == 3) {
                const value = std.fmt.parseFloat(f64, fields[2]) catch null;
                if (is_exclusion or value == null or !std.math.isFinite(value.?) or value.? > 0) {
                    try report(gpa, problems, number, "weight must be a number ≤ 0 (exclusions take none)");
                    continue;
                }
                weight = value.?;
            }
            if (is_exclusion) {
                _ = try dict.exclude(reading, text);
            } else {
                _ = try dict.add(reading, text, weight);
            }
        }
        return dict;
    }

    fn report(gpa: Allocator, problems: ?*std.ArrayList(Problem), line: usize, message: []const u8) !void {
        if (problems) |p| try p.append(gpa, .{ .line = line, .message = message });
    }
};

/// Why a (reading, text) pair cannot be stored, or null when it can.
pub fn validate(reading: []const u8, text: []const u8) ?[]const u8 {
    if (reading.len == 0) return "empty syllable in reading";
    var count: usize = 0;
    var syllables = std.mem.splitScalar(u8, reading, '-');
    while (syllables.next()) |s| {
        if (s.len == 0) return "empty syllable in reading";
        count += 1;
    }
    if (count > max_syllables) return "more than 8 syllables";
    syllables = std.mem.splitScalar(u8, reading, '-');
    while (syllables.next()) |s| {
        var body = s;
        if (endsWithToneMark(s)) body = s[0 .. s.len - 2];
        if (body.len == 0) return "not a Zhuyin syllable";
        var i: usize = 0;
        while (i < body.len) {
            const w = unicode.seqLen(body[i]);
            if (i + w > body.len or keyboard.keyForSymbol(body[i .. i + w]) == null) return "not a Zhuyin syllable";
            i += w;
        }
    }
    const chars = unicode.characterCount(text);
    if (text.len == 0 or chars > max_text_length) return "text must be one word, no spaces";
    var it = unicode.scalars(text);
    while (it.nextCodepoint()) |cp| if (unicode.isWhitespace(cp)) return "text must be one word, no spaces";
    if (chars != count) return "character count differs from syllable count";
    return null;
}

/// Tone marks ˊˇˋ˙ are all `CB xx` in UTF-8.
fn endsWithToneMark(s: []const u8) bool {
    if (s.len < 2 or s[s.len - 2] != 0xCB) return false;
    const b = s[s.len - 1];
    return b == 0x8A or b == 0x87 or b == 0x8B or b == 0x99;
}

fn isReadingLike(field: []const u8) bool {
    var i: usize = 0;
    while (i < field.len) {
        const w = unicode.seqLen(field[i]);
        if (i + w > field.len) return false;
        const ch = field[i .. i + w];
        const ok = std.mem.eql(u8, ch, "-") or (w == 2 and endsWithToneMark(ch)) or keyboard.keyForSymbol(ch) != null;
        if (!ok) return false;
        i += w;
    }
    return true;
}

/// Swift `Double.description`: shortest round-trip digits, ".0" when integral.
pub fn appendSwiftDouble(out: *std.ArrayList(u8), gpa: Allocator, value: f64) !void {
    const start = out.items.len;
    try out.print(gpa, "{d}", .{value});
    const printed = out.items[start..];
    if (std.mem.indexOfAny(u8, printed, ".einf") == null) try out.appendSlice(gpa, ".0");
}

const testing = std.testing;

test "parse, legacy order, serialize" {
    const source = "# c\n黃昱愷 ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ\nㄉㄚˇ-ㄉㄨㄟˋ\t打對\n!打對 ㄉㄚˇ-ㄉㄨㄟˋ\n壞 ㄏㄨㄞˋ-ㄏㄨㄞˋ\n好人 ㄏㄠˇ-ㄖㄣˊ -1.5\n";
    var problems: std.ArrayList(Problem) = .empty;
    defer problems.deinit(testing.allocator);
    var dict = try UserDictionary.parse(testing.allocator, source, &problems);
    defer dict.deinit();
    try testing.expectEqual(@as(usize, 2), dict.added.items.len);
    try testing.expectEqual(@as(usize, 1), dict.excluded.items.len);
    try testing.expectEqual(@as(usize, 1), problems.items.len);
    const text = try dict.serialized(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "好人 ㄏㄠˇ-ㄖㄣˊ -1.5\n") != null);
}
