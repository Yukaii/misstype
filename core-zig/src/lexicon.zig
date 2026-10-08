//! Lexicon trie and decoder: port of LexiconDecoder
//! (Sources/MisstypeCore/Lexicon.swift). Output must match Swift bit for
//! bit (core-zig/bench/compare.sh, tests/replay).
//!
//! Every decode function allocates its results in the caller's `arena`.
//! Not ported: the dev-only bigram overlay (MISSTYPE_BIGRAM).

const std = @import("std");
const keyboard = @import("keyboard.zig");
const unicode = @import("unicode.zig");
const candidate_mod = @import("candidate.zig");
const composition_mod = @import("composition.zig");
const user_lexicon = @import("user_lexicon.zig");
const channel_mod = @import("channel.zig");
const Syllable = keyboard.Syllable;
const Candidate = candidate_mod.Candidate;
const Span = candidate_mod.Span;
const Range = candidate_mod.Range;
const UserLexicon = user_lexicon.UserLexicon;
const Segment = composition_mod.Segment;
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    text: []const u8,
    score: f64,

    /// Best score first, text ascending (UTF-8 bytes) on ties, as in Swift.
    fn better(_: void, a: Entry, b: Entry) bool {
        return if (a.score == b.score) unicode.lessThan(a.text, b.text) else a.score > b.score;
    }
};

const Node = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Single-syllable nodes only: entries rescored for toneless input
    /// (null = same as `entries`).
    toneless_entries: ?std.ArrayList(Entry) = null,

    fn tonelessOrEntries(self: *const Node) []const Entry {
        return if (self.toneless_entries) |t| t.items else self.entries.items;
    }
};

pub const ReadingId = u32;

/// One reading a syllable may stand for: its cost, repairs counted, and
/// whether it may only appear inside a multi-syllable word.
pub const Option = struct {
    reading: ReadingId,
    cost: f64,
    correction: i32,
    word_only: bool = false,
};

pub const WordOption = struct { text: []const u8, score: f64 };

pub const beam_width = 16;
/// Decode-time entries per node for multi-syllable input.
const decode_entries_per_node = 4;
const max_word_syllables = 8;
const max_states = 32;
/// Longest symbol-only run that can form one syllable.
const max_syllable_keys = 4;

/// A user dictionary word (see user_dictionary.zig).
pub const UserWord = struct { reading: []const u8, text: []const u8, weight: f64 };

pub const Lexicon = struct {
    arena: std.heap.ArenaAllocator,
    /// User dictionary texts and the pristine copies of touched nodes;
    /// reset by every `applyUserDictionary`.
    user_arena: std.heap.ArenaAllocator,
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
    /// Optional per-user substitution costs (null = byte-identical decode).
    channel: ?*const channel_mod.ChannelModel = null,
    /// Added to every generic edit-repair cost (RepairStrength.costOffset).
    repair_cost_offset: f64 = 0,
    /// Repairs also run on syllables that already spell a valid reading.
    repair_valid_readings: bool = false,
    /// Touched nodes and what they held before the user overlay.
    pristine: std.ArrayList(Pristine) = .empty,
    user_word_count: usize = 0,

    const Pristine = struct { node: u32, entries: []Entry, toneless: ?[]Entry };

    /// `tsv` parts are concatenated (lexicon.tsv, local_phrases.tsv); rows
    /// are `reading-reading<TAB>text<TAB>score`. `toneless` rows override a
    /// single char's score when its syllable is typed without a tone.
    pub fn create(gpa: Allocator, tsv: []const []const u8, toneless: []const u8) !*Lexicon {
        const self = try gpa.create(Lexicon);
        self.* = .{ .arena = .init(gpa), .user_arena = .init(gpa) };
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
        self.user_arena.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn splitFields(line: []const u8, fields: *[3][]const u8) bool {
        // Swift's split drops empty fields; tokenize does the same.
        var count: usize = 0;
        var it = std.mem.tokenizeScalar(u8, line, '\t');
        while (it.next()) |field| : (count += 1) {
            if (count == 3) return false;
            fields[count] = field;
        }
        return count == 3;
    }

    fn addRows(self: *Lexicon, tsv: []const u8) !void {
        const a = self.arena.allocator();
        var lines = std.mem.tokenizeScalar(u8, tsv, '\n');
        while (lines.next()) |line| {
            var fields: [3][]const u8 = undefined;
            if (!splitFields(line, &fields)) continue;
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
            const node = try self.walkCreate(parts[0..n]);
            try self.nodes.items[node].entries.append(a, .{ .text = try a.dupe(u8, fields[1]), .score = score });
            self.entry_count += 1;
        }
    }

    /// Trie node for a reading path, created (with its readings) on demand.
    fn walkCreate(self: *Lexicon, parts: []const []const u8) !u32 {
        const a = self.arena.allocator();
        var node: u32 = 0;
        for (parts) |reading| {
            const id = try self.intern(reading);
            const key = (@as(u64, node) << 32) | id;
            const slot = try self.children.getOrPut(a, key);
            if (!slot.found_existing) {
                slot.value_ptr.* = @intCast(self.nodes.items.len);
                try self.nodes.append(a, .{});
            }
            node = slot.value_ptr.*;
        }
        return node;
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
            if (!splitFields(line, &fields)) continue;
            const score = std.fmt.parseFloat(f64, fields[2]) catch continue;
            if (!std.math.isFinite(score)) continue;
            const slot = try overrides.getOrPut(a, fields[0]);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.put(a, fields[1], score);
        }
        var groups = overrides.iterator();
        while (groups.next()) |group| {
            const id = self.reading_ids.get(group.key_ptr.*) orelse continue;
            const child_id = self.children.get(id) orelse continue; // root << 32 == 0
            const node = &self.nodes.items[child_id];
            var rescored: std.ArrayList(Entry) = try .initCapacity(a, node.entries.items.len);
            for (node.entries.items) |entry| {
                rescored.appendAssumeCapacity(.{ .text = entry.text, .score = group.value_ptr.get(entry.text) orelse entry.score });
            }
            std.mem.sort(Entry, rescored.items, {}, Entry.better);
            node.toneless_entries = rescored;
        }
    }

    pub fn readingName(self: *const Lexicon, id: ReadingId) []const u8 {
        return self.reading_names.items[id];
    }

    fn child(self: *const Lexicon, node: u32, reading: ReadingId) ?u32 {
        return self.children.get((@as(u64, node) << 32) | reading);
    }

    fn childNamed(self: *const Lexicon, node: u32, reading: []const u8) ?u32 {
        const id = self.reading_ids.get(reading) orelse return null;
        return self.child(node, id);
    }

    // MARK: - Reading options

    const Scored = struct {
        list: std.ArrayList(Option) = .empty,

        fn add(self: *Scored, arena: Allocator, reading: ReadingId, cost: f64, correction: i32, word_only: bool) !void {
            for (self.list.items) |*existing| {
                if (existing.reading != reading) continue;
                if (existing.cost <= cost) return;
                existing.* = .{ .reading = reading, .cost = cost, .correction = correction, .word_only = word_only };
                return;
            }
            try self.list.append(arena, .{ .reading = reading, .cost = cost, .correction = correction, .word_only = word_only });
        }
    };

    /// Reading options of one syllable, cheapest first (at most 16): exact
    /// 0, toneless 0.5, explicit-tone mismatch 4.0, and with `fuzzy` the
    /// edit repairs (transpose 4, substitute/phonetic 5, insert/delete 6,
    /// generic tiers shifted by `repair_cost_offset`).
    pub fn alternatives(self: *const Lexicon, arena: Allocator, syllable: Syllable, fuzzy: bool, tone_tolerance: bool) ![]Option {
        var buf: [Syllable.max_reading_bytes]u8 = undefined;
        var base_buf: [Syllable.max_reading_bytes]u8 = undefined;
        const reading = syllable.reading(&buf);
        const variants = self.toneless.get(keyboard.withoutTone(reading, &base_buf));
        var scored: Scored = .{};
        if (syllable.tone != null) {
            const exact = self.reading_ids.get(reading);
            if (exact) |id| try scored.add(arena, id, 0, 0, false);
            if (tone_tolerance) if (variants) |list| for (list.items) |variant| {
                if (variant != exact) try scored.add(arena, variant, 4.0, 1, false);
            };
        } else if (variants) |list| {
            for (list.items) |variant| try scored.add(arena, variant, 0.5, 0, false);
        }
        if (fuzzy) try self.repairs(arena, syllable, &scored);
        std.mem.sort(Option, scored.list.items, self, struct {
            fn lessThan(lexicon: *const Lexicon, x: Option, y: Option) bool {
                return if (x.cost == y.cost)
                    unicode.lessThan(lexicon.readingName(x.reading), lexicon.readingName(y.reading))
                else
                    x.cost < y.cost;
            }
        }.lessThan);
        scored.list.shrinkRetainingCapacity(@min(scored.list.items.len, beam_width));
        return scored.list.items;
    }

    const Repair = struct {
        lexicon: *const Lexicon,
        arena: Allocator,
        scored: *Scored,
        tone: ?u8,
        offset: f64,

        fn consider(r: Repair, keys: []const u8, cost_: f64, generic: bool, word_only: bool) !void {
            const cost = if (generic) cost_ + r.offset else cost_;
            var buf: [Syllable.max_reading_bytes]u8 = undefined;
            const repaired = (Syllable{ .keys = keys, .tone = r.tone }).reading(&buf);
            if (r.tone != null) {
                if (r.lexicon.reading_ids.get(repaired)) |id| try r.scored.add(r.arena, id, cost, 1, word_only);
                return;
            }
            var base_buf: [Syllable.max_reading_bytes]u8 = undefined;
            const list = r.lexicon.toneless.get(keyboard.withoutTone(repaired, &base_buf)) orelse return;
            for (list.items) |variant| try r.scored.add(r.arena, variant, cost, 1, word_only);
        }
    };

    fn repairs(self: *const Lexicon, arena: Allocator, syllable: Syllable, scored: *Scored) !void {
        const r: Repair = .{ .lexicon = self, .arena = arena, .scored = scored, .tone = syllable.tone, .offset = self.repair_cost_offset };
        const toneless_probe = syllable.tone == null;
        const base = syllable.keys;
        const keys = try arena.alloc(u8, base.len + 1);
        // Snapshot before phonetic confusions: the edit tiers stay gated on
        // no clean reading, phonetic confusions ride along always.
        const clean_empty = scored.list.items.len == 0;
        for (base, 0..) |typed, index| {
            const personal = if (self.channel) |c| c.substitutes(typed) else &.{};
            for (keyboard.phoneticConfusions(typed)) |replacement| {
                if (channel_mod.ChannelModel.has(personal, replacement)) continue;
                @memcpy(keys[0..base.len], base);
                keys[index] = replacement;
                try r.consider(keys[0..base.len], 5, true, false);
            }
            for (personal) |sub| {
                @memcpy(keys[0..base.len], base);
                keys[index] = sub.intended;
                try r.consider(keys[0..base.len], sub.cost(), false, false);
            }
        }
        if (clean_empty or self.repair_valid_readings) {
            const word_only = !clean_empty;
            var ordered_buf: [3]u8 = undefined;
            if (!toneless_probe) if (keyboard.slotOrdered(base, &ordered_buf)) |ordered| {
                try r.consider(ordered, 4, true, word_only);
            };
            for (base, 0..) |typed, index| {
                for (keyboard.neighbors(typed)) |replacement| {
                    @memcpy(keys[0..base.len], base);
                    keys[index] = replacement;
                    try r.consider(keys[0..base.len], 5, true, word_only);
                }
                if (index + 1 < base.len) {
                    @memcpy(keys[0..base.len], base);
                    std.mem.swap(u8, &keys[index], &keys[index + 1]);
                    try r.consider(keys[0..base.len], 4, true, word_only);
                }
                if (base.len > 1) {
                    @memcpy(keys[0..index], base[0..index]);
                    @memcpy(keys[index .. base.len - 1], base[index + 1 ..]);
                    try r.consider(keys[0 .. base.len - 1], 6, true, word_only);
                }
            }
        }
        // Dropped key that still spells a valid reading (toned only).
        if (!clean_empty and !toneless_probe) {
            for (try keyboard.slotCompletions(arena, base)) |completed| {
                try r.consider(completed, 6, true, true);
            }
        }
        // Insertion: the most speculative class, only on no clean reading.
        if (clean_empty and base.len < max_syllable_keys) {
            for (0..base.len + 1) |position| {
                for (keyboard.symbol_keys) |symbol| {
                    @memcpy(keys[0..position], base[0..position]);
                    keys[position] = symbol;
                    @memcpy(keys[position + 1 .. base.len + 1], base[position..]);
                    try r.consider(keys[0 .. base.len + 1], 6, true, false);
                }
            }
        }
    }

    fn cheapest(options: []const Option) ?f64 {
        var best: ?f64 = null;
        for (options) |o| {
            if (best == null or o.cost < best.?) best = o.cost;
        }
        return best;
    }

    // MARK: - Segmentation

    const Partial = struct { syllables: []const Syllable, cost: f64 };

    /// Split pending symbol keys into syllable hypotheses, cheapest first
    /// (at most 12).
    pub fn segmentations(self: *const Lexicon, arena: Allocator, keys: []const u8, fuzzy: bool, tone_tolerance: bool) ![]const []const Syllable {
        if (keys.len == 0) {
            const out = try arena.alloc([]const Syllable, 1);
            out[0] = &.{};
            return out;
        }
        const lattice = try arena.alloc(std.ArrayList(Partial), keys.len + 1);
        for (lattice) |*l| l.* = .empty;
        try lattice[0].append(arena, .{ .syllables = &.{}, .cost = 0 });
        for (0..keys.len) |start| {
            sortPartials(lattice[start].items);
            lattice[start].shrinkRetainingCapacity(@min(lattice[start].items.len, 24));
            if (lattice[start].items.len == 0) continue;
            for (1..@min(max_syllable_keys, keys.len - start) + 1) |len| {
                const slice = keys[start .. start + len];
                const all_symbols = for (slice) |k| {
                    if (!keyboard.isSymbol(k)) break false;
                } else true;
                if (!all_symbols) continue;
                const probe = Syllable{ .keys = slice, .tone = null };
                const best = cheapest(try self.alternatives(arena, probe, fuzzy, tone_tolerance)) orelse continue;
                const prefixes = lattice[start].items[0..@min(lattice[start].items.len, 8)];
                for (prefixes) |prefix| {
                    const syllables = try arena.alloc(Syllable, prefix.syllables.len + 1);
                    @memcpy(syllables[0..prefix.syllables.len], prefix.syllables);
                    syllables[prefix.syllables.len] = probe;
                    try lattice[start + len].append(arena, .{ .syllables = syllables, .cost = prefix.cost + best });
                    if (lattice[start + len].items.len >= 64) break;
                }
            }
        }
        const last = lattice[keys.len].items;
        sortPartials(last);
        const n = @min(last.len, 12);
        const out = try arena.alloc([]const Syllable, n);
        for (last[0..n], out) |p, *o| o.* = p.syllables;
        return out;
    }

    fn sortPartials(items: []Partial) void {
        std.mem.sort(Partial, items, {}, struct {
            fn lt(_: void, a: Partial, b: Partial) bool {
                return a.cost < b.cost;
            }
        }.lt);
    }

    /// Live conversion: how many leading pending keys to convert now.
    pub fn livePendingCut(self: *const Lexicon, arena: Allocator, keys: []const u8, tone_tolerance: bool) !usize {
        if (keys.len == 0) return 0;
        var cut = keys.len;
        while (true) : (cut -= 1) {
            if (try self.clean(arena, keys[0..cut], tone_tolerance)) return cut;
            if (cut == 0 or cut == keys.len -| 3) break;
        }
        for (1..@min(max_syllable_keys, keys.len) + 1) |count| {
            if (try self.clean(arena, keys[0..count], tone_tolerance)) return keys.len;
        }
        return 0;
    }

    fn clean(self: *const Lexicon, arena: Allocator, keys: []const u8, tone_tolerance: bool) !bool {
        return keys.len == 0 or (try self.segmentations(arena, keys, false, tone_tolerance)).len > 0;
    }

    // MARK: - Word lists

    /// Distinct word options covering exactly `span` (best first; 64 for one
    /// syllable, else 16).
    pub fn segmentOptions(self: *const Lexicon, arena: Allocator, syllables: []const Syllable, span: Range, fuzzy: bool, tone_tolerance: bool) ![]WordOption {
        if (span.isEmpty() or span.len() > 8 or span.end > syllables.len) return &.{};
        const cap: usize = if (span.len() == 1) 64 else 16;
        const options = try arena.alloc([]Option, syllables.len);
        for (span.start..span.end) |i| options[i] = try self.alternatives(arena, syllables[i], fuzzy, tone_tolerance);
        var found: std.StringArrayHashMapUnmanaged(f64) = .empty;
        const Walker = struct {
            lexicon: *const Lexicon,
            arena: Allocator,
            options: []const []Option,
            span: Range,
            found: *std.StringArrayHashMapUnmanaged(f64),

            fn walk(w: @This(), node: u32, index: usize, penalty: f64) !void {
                if (index == w.span.end) {
                    for (w.lexicon.nodes.items[node].entries.items) |entry| {
                        const score = entry.score - penalty;
                        const slot = try w.found.getOrPut(w.arena, entry.text);
                        if (slot.found_existing and slot.value_ptr.* >= score) continue;
                        slot.value_ptr.* = score;
                    }
                    return;
                }
                for (w.options[index]) |o| {
                    if (o.word_only and w.span.len() == 1) continue;
                    const next = w.lexicon.child(node, o.reading) orelse continue;
                    try w.walk(next, index + 1, penalty + o.cost);
                }
            }
        };
        try (Walker{ .lexicon = self, .arena = arena, .options = options, .span = span, .found = &found }).walk(0, span.start, 0);
        const out = try arena.alloc(WordOption, found.count());
        for (found.keys(), found.values(), out) |text, score, *o| o.* = .{ .text = text, .score = score };
        std.mem.sort(WordOption, out, {}, struct {
            fn lt(_: void, a: WordOption, b: WordOption) bool {
                return if (a.score == b.score) unicode.lessThan(a.text, b.text) else a.score > b.score;
            }
        }.lt);
        return out[0..@min(out.len, cap)];
    }

    /// The toned readings (hyphen-joined trie path) under which `text` is a
    /// dictionary word over `span`; the cheapest path the keys admit.
    pub fn readingsOf(self: *const Lexicon, arena: Allocator, text: []const u8, syllables: []const Syllable, span: Range, fuzzy: bool, tone_tolerance: bool) !?[]const u8 {
        if (span.isEmpty() or span.len() > 8 or span.end > syllables.len) return null;
        const options = try arena.alloc([]Option, syllables.len);
        for (span.start..span.end) |i| options[i] = try self.alternatives(arena, syllables[i], fuzzy, tone_tolerance);
        var path: [8]ReadingId = undefined;
        var best_path: [8]ReadingId = undefined;
        var best: ?f64 = null;
        const Walker = struct {
            lexicon: *const Lexicon,
            options: []const []Option,
            span: Range,
            text: []const u8,
            path: *[8]ReadingId,
            best_path: *[8]ReadingId,
            best: *?f64,

            fn walk(w: @This(), node: u32, index: usize, penalty: f64) void {
                if (index == w.span.end) {
                    const has = for (w.lexicon.nodes.items[node].entries.items) |e| {
                        if (unicode.equal(e.text, w.text)) break true;
                    } else false;
                    if (has and (w.best.* == null or penalty < w.best.*.?)) {
                        w.best.* = penalty;
                        w.best_path.* = w.path.*;
                    }
                    return;
                }
                for (w.options[index]) |o| {
                    const next = w.lexicon.child(node, o.reading) orelse continue;
                    w.path[index - w.span.start] = o.reading;
                    w.walk(next, index + 1, penalty + o.cost);
                }
            }
        };
        (Walker{ .lexicon = self, .options = options, .span = span, .text = text, .path = &path, .best_path = &best_path, .best = &best }).walk(0, span.start, 0);
        if (best == null) return null;
        var out: std.ArrayList(u8) = .empty;
        for (best_path[0..span.len()], 0..) |id, i| {
            if (i > 0) try out.append(arena, '-');
            try out.appendSlice(arena, self.readingName(id));
        }
        return out.items;
    }

    // MARK: - Composition decoding

    /// Split a tone-terminated run that is not viable as one syllable.
    fn repairComplete(self: *const Lexicon, arena: Allocator, syllable: Syllable, tone_tolerance: bool) ![]const []const Syllable {
        var out: std.ArrayList([]const Syllable) = .empty;
        // Swift passes no toneTolerance here: the default (true) applies.
        if ((try self.alternatives(arena, syllable, false, true)).len > 0) {
            try out.append(arena, try one(arena, syllable));
            return out.items;
        }
        const keys = syllable.keys;
        if (keys.len <= 1) return out.items;
        var by_tail: std.ArrayList([]const []const Syllable) = .empty;
        for (1..@min(max_syllable_keys, keys.len - 1) + 1) |tail_len| {
            const tail = Syllable{ .keys = keys[keys.len - tail_len ..], .tone = syllable.tone };
            if ((try self.alternatives(arena, tail, false, tone_tolerance)).len == 0) continue;
            const leads = try self.segmentations(arena, keys[0 .. keys.len - tail_len], false, tone_tolerance);
            const options = try arena.alloc([]const Syllable, @min(leads.len, 6));
            for (leads[0..options.len], options) |lead, *o| o.* = try concat(arena, lead, &.{tail});
            try by_tail.append(arena, options);
        }
        const reordered = try self.slotReorderable(arena, syllable, tone_tolerance);
        const cap: usize = if (reordered) 11 else 12;
        ranks: for (0..6) |rank| {
            for (by_tail.items) |options| {
                if (rank >= options.len) continue;
                try out.append(arena, options[rank]);
                if (out.items.len >= cap) break :ranks;
            }
        }
        if (out.items.len == 0) {
            if (keys.len <= max_syllable_keys) try out.append(arena, try one(arena, syllable));
            const max_tail: usize = @min(3, keys.len - 1);
            for (1..max_tail + 1) |tail_len| {
                const leads = try self.segmentations(arena, keys[0 .. keys.len - tail_len], false, tone_tolerance);
                if (leads.len == 0) continue;
                try out.append(arena, try concat(arena, leads[0], &.{.{ .keys = keys[keys.len - tail_len ..], .tone = syllable.tone }}));
            }
        }
        if (reordered) {
            const has = for (out.items) |o| {
                if (o.len == 1 and o[0].eql(syllable)) break true;
            } else false;
            if (!has) try out.append(arena, try one(arena, syllable));
        }
        return out.items;
    }

    fn one(arena: Allocator, syllable: Syllable) ![]const Syllable {
        const out = try arena.alloc(Syllable, 1);
        out[0] = syllable;
        return out;
    }

    fn concat(arena: Allocator, a: []const Syllable, b: []const Syllable) ![]const Syllable {
        const out = try arena.alloc(Syllable, a.len + b.len);
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        return out;
    }

    /// Whether the syllable's keys, put in slot order, spell a valid reading.
    pub fn slotReorderable(self: *const Lexicon, arena: Allocator, syllable: Syllable, tone_tolerance: bool) !bool {
        var buf: [3]u8 = undefined;
        const ordered = keyboard.slotOrdered(syllable.keys, &buf) orelse return false;
        const keys = try arena.dupe(u8, ordered);
        return (try self.alternatives(arena, .{ .keys = keys, .tone = syllable.tone }, false, tone_tolerance)).len > 0;
    }

    pub const DecodeOptions = struct {
        fuzzy: bool = true,
        tone_tolerance: bool = true,
        user_lexicon: ?*const UserLexicon = null,
        locked: ?*const UserLexicon = null,
    };

    /// Decode tone-terminated syllables plus an unsegmented pending key run.
    pub fn decodeComposition(self: *const Lexicon, arena: Allocator, complete: []const Syllable, pending: []const u8, opts: DecodeOptions) ![]Candidate {
        const tone_tolerance = opts.tone_tolerance;
        var expanded: std.ArrayList([]const Syllable) = .empty;
        var expanded_cost: std.ArrayList(f64) = .empty;
        try expanded.append(arena, &.{});
        try expanded_cost.append(arena, 0);
        const Next = struct { syllables: []const Syllable, cost: f64, order: usize };
        for (complete) |syllable| {
            const options = try self.repairComplete(arena, syllable, tone_tolerance);
            const chosen = if (options.len == 0) try arena.dupe([]const Syllable, &.{try one(arena, syllable)}) else options;
            const costs = try arena.alloc(f64, chosen.len);
            for (chosen, costs) |option, *c| c.* = try self.splitCost(arena, option, tone_tolerance);
            var next: std.ArrayList(Next) = .empty;
            for (expanded.items, 0..) |prefix, p| {
                for (chosen, 0..) |option, o| {
                    try next.append(arena, .{ .syllables = try concat(arena, prefix, option), .cost = expanded_cost.items[p] + costs[o], .order = next.items.len });
                }
            }
            std.mem.sort(Next, next.items, {}, struct {
                fn lt(_: void, a: Next, b: Next) bool {
                    return if (a.cost == b.cost) a.order < b.order else a.cost < b.cost;
                }
            }.lt);
            expanded.clearRetainingCapacity();
            expanded_cost.clearRetainingCapacity();
            for (next.items[0..@min(next.items.len, 12)]) |n| {
                try expanded.append(arena, n.syllables);
                try expanded_cost.append(arena, n.cost);
            }
        }
        var segment_options: []const []const Syllable = &.{&.{}};
        if (pending.len > 0) {
            segment_options = try self.segmentations(arena, pending, false, tone_tolerance);
            if (segment_options.len == 0 and opts.fuzzy) {
                segment_options = try self.segmentations(arena, pending, true, tone_tolerance);
            }
            if (segment_options.len == 0) {
                return self.decode(arena, try concat(arena, complete, &.{.{ .keys = pending, .tone = null }}), opts);
            }
        }
        var merger: Merger = .{ .lexicon = self, .arena = arena, .opts = opts };
        for (expanded.items) |prefix| {
            for (segment_options) |segmentation| {
                if (merger.budget <= 0) break;
                try merger.merge(try concat(arena, prefix, segmentation));
            }
        }
        // Repair track: when the best merge so far is not fully clean, also
        // decode repair-inclusive segmentations the clean track never had.
        const top_clean = if (merger.merged.items.len > 0)
            merger.merged.items[0].unresolved == 0 and merger.merged.items[0].repairs == 0
        else
            false;
        if (opts.fuzzy and pending.len > 0 and !top_clean) {
            var clean_forms: std.StringHashMapUnmanaged(void) = .empty;
            for (segment_options) |s| try clean_forms.put(arena, try form(arena, s), {});
            var extra: usize = 0;
            for (try self.segmentations(arena, pending, true, tone_tolerance)) |segmentation| {
                if (extra >= 6 or merger.budget <= 0) break;
                if (clean_forms.contains(try form(arena, segmentation))) continue;
                extra += 1;
                for (expanded.items[0..@min(expanded.items.len, 3)]) |prefix| {
                    if (merger.budget <= 0) break;
                    try merger.merge(try concat(arena, prefix, segmentation));
                }
            }
        }
        return merger.merged.items;
    }

    /// Readings joined by " " (Swift's segmentation identity).
    fn form(arena: Allocator, syllables: []const Syllable) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var buf: [Syllable.max_reading_bytes]u8 = undefined;
        for (syllables, 0..) |s, i| {
            if (i > 0) try out.append(arena, ' ');
            try out.appendSlice(arena, s.reading(&buf));
        }
        return out.items;
    }

    fn splitCost(self: *const Lexicon, arena: Allocator, option: []const Syllable, tone_tolerance: bool) !f64 {
        var total: f64 = 0;
        for (option) |syllable| {
            const best = cheapest(try self.alternatives(arena, syllable, false, tone_tolerance));
            total = total + (best orelse if (try self.slotReorderable(arena, syllable, tone_tolerance)) @as(f64, 4) else 6);
        }
        return total;
    }

    const Merger = struct {
        lexicon: *const Lexicon,
        arena: Allocator,
        opts: DecodeOptions,
        merged: std.ArrayList(Candidate) = .empty,
        budget: i32 = 12,

        fn merge(m: *Merger, syllables: []const Syllable) !void {
            for (try m.lexicon.decode(m.arena, syllables, m.opts)) |c| {
                var skip = false;
                for (m.merged.items, 0..) |existing, i| {
                    if (!unicode.equal(existing.text, c.text)) continue;
                    if (existing.score >= c.score) {
                        skip = true;
                    } else {
                        _ = m.merged.orderedRemove(i);
                    }
                    break;
                }
                if (skip) continue;
                try m.merged.append(m.arena, c);
                std.mem.sort(Candidate, m.merged.items, {}, struct {
                    fn lt(_: void, a: Candidate, b: Candidate) bool {
                        return candidate_mod.better(a, b);
                    }
                }.lt);
                m.merged.shrinkRetainingCapacity(@min(m.merged.items.len, beam_width));
            }
            m.budget -= 1;
        }
    };

    /// Decode an ordered mixed span: Zhuyin runs convert, punctuation and
    /// Latin pass through in place.
    pub fn decodeSegments(self: *const Lexicon, arena: Allocator, segments: []const Segment, pending: []const u8, opts: DecodeOptions) ![]Candidate {
        var runs: std.ArrayList(std.ArrayList(Syllable)) = .empty;
        try runs.append(arena, .empty);
        var seps: std.ArrayList([]const u8) = .empty;
        for (segments) |segment| switch (segment) {
            .syllable => |s| try runs.items[runs.items.len - 1].append(arena, s),
            .punct, .latin => |mark| {
                try runs.append(arena, .empty);
                try seps.append(arena, mark);
            },
        };
        const run_tops = try arena.alloc([]const Candidate, runs.items.len);
        for (runs.items, 0..) |run, index| {
            const trailing = index == runs.items.len - 1;
            var run_opts = opts;
            var pins: ?UserLexicon = null;
            if (opts.locked) |locked| pins = try locked.pinsForRun(index);
            defer if (pins) |*p| p.deinit();
            run_opts.locked = if (pins) |*p| p else null;
            const tops = try self.decodeComposition(arena, run.items, if (trailing) pending else &.{}, run_opts);
            run_tops[index] = if (tops.len == 0) try arena.dupe(Candidate, &.{Candidate.empty()}) else tops;
        }
        const base = try arena.alloc(Candidate, run_tops.len);
        for (run_tops, base) |tops, *b| b.* = tops[0];
        var out: std.ArrayList(Candidate) = .empty;
        try out.append(arena, try render(arena, base, seps.items));
        outer: for (run_tops, 0..) |tops, index| {
            for (tops[1..]) |alt| {
                const picks = try arena.dupe(Candidate, base);
                picks[index] = alt;
                try out.append(arena, try render(arena, picks, seps.items));
                if (out.items.len >= 64) break :outer;
            }
        }
        std.mem.sort(Candidate, out.items, {}, struct {
            fn lt(_: void, a: Candidate, b: Candidate) bool {
                return candidate_mod.better(a, b);
            }
        }.lt);
        return out.items[0..@min(out.items.len, beam_width)];
    }

    fn render(arena: Allocator, picks: []const Candidate, seps: []const []const u8) !Candidate {
        var text: std.ArrayList(u8) = .empty;
        var utf16_len: u32 = 0;
        var score: f64 = 0;
        var repairs_: i32 = 0;
        var unresolved: i32 = 0;
        var alignment: std.ArrayList(Span) = .empty;
        var syllables: std.ArrayList(Syllable) = .empty;
        var runs: std.ArrayList(Range) = .empty;
        var syl_base: u32 = 0;
        for (picks, 0..) |pick, index| {
            const char_base = utf16_len;
            for (pick.alignment) |span| {
                try alignment.append(arena, .{
                    .syllables = .{ .start = span.syllables.start + syl_base, .end = span.syllables.end + syl_base },
                    .chars = .{ .start = span.chars.start + char_base, .end = span.chars.end + char_base },
                });
            }
            const consumed: u32 = if (pick.alignment.len > 0) pick.alignment[pick.alignment.len - 1].syllables.end else 0;
            try runs.append(arena, .{ .start = syl_base, .end = syl_base + consumed });
            syl_base += consumed;
            try syllables.appendSlice(arena, pick.syllables);
            try text.appendSlice(arena, pick.text);
            utf16_len += pick.utf16_len;
            score += pick.score;
            repairs_ += pick.repairs;
            unresolved += pick.unresolved;
            if (index < seps.len) {
                try text.appendSlice(arena, seps[index]);
                utf16_len += unicode.utf16Len(seps[index]);
            }
        }
        return .{
            .text = text.items,
            .utf16_len = utf16_len,
            .score = score,
            .repairs = repairs_,
            .unresolved = unresolved,
            .alignment = alignment.items,
            .syllables = syllables.items,
            .runs = runs.items,
        };
    }

    /// Top candidates for syllables, best first.
    pub fn decode(self: *const Lexicon, arena: Allocator, syllables: []const Syllable, opts: DecodeOptions) ![]Candidate {
        if (syllables.len == 0) return &.{};
        const options = try arena.alloc([]Option, syllables.len);
        for (syllables, options) |syllable, *out| out.* = try self.alternatives(arena, syllable, opts.fuzzy, opts.tone_tolerance);
        return self.decodeOptions(arena, syllables, options, opts.user_lexicon, opts.locked);
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
                if (!unicode.equal(existing.text, candidate.text)) continue;
                if (existing.score >= candidate.score) return;
                std.mem.copyForwards(Candidate, beam.items[i .. beam.len - 1], beam.items[i + 1 .. beam.len]);
                beam.len -= 1;
                break;
            }
            var position = beam.len;
            for (beam.slice(), 0..) |existing, i| {
                if (candidate_mod.better(candidate, existing)) {
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

    const State = struct { node: u32, penalty: f64, repairs: i32, depth: u8, readings: [max_word_syllables]ReadingId };

    /// Decode with caller-supplied reading options per syllable.
    pub fn decodeOptions(self: *const Lexicon, arena: Allocator, syllables: []const Syllable, options: []const []Option, user_lexicon_: ?*const UserLexicon, locked: ?*const UserLexicon) ![]Candidate {
        if (syllables.len == 0 or options.len != syllables.len) return &.{};
        const context_rules = if (user_lexicon_) |u| try u.contextRules(arena) else null;
        const settled_units = if (locked) |l| try l.settledUnits(arena) else null;
        const locked_nonempty = if (locked) |l| !l.isEmpty() else false;
        const paths = try arena.alloc(Beam, syllables.len + 1);
        for (paths) |*beam| beam.* = .{};
        paths[0].add(Candidate.empty());
        var states: std.ArrayList(State) = .empty;
        var next: std.ArrayList(State) = .empty;
        var span_key: std.ArrayList(u8) = .empty;
        var pin_key: std.ArrayList(u8) = .empty;
        var previous_words: [beam_width][]const u8 = undefined;
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
            if (context_rules != null) {
                for (prefixes[0..prefix_count], 0..) |prefix, i| {
                    previous_words[i] = "";
                    if (prefix.alignment.len == 0) continue;
                    const last = prefix.alignment[prefix.alignment.len - 1];
                    if (last.chars.end > prefix.utf16_len) continue;
                    previous_words[i] = try unicode.utf16Slice(arena, prefix.text, last.chars.start, last.chars.end);
                }
            }
            states.clearRetainingCapacity();
            try states.append(arena, .{ .node = 0, .penalty = 0, .repairs = 0, .depth = 0, .readings = undefined });
            for (start..@min(syllables.len, start + max_word_syllables)) |end| {
                next.clearRetainingCapacity();
                for (states.items) |state| {
                    for (options[end]) |option| {
                        const child_node = self.child(state.node, option.reading) orelse continue;
                        var grown = State{ .node = child_node, .penalty = state.penalty + option.cost, .repairs = state.repairs + option.correction, .depth = state.depth + 1, .readings = state.readings };
                        grown.readings[state.depth] = option.reading;
                        try next.append(arena, grown);
                        if (option.word_only and end == start) continue;
                        // Single-syllable inputs ARE homophone browsing: walk
                        // the full node. Longer spans pay per extra entry.
                        const node = &self.nodes.items[child_node];
                        const entries = if (end == start and syllables[start].tone == null)
                            node.tonelessOrEntries()
                        else
                            node.entries.items;
                        const cap: usize = if (syllables.len == 1) entries.len else decode_entries_per_node;
                        span_key.clearRetainingCapacity();
                        for (grown.readings[0..grown.depth]) |id| {
                            const s = span_key.items.len;
                            try span_key.appendSlice(arena, self.readingName(id));
                            span_key.shrinkRetainingCapacity(s + keyboard.withoutTone(span_key.items[s..], span_key.items[s..]).len);
                        }
                        const rules: ?[]const user_lexicon.ContextRule = if (context_rules) |cr| (if (cr.get(span_key.items)) |list| list.items else null) else null;
                        for (entries, 0..) |entry, rank| {
                            // The cap trims the beam, never a user's pick.
                            if (rank >= cap) {
                                if (!locked_nonempty) break;
                                if (!locked.?.hasPin(span_key.items, entry.text)) continue;
                            }
                            const legacy_pinned = if (locked) |l| l.contains(span_key.items, entry.text) else false;
                            const learned: f64 = if (end > start or syllables.len == 1)
                                (if (user_lexicon_) |u| u.bonus(span_key.items, entry.text) else 0)
                            else
                                0;
                            for (prefixes[0..prefix_count], 0..) |prefix, index| {
                                var pinned = legacy_pinned;
                                if (!pinned) if (locked) |l| {
                                    pin_key.clearRetainingCapacity();
                                    try pin_key.print(arena, "{d}@{s}", .{ prefix.utf16_len, span_key.items });
                                    pinned = l.contains(pin_key.items, entry.text);
                                };
                                var contextual: f64 = 0;
                                if (rules) |list| {
                                    for (list) |rule| {
                                        if (unicode.equal(rule.text, entry.text) and unicode.equal(rule.previous, previous_words[index])) {
                                            contextual = rule.bonus;
                                            break;
                                        }
                                    }
                                }
                                var settled_hits: f64 = 0;
                                if (settled_units) |units| {
                                    var offset: i64 = prefix.utf16_len;
                                    var it = Utf16Iterator{ .text = entry.text };
                                    while (it.next()) |unit| : (offset += 1) {
                                        if (units.get(offset)) |want| {
                                            if (want == unit) settled_hits += 1;
                                        }
                                    }
                                }
                                const pin_term: f64 = if (pinned) user_lexicon.pin_bonus else 0;
                                const boost = learned + contextual + pin_term + settled_hits * user_lexicon.pin_bonus;
                                const score = prefix.score + entry.score - state.penalty - option.cost + boost - self.word_penalty;
                                if (!paths[end + 1].admits(score)) continue;
                                paths[end + 1].add(try extend(arena, prefix, entry.text, score, prefix.repairs + state.repairs + option.correction, prefix.unresolved, start, end + 1));
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
        const final = paths[syllables.len].slice();
        const out = try arena.alloc(Candidate, final.len);
        const runs = try arena.alloc(Range, 1);
        runs[0] = Range.of(0, syllables.len);
        for (final, out) |c, *o| {
            o.* = c;
            o.syllables = syllables;
            o.runs = runs;
        }
        return out;
    }

    fn extend(arena: Allocator, prefix: Candidate, word: []const u8, score: f64, repairs_: i32, unresolved: i32, syllable_start: usize, syllable_end: usize) !Candidate {
        const word_units = unicode.utf16Len(word);
        const alignment = try arena.alloc(Span, prefix.alignment.len + 1);
        @memcpy(alignment[0..prefix.alignment.len], prefix.alignment);
        alignment[prefix.alignment.len] = .{
            .syllables = Range.of(syllable_start, syllable_end),
            .chars = .{ .start = prefix.utf16_len, .end = prefix.utf16_len + word_units },
        };
        return .{
            .text = try std.mem.concat(arena, u8, &.{ prefix.text, word }),
            .utf16_len = prefix.utf16_len + word_units,
            .score = score,
            .repairs = repairs_,
            .unresolved = unresolved,
            .alignment = alignment,
        };
    }

    // MARK: - User dictionary overlay

    /// Replaces the user overlay: added words become trie entries (new
    /// paths and readings included), excluded words disappear from their
    /// node. Empty restores the built-in lexicon exactly. Readings and nodes
    /// a word introduced stay (empty), as in Swift.
    pub fn applyUserDictionary(self: *Lexicon, added: []const UserWord, excluded: []const UserWord) !void {
        const a = self.arena.allocator();
        for (self.pristine.items) |saved| {
            const node = &self.nodes.items[saved.node];
            node.entries.clearRetainingCapacity();
            try node.entries.appendSlice(a, saved.entries);
            if (saved.toneless) |t| {
                node.toneless_entries.?.clearRetainingCapacity();
                try node.toneless_entries.?.appendSlice(a, t);
            } else node.toneless_entries = null;
        }
        self.pristine = .empty;
        _ = self.user_arena.reset(.retain_capacity);
        self.user_word_count = 0;
        if (added.len == 0 and excluded.len == 0) return;
        const u = self.user_arena.allocator();
        var touched: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (added) |word| {
            var parts: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeScalar(u8, word.reading, '-');
            while (it.next()) |p| try parts.append(u, p);
            const node_id = try self.walkCreate(parts.items);
            try self.touch(&touched, node_id);
            const node = &self.nodes.items[node_id];
            const text = try u.dupe(u8, word.text);
            removeText(&node.entries, text);
            try node.entries.append(a, .{ .text = text, .score = word.weight });
            std.mem.sort(Entry, node.entries.items, {}, Entry.better);
            if (node.toneless_entries) |*t| {
                removeText(t, text);
                try t.append(a, .{ .text = text, .score = word.weight });
                std.mem.sort(Entry, t.items, {}, Entry.better);
            }
            self.user_word_count += 1;
        }
        for (excluded) |word| {
            var node_id: ?u32 = 0;
            var it = std.mem.tokenizeScalar(u8, word.reading, '-');
            while (it.next()) |p| {
                node_id = if (node_id) |n| self.childNamed(n, p) else null;
            }
            const n = node_id orelse continue;
            const node = &self.nodes.items[n];
            const has = for (node.entries.items) |e| {
                if (unicode.equal(e.text, word.text)) break true;
            } else false;
            if (!has) continue;
            try self.touch(&touched, n);
            removeText(&node.entries, word.text);
            if (node.toneless_entries) |*t| removeText(t, word.text);
        }
    }

    fn touch(self: *Lexicon, touched: *std.AutoHashMapUnmanaged(u32, void), node_id: u32) !void {
        const u = self.user_arena.allocator();
        if ((try touched.getOrPut(u, node_id)).found_existing) return;
        const node = &self.nodes.items[node_id];
        try self.pristine.append(u, .{
            .node = node_id,
            .entries = try u.dupe(Entry, node.entries.items),
            .toneless = if (node.toneless_entries) |t| try u.dupe(Entry, t.items) else null,
        });
    }

    fn removeText(list: *std.ArrayList(Entry), text: []const u8) void {
        var i: usize = 0;
        while (i < list.items.len) {
            if (unicode.equal(list.items[i].text, text)) {
                _ = list.orderedRemove(i);
            } else i += 1;
        }
    }
};

/// UTF-16 units of UTF-8 text.
pub const Utf16Iterator = struct {
    text: []const u8,
    i: usize = 0,
    low: ?u16 = null,

    pub fn next(self: *Utf16Iterator) ?u16 {
        if (self.low) |l| {
            self.low = null;
            return l;
        }
        if (self.i >= self.text.len) return null;
        const width = unicode.seqLen(self.text[self.i]);
        const end = @min(self.i + width, self.text.len);
        const scalar = std.unicode.utf8Decode(self.text[self.i..end]) catch 0xFFFD;
        self.i = end;
        if (scalar >= 0x10000) {
            const v = scalar - 0x10000;
            self.low = @intCast(0xDC00 + (v & 0x3FF));
            return @intCast(0xD800 + (v >> 10));
        }
        return @intCast(scalar);
    }
};

const testing = std.testing;

const fixture =
    "ㄋㄧˇ\t你\t-5.0\n" ++
    "ㄋㄧˇ\t妳\t-6.0\n" ++
    "ㄏㄠˇ\t好\t-4.0\n" ++
    "ㄋㄧˇ-ㄏㄠˇ\t你好\t-6.0\n" ++
    "ㄏㄠˋ\t號\t-5.5\n" ++
    "ㄕㄥ\t生\t-5.0\n";

test "exact syllables prefer the word" {
    const lexicon = try Lexicon.create(testing.allocator, &.{fixture}, "");
    defer lexicon.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try lexicon.decode(arena.allocator(), &.{ .{ .keys = "su", .tone = '3' }, .{ .keys = "cl", .tone = '3' } }, .{ .fuzzy = false });
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
    const out = try lexicon.decode(arena.allocator(), &.{.{ .keys = "cl", .tone = null }}, .{ .fuzzy = false });
    try testing.expectEqualStrings("號", out[0].text);
    try testing.expectEqual(@as(f64, -1.5), out[0].score);
    const toned = try lexicon.decode(arena.allocator(), &.{.{ .keys = "cl", .tone = '3' }}, .{ .fuzzy = false });
    try testing.expectEqualStrings("好", toned[0].text);
}

test "pending keys segment and decode" {
    const lexicon = try Lexicon.create(testing.allocator, &.{fixture}, "");
    defer lexicon.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try lexicon.decodeComposition(arena.allocator(), &.{}, "sucl", .{});
    try testing.expectEqualStrings("你好", out[0].text);
}

test "unknown tone-terminated run keeps fallback tails without overflow" {
    const lexicon = try Lexicon.create(testing.allocator, &.{fixture}, "");
    defer lexicon.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const options = try lexicon.repairComplete(arena.allocator(), .{ .keys = "suqqq", .tone = '3' }, true);
    try testing.expect(options.len > 0);
    try testing.expectEqualStrings("qqq", options[options.len - 1][options[options.len - 1].len - 1].keys);
}

test "user dictionary overlay restores" {
    const lexicon = try Lexicon.create(testing.allocator, &.{fixture}, "");
    defer lexicon.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try lexicon.applyUserDictionary(&.{.{ .reading = "ㄋㄧˇ-ㄏㄠˇ", .text = "擬好", .weight = 0 }}, &.{});
    const out = try lexicon.decode(arena.allocator(), &.{ .{ .keys = "su", .tone = '3' }, .{ .keys = "cl", .tone = '3' } }, .{});
    try testing.expectEqualStrings("擬好", out[0].text);
    try lexicon.applyUserDictionary(&.{}, &.{});
    const back = try lexicon.decode(arena.allocator(), &.{ .{ .keys = "su", .tone = '3' }, .{ .keys = "cl", .tone = '3' } }, .{});
    try testing.expectEqualStrings("你好", back[0].text);
}
