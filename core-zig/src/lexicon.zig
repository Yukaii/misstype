//! Lexicon trie and the exact-input decode beam: a port of the fuzzy=false,
//! no-user-lexicon path of LexiconDecoder (Sources/MisstypeCore/Lexicon.swift).
//! Output must match Swift bit for bit (core-zig/bench/compare.sh).
//!
//! Not ported yet: edit repair (fuzzy), segmentation of toneless key runs,
//! user lexicon / pins / context rules, bigram overlay, channel model.

const std = @import("std");
const keyboard = @import("keyboard.zig");
const Syllable = keyboard.Syllable;
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    text: []const u8,
    score: f64,

    /// Best score first, text ascending (UTF-8 bytes) on ties, as in Swift.
    fn better(_: void, a: Entry, b: Entry) bool {
        return if (a.score == b.score) std.mem.order(u8, a.text, b.text) == .lt else a.score > b.score;
    }
};

const Node = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Single-syllable nodes only: entries rescored for toneless input
    /// (null = same as `entries`).
    toneless_entries: ?[]Entry = null,
};

pub const ReadingId = u32;

/// One reading a syllable may stand for.
pub const Option = struct {
    reading: ReadingId,
    cost: f64,
    correction: i32,
    word_only: bool = false,
};

/// One decoded word: syllable range in the input, UTF-16 range in text
/// (UTF-16 because the platform caret contract is UTF-16).
pub const Span = struct {
    syllable_start: u32,
    syllable_end: u32,
    char_start: u32,
    char_end: u32,
};

pub const Candidate = struct {
    text: []const u8,
    utf16_len: u32,
    score: f64,
    repairs: i32,
    unresolved: i32,
    alignment: []const Span,
};

pub const beam_width = 16;
/// Decode-time entries per node for multi-syllable input (Swift:
/// decodeEntriesPerNode).
const decode_entries_per_node = 4;
const max_word_syllables = 8;
const max_states = 32;

pub const Lexicon = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node) = .empty,
    /// (parent node << 32 | reading) -> child node. Node 0 is the root.
    children: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    reading_ids: std.StringHashMapUnmanaged(ReadingId) = .empty,
    reading_names: std.ArrayList([]const u8) = .empty,
    /// Toneless form -> every toned reading with that base.
    toneless: std.StringHashMapUnmanaged(std.ArrayList(ReadingId)) = .empty,
    entry_count: usize = 0,
    /// Cost per dictionary word on a path (LexiconLoader sets 0.5).
    word_penalty: f64 = 0,

    /// `tsv` parts are concatenated (lexicon.tsv, local_phrases.tsv); rows
    /// are `reading-reading<TAB>text<TAB>score`. `toneless` rows override a
    /// single char's score when its syllable is typed without a tone.
    pub fn create(gpa: Allocator, tsv: []const []const u8, toneless: []const u8) !*Lexicon {
        const self = try gpa.create(Lexicon);
        self.* = .{ .arena = .init(gpa) };
        errdefer self.destroy();
        const a = self.arena.allocator();
        try self.nodes.append(a, .{});
        for (tsv) |part| try self.addRows(part);
        for (self.nodes.items) |*node| std.mem.sort(Entry, node.entries.items, {}, Entry.better);
        try self.applyToneless(toneless);
        return self;
    }

    pub fn destroy(self: *Lexicon) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn addRows(self: *Lexicon, tsv: []const u8) !void {
        const a = self.arena.allocator();
        var lines = std.mem.tokenizeScalar(u8, tsv, '\n');
        while (lines.next()) |line| {
            // Swift's split drops empty fields; tokenize does the same.
            var fields: [3][]const u8 = undefined;
            var count: usize = 0;
            var it = std.mem.tokenizeScalar(u8, line, '\t');
            while (it.next()) |field| : (count += 1) {
                if (count == 3) break;
                fields[count] = field;
            }
            if (count != 3 or it.next() != null) continue;
            const score = std.fmt.parseFloat(f64, fields[2]) catch continue;
            if (!std.math.isFinite(score)) continue;
            var parts: [max_word_syllables][]const u8 = undefined;
            var n: usize = 0;
            var syllables = std.mem.tokenizeScalar(u8, fields[0], '-');
            const fits = while (syllables.next()) |part| : (n += 1) {
                if (n == max_word_syllables) break false;
                parts[n] = part;
            } else true;
            if (!fits or n == 0) continue;
            var node: u32 = 0;
            for (parts[0..n]) |reading| {
                const id = try self.intern(reading);
                const key = (@as(u64, node) << 32) | id;
                const slot = try self.children.getOrPut(a, key);
                if (!slot.found_existing) {
                    slot.value_ptr.* = @intCast(self.nodes.items.len);
                    try self.nodes.append(a, .{});
                }
                node = slot.value_ptr.*;
            }
            try self.nodes.items[node].entries.append(a, .{ .text = try a.dupe(u8, fields[1]), .score = score });
            self.entry_count += 1;
        }
    }

    fn intern(self: *Lexicon, reading: []const u8) !ReadingId {
        const a = self.arena.allocator();
        if (self.reading_ids.get(reading)) |id| return id;
        const name = try a.dupe(u8, reading);
        const id: ReadingId = @intCast(self.reading_names.items.len);
        try self.reading_names.append(a, name);
        try self.reading_ids.put(a, name, id);
        const base = keyboard.withoutTone(name, try a.alloc(u8, name.len));
        const slot = try self.toneless.getOrPut(a, base);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(a, id);
        return id;
    }

    fn applyToneless(self: *Lexicon, tsv: []const u8) !void {
        const a = self.arena.allocator();
        // reading -> text -> score, last row wins (Swift dictionary assignment).
        var overrides: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(f64)) = .empty;
        var lines = std.mem.tokenizeScalar(u8, tsv, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "#")) continue;
            var fields: [3][]const u8 = undefined;
            var count: usize = 0;
            var it = std.mem.tokenizeScalar(u8, line, '\t');
            while (it.next()) |field| : (count += 1) {
                if (count == 3) break;
                fields[count] = field;
            }
            if (count != 3 or it.next() != null) continue;
            const score = std.fmt.parseFloat(f64, fields[2]) catch continue;
            if (!std.math.isFinite(score)) continue;
            const slot = try overrides.getOrPut(a, fields[0]);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.put(a, fields[1], score);
        }
        var groups = overrides.iterator();
        while (groups.next()) |group| {
            const id = self.reading_ids.get(group.key_ptr.*) orelse continue;
            const child = self.children.get(id) orelse continue; // root << 32 == 0
            const node = &self.nodes.items[child];
            const rescored = try a.alloc(Entry, node.entries.items.len);
            for (node.entries.items, rescored) |entry, *out| {
                out.* = .{ .text = entry.text, .score = group.value_ptr.get(entry.text) orelse entry.score };
            }
            std.mem.sort(Entry, rescored, {}, Entry.better);
            node.toneless_entries = rescored;
        }
    }

    pub fn readingName(self: *const Lexicon, id: ReadingId) []const u8 {
        return self.reading_names.items[id];
    }

    /// Exact-input reading options of one syllable, cheapest first (Swift
    /// `alternatives(_:fuzzy: false, toneTolerance:)`): exact 0, toneless
    /// 0.5, explicit-tone mismatch 4.0.
    pub fn alternatives(self: *const Lexicon, gpa: Allocator, syllable: Syllable, tone_tolerance: bool) ![]Option {
        var buf: [Syllable.max_reading_bytes]u8 = undefined;
        var base_buf: [Syllable.max_reading_bytes]u8 = undefined;
        const reading = syllable.reading(&buf);
        const variants = self.toneless.get(keyboard.withoutTone(reading, &base_buf));
        var out: std.ArrayList(Option) = .empty;
        errdefer out.deinit(gpa);
        if (syllable.tone != null) {
            const exact = self.reading_ids.get(reading);
            if (exact) |id| try out.append(gpa, .{ .reading = id, .cost = 0, .correction = 0 });
            if (tone_tolerance) if (variants) |list| for (list.items) |variant| {
                if (variant != exact) try out.append(gpa, .{ .reading = variant, .cost = 4.0, .correction = 1 });
            };
        } else if (variants) |list| {
            for (list.items) |variant| try out.append(gpa, .{ .reading = variant, .cost = 0.5, .correction = 0 });
        }
        // Readings are distinct here, so no cheapest-wins merge is needed
        // until repair options join.
        std.mem.sort(Option, out.items, self, struct {
            fn lessThan(lexicon: *const Lexicon, x: Option, y: Option) bool {
                return if (x.cost == y.cost)
                    std.mem.order(u8, lexicon.readingName(x.reading), lexicon.readingName(y.reading)) == .lt
                else
                    x.cost < y.cost;
            }
        }.lessThan);
        out.shrinkRetainingCapacity(@min(out.items.len, beam_width));
        return out.toOwnedSlice(gpa);
    }

    /// Top candidates for exactly typed syllables, best first. Everything
    /// returned lives in `arena`.
    pub fn decode(self: *const Lexicon, arena: Allocator, syllables: []const Syllable, tone_tolerance: bool) ![]Candidate {
        if (syllables.len == 0) return &.{};
        const options = try arena.alloc([]Option, syllables.len);
        for (syllables, options) |syllable, *out| out.* = try self.alternatives(arena, syllable, tone_tolerance);
        return self.decodeOptions(arena, syllables, options);
    }

    const Beam = struct {
        items: [beam_width]Candidate = undefined,
        len: usize = 0,

        fn slice(beam: *const Beam) []const Candidate {
            return beam.items[0..beam.len];
        }

        fn admits(beam: *const Beam, score: f64) bool {
            return beam.len < beam_width or score >= beam.items[beam_width - 1].score;
        }

        fn add(beam: *Beam, candidate: Candidate) void {
            for (beam.slice(), 0..) |existing, i| {
                if (!std.mem.eql(u8, existing.text, candidate.text)) continue;
                if (existing.score >= candidate.score) return;
                std.mem.copyForwards(Candidate, beam.items[i .. beam.len - 1], beam.items[i + 1 .. beam.len]);
                beam.len -= 1;
                break;
            }
            var position = beam.len;
            for (beam.slice(), 0..) |existing, i| {
                const precedes = if (candidate.score == existing.score)
                    std.mem.order(u8, candidate.text, existing.text) == .lt
                else
                    candidate.score > existing.score;
                if (precedes) {
                    position = i;
                    break;
                }
            }
            if (position == beam_width) return;
            // usize, not the u4 @min would infer from beam_width - 1.
            const last: usize = @min(beam.len, beam_width - 1);
            std.mem.copyBackwards(Candidate, beam.items[position + 1 .. last + 1], beam.items[position..last]);
            beam.items[position] = candidate;
            beam.len = last + 1;
        }
    };

    const State = struct { node: u32, penalty: f64, repairs: i32 };

    fn decodeOptions(self: *const Lexicon, arena: Allocator, syllables: []const Syllable, options: []const []Option) ![]Candidate {
        const paths = try arena.alloc(Beam, syllables.len + 1);
        for (paths) |*beam| beam.* = .{};
        paths[0].add(.{ .text = "", .utf16_len = 0, .score = 0, .repairs = 0, .unresolved = 0, .alignment = &.{} });
        var states: std.ArrayList(State) = .empty;
        var next: std.ArrayList(State) = .empty;
        for (0..syllables.len) |start| {
            if (paths[start].len == 0) continue;
            const prefixes = paths[start].items;
            const prefix_count = paths[start].len;
            // Unresolved: the raw reading stands in, at a heavy cost.
            var raw_buf: [Syllable.max_reading_bytes]u8 = undefined;
            const raw = syllables[start].reading(&raw_buf);
            for (prefixes[0..prefix_count]) |prefix| {
                if (!paths[start + 1].admits(prefix.score - 100)) continue;
                paths[start + 1].add(try extend(arena, prefix, raw, prefix.score - 100, prefix.repairs, prefix.unresolved + 1, start, start + 1));
            }
            states.clearRetainingCapacity();
            try states.append(arena, .{ .node = 0, .penalty = 0, .repairs = 0 });
            for (start..@min(syllables.len, start + max_word_syllables)) |end| {
                next.clearRetainingCapacity();
                for (states.items) |state| {
                    for (options[end]) |option| {
                        const child = self.children.get((@as(u64, state.node) << 32) | option.reading) orelse continue;
                        try next.append(arena, .{ .node = child, .penalty = state.penalty + option.cost, .repairs = state.repairs + option.correction });
                        if (option.word_only and end == start) continue;
                        const node = &self.nodes.items[child];
                        const entries = if (end == start and syllables[start].tone == null)
                            node.toneless_entries orelse node.entries.items
                        else
                            node.entries.items;
                        const cap: usize = if (syllables.len == 1) entries.len else @min(entries.len, decode_entries_per_node);
                        for (entries[0..cap]) |entry| {
                            for (prefixes[0..prefix_count]) |prefix| {
                                const score = prefix.score + entry.score - state.penalty - option.cost - self.word_penalty;
                                if (!paths[end + 1].admits(score)) continue;
                                paths[end + 1].add(try extend(arena, prefix, entry.text, score,
                                    prefix.repairs + state.repairs + option.correction, prefix.unresolved, start, end + 1));
                            }
                        }
                    }
                }
                // Cheapest 32 partial words, arrival order on ties (stable).
                std.mem.sort(State, next.items, {}, struct {
                    fn lessThan(_: void, x: State, y: State) bool {
                        return x.penalty < y.penalty;
                    }
                }.lessThan);
                std.mem.swap(std.ArrayList(State), &states, &next);
                states.shrinkRetainingCapacity(@min(states.items.len, max_states));
                if (states.items.len == 0) break;
            }
        }
        return arena.dupe(Candidate, paths[syllables.len].slice());
    }

    fn extend(arena: Allocator, prefix: Candidate, word: []const u8, score: f64, repairs: i32, unresolved: i32, syllable_start: usize, syllable_end: usize) !Candidate {
        const word_units = utf16Len(word);
        const alignment = try arena.alloc(Span, prefix.alignment.len + 1);
        @memcpy(alignment[0..prefix.alignment.len], prefix.alignment);
        alignment[prefix.alignment.len] = .{
            .syllable_start = @intCast(syllable_start),
            .syllable_end = @intCast(syllable_end),
            .char_start = prefix.utf16_len,
            .char_end = prefix.utf16_len + word_units,
        };
        return .{
            .text = try std.mem.concat(arena, u8, &.{ prefix.text, word }),
            .utf16_len = prefix.utf16_len + word_units,
            .score = score,
            .repairs = repairs,
            .unresolved = unresolved,
            .alignment = alignment,
        };
    }
};

/// UTF-16 code units of valid UTF-8 text: one per scalar, two above U+FFFF.
pub fn utf16Len(text: []const u8) u32 {
    var units: u32 = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) units += 1; // lead byte
        if (byte >= 0xF0) units += 1; // 4-byte sequence: surrogate pair
    }
    return units;
}

const testing = std.testing;

const fixture =
    "ㄋㄧˇ\t你\t-5.0\n" ++
    "ㄋㄧˇ\t妳\t-6.0\n" ++
    "ㄏㄠˇ\t好\t-4.0\n" ++
    "ㄋㄧˇ-ㄏㄠˇ\t你好\t-6.0\n" ++
    "ㄏㄠˋ\t號\t-5.5\n" ++
    "ㄕㄥ\t生\t-5.0\n" ++
    "\n";

test "exact syllables prefer the word" {
    const lexicon = try Lexicon.create(testing.allocator, &.{fixture}, "");
    defer lexicon.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try lexicon.decode(arena.allocator(), &.{ .{ .keys = "su", .tone = '3' }, .{ .keys = "cl", .tone = '3' } }, true);
    try testing.expectEqualStrings("你好", out[0].text);
    try testing.expectEqual(@as(f64, -6.0), out[0].score);
    try testing.expectEqual(@as(usize, 1), out[0].alignment.len);
    // 你+好 (-9) shares the text and loses to the word; next is 妳好.
    try testing.expectEqualStrings("妳好", out[1].text);
}

test "toneless input reaches every tone at 0.5" {
    const lexicon = try Lexicon.create(testing.allocator, &.{fixture}, "ㄏㄠˋ\t號\t-1.0\n");
    defer lexicon.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try lexicon.decode(arena.allocator(), &.{.{ .keys = "cl", .tone = null }}, true);
    // The toneless override lifts 號 above 好 only for toneless input.
    try testing.expectEqualStrings("號", out[0].text);
    try testing.expectEqual(@as(f64, -1.5), out[0].score);
    const toned = try lexicon.decode(arena.allocator(), &.{.{ .keys = "cl", .tone = '3' }}, true);
    try testing.expectEqualStrings("好", toned[0].text);
}

test "unknown reading stays raw" {
    const lexicon = try Lexicon.create(testing.allocator, &.{fixture}, "");
    defer lexicon.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try lexicon.decode(arena.allocator(), &.{.{ .keys = "1", .tone = '4' }}, true);
    try testing.expectEqualStrings("ㄅˋ", out[0].text);
    try testing.expectEqual(@as(i32, 1), out[0].unresolved);
}

test "utf16 length" {
    try testing.expectEqual(@as(u32, 2), utf16Len("你好"));
    try testing.expectEqual(@as(u32, 2), utf16Len("𠀀"));
    try testing.expectEqual(@as(u32, 4), utf16Len("a你𠀀"));
}

