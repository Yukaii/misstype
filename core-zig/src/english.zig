//! English words in bare keys: the word list and the mixed pass (port of
//! Sources/MisstypeCore/MixedDecode.swift).
//!
//! Where Swift's ordering is unspecified (dictionary iteration feeding a
//! score-only sort), this port uses file order; the two agree unless two
//! English matches tie exactly on score.

const std = @import("std");
const keyboard = @import("keyboard.zig");
const unicode = @import("unicode.zig");
const candidate_mod = @import("candidate.zig");
const composition_mod = @import("composition.zig");
const lexicon_mod = @import("lexicon.zig");
const user_lexicon = @import("user_lexicon.zig");
const Candidate = candidate_mod.Candidate;
const Range = candidate_mod.Range;
const Composition = composition_mod.Composition;
const Key = composition_mod.Key;
const Lexicon = lexicon_mod.Lexicon;
const Allocator = std.mem.Allocator;

pub const fuzzy_min_length = 5;
pub const default_switch_penalty = 4.0;
pub const default_min_word_length = 3;
pub const default_english_edit_cost = 6.0;
pub const max_span_length = 14;
pub const max_spans = 8;
pub const max_spans_per_hypothesis = 3;
pub const auto_margin = 3.0;
pub const suggest_window = 8.0;
pub const max_keys = 48;
pub const raw_key_cost = 5.0;

pub const EnglishLexicon = struct {
    arena: std.heap.ArenaAllocator,
    scores: std.StringHashMapUnmanaged(f64) = .empty,
    /// Words of at least `fuzzy_min_length`, by themselves and by every
    /// one-letter deletion (symmetric delete).
    delete_index: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,

    /// `word<TAB>ln p` rows.
    pub fn create(gpa: Allocator, tsv: []const u8) !*EnglishLexicon {
        const self = try gpa.create(EnglishLexicon);
        self.* = .{ .arena = .init(gpa) };
        errdefer self.destroy();
        const a = self.arena.allocator();
        var order: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, tsv, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeScalar(u8, line, '\t');
            const word = fields.next() orelse continue;
            const value = fields.next() orelse continue;
            if (fields.next() != null) continue;
            const score = std.fmt.parseFloat(f64, value) catch continue;
            const slot = try self.scores.getOrPut(a, word);
            if (!slot.found_existing) {
                slot.key_ptr.* = try a.dupe(u8, word);
                try order.append(a, slot.key_ptr.*);
            }
            slot.value_ptr.* = score;
        }
        for (order.items) |word| {
            if (unicode.characterCount(word) < fuzzy_min_length) continue;
            try self.index(word, word);
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            for (0..word.len) |i| {
                const variant = try std.mem.concat(a, u8, &.{ word[0..i], word[i + 1 ..] });
                if ((try seen.getOrPut(a, variant)).found_existing) continue;
                try self.index(variant, word);
            }
        }
        return self;
    }

    fn index(self: *EnglishLexicon, key: []const u8, word: []const u8) !void {
        const a = self.arena.allocator();
        const slot = try self.delete_index.getOrPut(a, key);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(a, word);
    }

    pub fn destroy(self: *EnglishLexicon) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn isEmpty(self: *const EnglishLexicon) bool {
        return self.scores.count() == 0;
    }

    pub const Match = struct { word: []const u8, score: f64, edits: u8 };

    /// Exact word, or words one edit away, best score first.
    pub fn matches(self: *const EnglishLexicon, arena: Allocator, typed: []const u8, fuzzy: bool) ![]Match {
        if (self.scores.get(typed)) |score| {
            const out = try arena.alloc(Match, 1);
            out[0] = .{ .word = typed, .score = score, .edits = 0 };
            return out;
        }
        if (!fuzzy or typed.len < fuzzy_min_length - 1) return &.{};
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var out: std.ArrayList(Match) = .empty;
        var keys: std.ArrayList([]const u8) = .empty;
        try keys.append(arena, typed);
        var variants: std.StringHashMapUnmanaged(void) = .empty;
        for (0..typed.len) |i| {
            const variant = try std.mem.concat(arena, u8, &.{ typed[0..i], typed[i + 1 ..] });
            if ((try variants.getOrPut(arena, variant)).found_existing) continue;
            try keys.append(arena, variant);
        }
        for (keys.items) |key| {
            const list = self.delete_index.get(key) orelse continue;
            for (list.items) |word| {
                if ((try seen.getOrPut(arena, word)).found_existing) continue;
                if (withinOneEdit(typed, word)) if (self.scores.get(word)) |score| {
                    try out.append(arena, .{ .word = word, .score = score, .edits = 1 });
                };
            }
        }
        std.mem.sort(Match, out.items, {}, struct {
            fn lt(_: void, a: Match, b: Match) bool {
                return a.score > b.score;
            }
        }.lt);
        return out.items;
    }

    /// Optimal-string-alignment distance 1 (ASCII words).
    fn withinOneEdit(a: []const u8, b: []const u8) bool {
        if (std.mem.eql(u8, a, b)) return true;
        if (@max(a.len, b.len) - @min(a.len, b.len) > 1) return false;
        if (a.len == b.len) {
            var diffs: [3]usize = undefined;
            var n: usize = 0;
            for (a, b, 0..) |x, y, i| if (x != y) {
                if (n < 3) diffs[n] = i;
                n += 1;
            };
            if (n == 1) return true;
            return n == 2 and diffs[1] == diffs[0] + 1 and a[diffs[0]] == b[diffs[1]] and a[diffs[1]] == b[diffs[0]];
        }
        const long = if (a.len > b.len) a else b;
        const short = if (a.len > b.len) b else a;
        var skip: usize = 0;
        while (skip < short.len and long[skip] == short[skip]) skip += 1;
        return std.mem.eql(u8, long[skip + 1 ..], short[skip..]);
    }
};

pub const MixedCandidate = struct {
    sentence: Candidate,
    score: f64,
};

const SpanWord = struct { range: Range, word: []const u8, score: f64, exact: bool };

const Letter = struct { char: u8, latin: bool };

/// A bare Zhuyin-position letter, or a letter typed as Latin.
fn letter(key: Key) ?Letter {
    return switch (key) {
        .key => |k| if (std.ascii.isLower(k)) .{ .char = k, .latin = false } else null,
        .latin => |c| if (std.ascii.isAlphabetic(c)) .{ .char = std.ascii.toLower(c), .latin = true } else null,
        .literal => null,
    };
}

pub const Pass = struct { candidates: []MixedCandidate, plain_score: ?f64 };

pub const PassOptions = struct {
    switch_penalty: f64 = default_switch_penalty,
    min_word_length: usize = default_min_word_length,
    include_plain: bool = true,
    prune_window: f64 = suggest_window,
    fuzzy_english: bool = true,
    english_edit_cost: f64 = default_english_edit_cost,
    live_tail: bool = false,
    fuzzy: bool = true,
    tone_tolerance: bool = true,
    user_lexicon: ?*const user_lexicon.UserLexicon = null,
};

/// Every non-overlapping subset of English spans decoded through the
/// shipping path; spans priced `wordScore - switchPenalty`.
pub fn mixedPass(decoder: *const Lexicon, arena: Allocator, keys: []const Key, english: *const EnglishLexicon, opts: PassOptions) !Pass {
    if (keys.len == 0) return .{ .candidates = &.{}, .plain_score = null };
    var spans: std.ArrayList(SpanWord) = .empty;
    var start: usize = 0;
    while (start < keys.len) {
        if (letter(keys[start]) == null) {
            start += 1;
            continue;
        }
        var end = start;
        while (end < keys.len and letter(keys[end]) != null) end += 1;
        var from = start;
        while (from + opts.min_word_length <= end) : (from += 1) {
            var to = from + opts.min_word_length;
            while (to <= @min(end, from + max_span_length)) : (to += 1) {
                // Latin keys only lead a span (a capital); at least one is bare.
                var seen_bare = false;
                var valid = true;
                for (keys[from..to]) |k| {
                    if (letter(k).?.latin) {
                        if (seen_bare) {
                            valid = false;
                            break;
                        }
                    } else seen_bare = true;
                }
                if (!valid or !seen_bare) continue;
                const typed = try arena.alloc(u8, to - from);
                for (keys[from..to], typed) |k, *c| c.* = letter(k).?.char;
                const capital = keys[from] == .latin and std.ascii.isUpper(keys[from].latin);
                for (try english.matches(arena, typed, opts.fuzzy_english)) |match| {
                    if (unicode.characterCount(match.word) < opts.min_word_length) continue;
                    // A different extra letter right after a whole word is the
                    // next Chinese syllable starting, not a typo.
                    if (match.edits == 1 and typed.len == match.word.len + 1 and
                        std.mem.startsWith(u8, typed, match.word) and
                        typed[typed.len - 1] != typed[typed.len - 2]) continue;
                    const word = if (capital) blk: {
                        const w = try arena.dupe(u8, match.word);
                        w[0] = std.ascii.toUpper(w[0]);
                        break :blk w;
                    } else match.word;
                    try spans.append(arena, .{ .range = Range.of(from, to), .word = word, .score = match.score - opts.english_edit_cost * @as(f64, @floatFromInt(match.edits)), .exact = match.edits == 0 });
                }
            }
        }
        start = end;
    }
    std.mem.sort(SpanWord, spans.items, {}, struct {
        fn lt(_: void, a: SpanWord, b: SpanWord) bool {
            return if (a.score == b.score) a.range.start < b.range.start else a.score > b.score;
        }
    }.lt);
    const chosen_spans = spans.items[0..@min(spans.items.len, max_spans)];

    var h: Hypotheses = .{ .decoder = decoder, .arena = arena, .keys = keys, .spans = chosen_spans, .opts = opts };
    if (chosen_spans.len == 0) {
        return .{ .candidates = if (opts.include_plain) try h.get(&.{}) else &.{}, .plain_score = null };
    }
    const plain = try h.get(&.{});
    const plain_score = if (plain.len > 0) plain[0].score else -std.math.inf(f64);
    var survivors: std.ArrayList(usize) = .empty;
    for (chosen_spans, 0..) |_, i| {
        const alone = try h.get(&.{i});
        const score = if (alone.len > 0) alone[0].score else -std.math.inf(f64);
        if (score > plain_score - opts.prune_window) try survivors.append(arena, i);
    }
    var subsets: std.ArrayList([]const usize) = .empty;
    if (opts.include_plain) try subsets.append(arena, &.{});
    try extendSubsets(arena, &subsets, chosen_spans, survivors.items, &.{}, 0);

    var best: std.StringArrayHashMapUnmanaged(MixedCandidate) = .empty;
    for (subsets.items) |subset| {
        for (try h.get(subset)) |c| {
            const slot = try best.getOrPut(arena, c.sentence.text);
            if (slot.found_existing and slot.value_ptr.score >= c.score) continue;
            slot.value_ptr.* = c;
        }
    }
    const out = try arena.dupe(MixedCandidate, best.values());
    std.mem.sort(MixedCandidate, out, {}, struct {
        fn lt(_: void, a: MixedCandidate, b: MixedCandidate) bool {
            return if (a.score == b.score) unicode.lessThan(a.sentence.text, b.sentence.text) else a.score > b.score;
        }
    }.lt);
    return .{ .candidates = out[0..@min(out.len, 16)], .plain_score = plain_score };
}

fn extendSubsets(arena: Allocator, subsets: *std.ArrayList([]const usize), spans: []const SpanWord, survivors: []const usize, chosen: []const usize, from: usize) !void {
    if (chosen.len >= max_spans_per_hypothesis) return;
    for (from..survivors.len) |next| {
        const candidate = survivors[next];
        const overlaps = for (chosen) |c| {
            if (spans[c].range.overlaps(spans[candidate].range)) break true;
        } else false;
        if (overlaps) continue;
        const grown = try arena.alloc(usize, chosen.len + 1);
        @memcpy(grown[0..chosen.len], chosen);
        grown[chosen.len] = candidate;
        try subsets.append(arena, grown);
        try extendSubsets(arena, subsets, spans, survivors, grown, next + 1);
    }
}

const Hypotheses = struct {
    decoder: *const Lexicon,
    arena: Allocator,
    keys: []const Key,
    spans: []const SpanWord,
    opts: PassOptions,
    memo: std.ArrayList(struct { subset: []const usize, result: []MixedCandidate }) = .empty,

    fn get(h: *Hypotheses, subset: []const usize) ![]MixedCandidate {
        for (h.memo.items) |m| if (std.mem.eql(usize, m.subset, subset)) return m.result;
        const result = try h.compute(subset);
        try h.memo.append(h.arena, .{ .subset = try h.arena.dupe(usize, subset), .result = result });
        return result;
    }

    fn compute(h: *Hypotheses, subset: []const usize) ![]MixedCandidate {
        const arena = h.arena;
        const chosen = try arena.alloc(SpanWord, subset.len);
        for (subset, chosen) |i, *c| c.* = h.spans[i];
        std.mem.sort(SpanWord, chosen, {}, struct {
            fn lt(_: void, a: SpanWord, b: SpanWord) bool {
                return a.range.start < b.range.start;
            }
        }.lt);
        var c: Composition = .{};
        for (h.keys, 0..) |key, index| {
            const span: ?SpanWord = for (chosen) |s| {
                if (s.range.contains(index)) break s;
            } else null;
            if (span) |s| {
                // A typo'd span renders the corrected word, once, at its start.
                if (index == s.range.start) {
                    for (s.word) |ch| _ = try c.appendLatin(arena, &.{ch});
                }
            } else switch (key) {
                .latin => |ch| _ = try c.appendLatin(arena, &.{ch}),
                .literal => |l| _ = try c.appendLiteral(arena, @import("punctuation.zig").literals[l]),
                .key => |k| {
                    if (k == ' ') {
                        _ = try c.appendSpace(arena);
                    } else {
                        _ = try c.append(arena, k);
                    }
                },
            }
        }
        const pending = (try c.parsed(arena)).pending;
        const cut = if (h.opts.live_tail) try h.decoder.livePendingCut(arena, pending, h.opts.tone_tolerance) else pending.len;
        var tail: std.ArrayList(u8) = .empty;
        for (pending[cut..]) |k| try tail.appendSlice(arena, keyboard.symbol(k).?);
        const tail_count: f64 = @floatFromInt(pending.len - cut);
        const decoded = try h.decoder.decodeSegments(arena, try c.segments(arena), pending[0..cut], .{
            .fuzzy = h.opts.fuzzy,
            .tone_tolerance = h.opts.tone_tolerance,
            .user_lexicon = h.opts.user_lexicon,
        });
        var extra: f64 = 0;
        for (chosen) |s| extra = extra + s.score - h.opts.switch_penalty;
        extra = extra - raw_key_cost * tail_count;
        const n = @min(decoded.len, 2);
        const out = try arena.alloc(MixedCandidate, n);
        const english_spans = try arena.alloc(@import("candidate.zig").EnglishSpan, chosen.len);
        for (chosen, english_spans) |s, *span| span.* = .{ .keys = s.range, .exact = s.exact };
        for (decoded[0..n], out) |sentence, *o| {
            var shown = sentence;
            shown.english_spans = english_spans;
            if (tail.items.len > 0) {
                shown.text = try std.mem.concat(arena, u8, &.{ sentence.text, tail.items });
                shown.utf16_len = sentence.utf16_len + unicode.utf16Len(tail.items);
            }
            o.* = .{ .sentence = shown, .score = sentence.score + extra };
        }
        return out;
    }
};

pub const Application = struct {
    candidates: []Candidate,
    /// Texts of the inserted English readings.
    complete_texts: []const []const u8,
    adopted: bool,
};

/// Add the English reading to a live preview when the typed keys support
/// it. Null = leave the preview alone.
pub fn applyEnglish(decoder: *const Lexicon, arena: Allocator, live: []const Candidate, keys: []const Key, english: *const EnglishLexicon, fuzzy: bool, tone_tolerance: bool, user_lex: ?*const user_lexicon.UserLexicon) !?Application {
    const min_word_length = default_min_word_length;
    if (english.isEmpty() or keys.len < min_word_length or keys.len > max_keys or live.len == 0) return null;
    var run: usize = 0;
    var longest: usize = 0;
    var bare_in_run: usize = 0;
    var best_has_bare = false;
    for (keys) |key| {
        const bare = key == .key and std.ascii.isAlphabetic(key.key);
        const latin = key == .latin;
        if (bare or latin) {
            run += 1;
            if (bare) bare_in_run += 1;
            if (run > longest) {
                longest = run;
                best_has_bare = bare_in_run > 0;
            }
        } else {
            run = 0;
            bare_in_run = 0;
        }
    }
    if (longest < min_word_length or !best_has_bare) return null;
    const pass = try mixedPass(decoder, arena, keys, english, .{
        .include_plain = false,
        .live_tail = true,
        .fuzzy = fuzzy,
        .tone_tolerance = tone_tolerance,
        .user_lexicon = user_lex,
    });
    if (pass.candidates.len == 0) return null;
    const plain = pass.plain_score orelse return null;
    const best = pass.candidates[0];
    const margin = best.score - plain;
    if (margin < -suggest_window) return null;
    const adopted = margin >= auto_margin;
    var inserted: std.ArrayList(Candidate) = .empty;
    try inserted.append(arena, best.sentence);
    if (pass.candidates.len > 1 and best.score - pass.candidates[1].score < suggest_window) {
        try inserted.append(arena, pass.candidates[1].sentence);
    }
    var rest: std.ArrayList(Candidate) = .empty;
    for (live) |c| {
        const dup = for (inserted.items) |i| {
            if (std.mem.eql(u8, i.text, c.text)) break true;
        } else false;
        if (!dup) try rest.append(arena, c);
    }
    var ordered: std.ArrayList(Candidate) = .empty;
    if (adopted) {
        try ordered.appendSlice(arena, inserted.items);
        try ordered.appendSlice(arena, rest.items);
    } else {
        try ordered.appendSlice(arena, rest.items[0..@min(rest.items.len, 1)]);
        try ordered.appendSlice(arena, inserted.items);
        if (rest.items.len > 1) try ordered.appendSlice(arena, rest.items[1..]);
    }
    const texts = try arena.alloc([]const u8, inserted.items.len);
    for (inserted.items, texts) |c, *t| t.* = c.text;
    return .{ .candidates = ordered.items, .complete_texts = texts, .adopted = adopted };
}

test "english matches" {
    const english = try EnglishLexicon.create(std.testing.allocator, "hello\t-5\npython\t-9\nworld\t-6\n");
    defer english.destroy();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("python", (try english.matches(arena.allocator(), "pytohn", true))[0].word);
    try std.testing.expectEqual(@as(usize, 0), (try english.matches(arena.allocator(), "pyth", true)).len);
}
