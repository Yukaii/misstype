//! Decoded sentences and their alignment (SentenceCandidate, WordSpan,
//! CursorOption and their helpers in Lexicon.swift / CursorSelection.swift).

const std = @import("std");
const keyboard = @import("keyboard.zig");
const unicode = @import("unicode.zig");
const Syllable = keyboard.Syllable;
const Allocator = std.mem.Allocator;

/// Half-open integer range (Swift `Range<Int>`).
pub const Range = struct {
    start: u32,
    end: u32,

    pub fn len(r: Range) u32 {
        return r.end - r.start;
    }
    pub fn isEmpty(r: Range) bool {
        return r.end <= r.start;
    }
    pub fn contains(r: Range, i: usize) bool {
        return i >= r.start and i < r.end;
    }
    pub fn overlaps(a: Range, b: Range) bool {
        return !a.isEmpty() and !b.isEmpty() and a.start < b.end and b.start < a.end;
    }
    pub fn eql(a: Range, b: Range) bool {
        return a.start == b.start and a.end == b.end;
    }
    pub fn of(start: usize, end: usize) Range {
        return .{ .start = @intCast(start), .end = @intCast(end) };
    }
};

/// One decoded word: syllable range in the input, UTF-16 range in text.
pub const Span = struct {
    syllables: Range,
    chars: Range,
};

/// Original raw-key ranges reinterpreted as English by the mixed pass.
/// Session chunking skips these keys when matching Chinese syllables; an
/// edited English word must remain available for correction.
pub const EnglishSpan = struct { keys: Range, exact: bool };

pub const Candidate = struct {
    text: []const u8,
    utf16_len: u32,
    score: f64,
    repairs: i32,
    unresolved: i32,
    alignment: []const Span = &.{},
    syllables: []const Syllable = &.{},
    runs: []const Range = &.{},
    english_spans: []const EnglishSpan = &.{},

    pub fn empty() Candidate {
        return .{ .text = "", .utf16_len = 0, .score = 0, .repairs = 0, .unresolved = 0 };
    }

    /// Syllable range of the Zhuyin run holding `syllable`.
    pub fn run(self: Candidate, syllable: usize) ?Range {
        for (self.runs) |r| if (r.contains(syllable)) return r;
        return null;
    }

    pub fn runIndex(self: Candidate, syllable: usize) ?usize {
        for (self.runs, 0..) |r, i| if (r.contains(syllable)) return i;
        return null;
    }

    /// UTF-16 offset of `syllable`'s first character: exact inside 1:1
    /// words, else the start of the word holding it.
    pub fn charOffset(self: Candidate, syllable: usize) ?u32 {
        const word = self.wordAt(syllable) orelse return null;
        if (word.chars.len() != word.syllables.len()) return word.chars.start;
        return word.chars.start + @as(u32, @intCast(syllable - word.syllables.start));
    }

    /// First aligned word whose syllables contain `syllable`.
    pub fn wordAt(self: Candidate, syllable: usize) ?Span {
        for (self.alignment) |word| if (word.syllables.contains(syllable)) return word;
        return null;
    }

    /// Positional session-pin key ("run#offset@readings") for the word
    /// covering `span`; written into `buf`.
    pub fn pinKey(self: Candidate, span: Range, buf: *std.ArrayList(u8), gpa: Allocator) !?[]const u8 {
        const r = self.runIndex(span.start) orelse return null;
        if (span.end > self.runs[r].end) return null;
        const start = self.charOffset(span.start) orelse return null;
        const run_start = self.charOffset(self.runs[r].start) orelse return null;
        buf.clearRetainingCapacity();
        try buf.print(gpa, "{d}#{d}@", .{ r, @as(i64, start) - @as(i64, run_start) });
        try appendKey(buf, gpa, self.syllables[span.start..span.end]);
        return buf.items;
    }

    /// Text of UTF-16 range `chars` (Swift lossy UTF-16 slicing).
    pub fn slice(self: Candidate, gpa: Allocator, chars: Range) !?[]const u8 {
        if (chars.end > self.utf16_len or chars.start > chars.end) return null;
        return try unicode.utf16Slice(gpa, self.text, chars.start, chars.end);
    }

    pub fn deepCopy(self: Candidate, gpa: Allocator) !Candidate {
        var copy = self;
        copy.text = try gpa.dupe(u8, self.text);
        copy.alignment = try gpa.dupe(Span, self.alignment);
        const syllables = try gpa.alloc(Syllable, self.syllables.len);
        for (self.syllables, syllables) |s, *out| out.* = .{ .keys = try gpa.dupe(u8, s.keys), .tone = s.tone };
        copy.syllables = syllables;
        copy.runs = try gpa.dupe(Range, self.runs);
        copy.english_spans = try gpa.dupe(EnglishSpan, self.english_spans);
        return copy;
    }
};

/// Toneless-concatenated key of syllables (UserLexicon.key(for:)).
pub fn appendKey(buf: *std.ArrayList(u8), gpa: Allocator, syllables: []const Syllable) !void {
    var tmp: [Syllable.max_reading_bytes]u8 = undefined;
    for (syllables) |s| try buf.appendSlice(gpa, s.base(&tmp));
}

/// Toneless-concatenated key of readings (UserLexicon.key(forReadings:)).
pub fn appendReadingsKey(buf: *std.ArrayList(u8), gpa: Allocator, readings: []const []const u8) !void {
    for (readings) |r| {
        const start = buf.items.len;
        try buf.appendSlice(gpa, r);
        const stripped = keyboard.withoutTone(buf.items[start..], buf.items[start..]);
        buf.shrinkRetainingCapacity(start + stripped.len);
    }
}

/// One pickable word at the syllable cursor.
pub const CursorOption = struct {
    text: []const u8,
    span: Range,
    score: f64,
};

/// Best score first, text ascending on ties.
pub fn better(a: Candidate, b: Candidate) bool {
    return if (a.score == b.score) unicode.lessThan(a.text, b.text) else a.score > b.score;
}
