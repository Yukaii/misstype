//! Coordinate hypotheses and beam/lattice touch decoding, following Touch.swift.
//! Raw taps are immutable evidence. All decode allocations belong to the caller's arena.
const std = @import("std");
const keyboard = @import("keyboard.zig");
const composition = @import("composition.zig");
const lexicon = @import("lexicon.zig");
const Candidate = @import("candidate.zig").Candidate;
const UserLexicon = @import("user_lexicon.zig").UserLexicon;
const A = std.mem.Allocator;
const Syllable = keyboard.Syllable;
const Option = lexicon.Option;
extern "c" fn hypot(f64, f64) f64;

pub const version = "full-split-1";
pub const Surface = enum { left, right };
pub const Position = struct { key: u8, surface: Surface, x: f64, y: f64 };
pub const positions = blk: {
    const left = "1qaz2ws34erdfcvxg5bt";
    const right = "8ik,9ol67yuhjnm0/p.;-";
    const coords = [_][2]f64{ .{ 0.15, 0.20 }, .{ 0.30, 0.20 }, .{ 0.30, 0.50 }, .{ 0.30, 0.80 }, .{ 0.50, 0.20 }, .{ 0.50, 0.50 }, .{ 0.50, 0.80 }, .{ 0.70, 0.10 }, .{ 0.88, 0.10 }, .{ 0.70, 0.23 }, .{ 0.88, 0.23 }, .{ 0.70, 0.36 }, .{ 0.88, 0.36 }, .{ 0.70, 0.49 }, .{ 0.88, 0.49 }, .{ 0.70, 0.62 }, .{ 0.88, 0.62 }, .{ 0.70, 0.75 }, .{ 0.88, 0.75 }, .{ 0.70, 0.88 }, .{ 0.88, 0.88 } };
    var out: [left.len + right.len]Position = undefined;
    for (left, 0..) |key, i| out[i] = .{ .key = key, .surface = .left, .x = coords[i][0], .y = coords[i][1] };
    for (right, 0..) |key, i| out[left.len + i] = .{ .key = key, .surface = .right, .x = coords[i][0], .y = coords[i][1] };
    break :blk out;
};
pub fn position(key: u8) ?Position {
    for (positions) |p| if (p.key == key) return p;
    return null;
}
pub const Hypothesis = struct {
    surface: Surface,
    x: f64,
    y: f64,
    ranked: [5]Ranked,
    pub const Ranked = struct { key: u8, distance: f64, weight: f64 };
    pub fn key(self: Hypothesis) u8 {
        return self.ranked[0].key;
    }
};
pub fn weight(distance: f64) f64 {
    return @max(0.1, 1.0 - distance * 1.5);
}
pub fn hypothesis(surface: Surface, x: f64, y: f64) ?Hypothesis {
    if (!(x >= 0 and x <= 1 and y >= 0 and y <= 1)) return null;
    var all: [21]Hypothesis.Ranked = undefined;
    var n: usize = 0;
    for (positions) |p| if (p.surface == surface) {
        const distance = hypot(x - p.x, y - p.y);
        all[n] = .{ .key = p.key, .distance = distance, .weight = weight(distance) };
        n += 1;
    };
    std.mem.sort(Hypothesis.Ranked, all[0..n], {}, struct {
        fn lt(_: void, a: Hypothesis.Ranked, b: Hypothesis.Ranked) bool {
            return if (a.distance == b.distance) a.key < b.key else a.distance < b.distance;
        }
    }.lt);
    var out = Hypothesis{ .surface = surface, .x = x, .y = y, .ranked = undefined };
    @memcpy(&out.ranked, all[0..5]);
    return out;
}
pub const TouchCandidate = struct {
    sentence: Candidate,
    keys: []const u8,
    spatial_cost: f64,
    pub fn score(self: TouchCandidate) f64 {
        return self.sentence.score - self.spatial_cost;
    }
    fn better(_: void, a: TouchCandidate, b: TouchCandidate) bool {
        return if (a.score() == b.score()) std.mem.order(u8, a.sentence.text, b.sentence.text) == .lt else a.score() > b.score();
    }
};
pub const Options = struct {
    spatial: bool = true,
    fuzzy: bool = true,
    tone_tolerance: bool = true,
    spatial_scale: f64 = 10,
    beam: usize = 16,
    combos_per_slice: usize = 24,
    repair_combos: usize = 4,
    always_repair: bool = false,
    user_lexicon: ?*const UserLexicon = null,
};
const KeyOption = struct { key: u8, cost: f64 };
const Combo = struct {
    keys: []const u8,
    cost: f64,
    fn better(_: void, a: Combo, b: Combo) bool {
        return if (a.cost == b.cost) std.mem.order(u8, a.keys, b.keys) == .lt else a.cost < b.cost;
    }
};
fn keyOptions(a: A, tap: Hypothesis, opts: Options) ![]KeyOption {
    var out: std.ArrayList(KeyOption) = .empty;
    try out.append(a, .{ .key = tap.key(), .cost = 0 });
    if (opts.spatial and keyboard.isSymbol(tap.key())) for (tap.ranked[1..]) |other| {
        if (keyboard.isSymbol(other.key)) try out.append(a, .{ .key = other.key, .cost = opts.spatial_scale * (other.distance - tap.ranked[0].distance) });
    };
    return out.items;
}
fn extendCombos(a: A, combos: []const Combo, options: []const KeyOption, cap: usize) ![]Combo {
    var out: std.ArrayList(Combo) = .empty;
    for (combos) |combo| for (options) |o| {
        const keys = try a.alloc(u8, combo.keys.len + 1);
        @memcpy(keys[0..combo.keys.len], combo.keys);
        keys[combo.keys.len] = o.key;
        try out.append(a, .{ .keys = keys, .cost = combo.cost + o.cost });
    };
    std.mem.sort(Combo, out.items, {}, Combo.better);
    return out.items[0..@min(out.items.len, cap)];
}
fn merge(a: A, list: *std.ArrayList(TouchCandidate), value: TouchCandidate) !void {
    for (list.items) |*old| if (@import("unicode.zig").equal(old.sentence.text, value.sentence.text)) {
        if (old.score() < value.score()) old.* = value;
        return;
    };
    try list.append(a, value);
}
pub fn decodeBeam(dec: *const lexicon.Lexicon, a: A, taps: []const Hypothesis, opts: Options) ![]TouchCandidate {
    if (taps.len == 0) return &.{};
    var combos: []const Combo = &.{.{ .keys = "", .cost = 0 }};
    for (taps) |tap| combos = try extendCombos(a, combos, try keyOptions(a, tap, opts), opts.beam);
    var out: std.ArrayList(TouchCandidate) = .empty;
    for (combos) |combo| {
        var c: composition.Composition = .{};
        for (combo.keys) |key| _ = try c.append(a, key);
        const parsed = try c.parsed(a);
        const decoded = try dec.decodeSegments(a, try c.segments(a), parsed.pending, .{ .fuzzy = opts.fuzzy, .tone_tolerance = opts.tone_tolerance, .user_lexicon = opts.user_lexicon });
        for (decoded[0..@min(decoded.len, 4)]) |sentence| try merge(a, &out, .{ .sentence = sentence, .keys = combo.keys, .spatial_cost = combo.cost });
    }
    std.mem.sort(TouchCandidate, out.items, {}, TouchCandidate.better);
    return out.items[0..@min(out.items.len, 16)];
}
const Run = struct { start: usize, end: usize, tone: ?u8 };
const Slice = struct { syllable: Syllable, options: []Option };
const Segmentation = struct {
    slices: []const Slice,
    cost: f64,
    fn better(_: void, a: Segmentation, b: Segmentation) bool {
        return a.cost < b.cost;
    }
};
const CacheKey = struct { start: usize, end: usize, tone: ?u8, repair: bool };
const Decoder = struct {
    dec: *const lexicon.Lexicon,
    a: A,
    taps: []const Hypothesis,
    nearest: []const u8,
    tap_options: []const []KeyOption,
    opts: Options,
    cache: std.AutoHashMapUnmanaged(CacheKey, []Option) = .empty,
    fn sliceOptions(self: *Decoder, run: Run, repair: bool) ![]Option {
        const id: CacheKey = .{ .start = run.start, .end = run.end, .tone = run.tone, .repair = repair };
        if (self.cache.get(id)) |hit| return hit;
        const a = self.a;
        var combos: []const Combo = &.{.{ .keys = "", .cost = 0 }};
        for (self.tap_options[run.start..run.end]) |options| combos = try extendCombos(a, combos, options, self.opts.combos_per_slice);
        var merged: std.ArrayList(Option) = .empty;
        for (combos, 0..) |combo, rank| {
            const nearest = std.mem.eql(u8, combo.keys, self.nearest[run.start..run.end]);
            const alternatives = try self.dec.alternatives(a, .{ .keys = combo.keys, .tone = run.tone }, repair and rank < self.opts.repair_combos, self.opts.tone_tolerance);
            for (alternatives) |option| {
                var priced = option;
                priced.cost += combo.cost;
                priced.correction += if (nearest) @as(i32, 0) else 1;
                var found = false;
                for (merged.items) |*old| if (old.reading == option.reading) {
                    if (old.cost > priced.cost) old.* = priced;
                    found = true;
                    break;
                };
                if (!found) try merged.append(a, priced);
            }
        }
        std.mem.sort(Option, merged.items, self.dec, struct {
            fn lt(dec: *const lexicon.Lexicon, x: Option, y: Option) bool {
                return if (x.cost == y.cost) std.mem.order(u8, dec.reading_names.items[x.reading], dec.reading_names.items[y.reading]) == .lt else x.cost < y.cost;
            }
        }.lt);
        const out = merged.items[0..@min(merged.items.len, 16)];
        try self.cache.put(a, id, out);
        return out;
    }
    fn segmentations(self: *Decoder, run: Run, repair: bool) ![]const Segmentation {
        const a = self.a;
        const n = run.end - run.start;
        const lattice = try a.alloc(std.ArrayList(Segmentation), n + 1);
        for (lattice) |*slot| slot.* = .empty;
        try lattice[0].append(a, .{ .slices = &.{}, .cost = 0 });
        for (0..n) |offset| {
            std.mem.sort(Segmentation, lattice[offset].items, {}, Segmentation.better);
            lattice[offset].shrinkRetainingCapacity(@min(lattice[offset].items.len, 24));
            const max_len: usize = @min(4, n - offset);
            for (1..max_len + 1) |len| {
                const span: Run = .{ .start = run.start + offset, .end = run.start + offset + len, .tone = if (offset + len == n) run.tone else null };
                const options = try self.sliceOptions(span, repair);
                if (options.len == 0) continue;
                const slice: Slice = .{ .syllable = .{ .keys = self.nearest[span.start..span.end], .tone = span.tone }, .options = options };
                const prefixes = lattice[offset].items;
                for (prefixes[0..@min(prefixes.len, 8)]) |prefix| {
                    const slices = try a.alloc(Slice, prefix.slices.len + 1);
                    @memcpy(slices[0..prefix.slices.len], prefix.slices);
                    slices[prefix.slices.len] = slice;
                    try lattice[offset + len].append(a, .{ .slices = slices, .cost = prefix.cost + options[0].cost });
                    if (lattice[offset + len].items.len >= 64) break;
                }
            }
        }
        const done = lattice[n].items;
        std.mem.sort(Segmentation, done, {}, Segmentation.better);
        if (done.len > 0) return done[0..@min(done.len, 12)];
        const raw = try a.alloc(Slice, n);
        for (raw, 0..) |*slice, index| slice.* = .{ .syllable = .{ .keys = self.nearest[run.start + index .. run.start + index + 1], .tone = if (index == n - 1) run.tone else null }, .options = &.{} };
        const result = try a.alloc(Segmentation, 1);
        result[0] = .{ .slices = raw, .cost = 100 };
        return result;
    }
    fn decodeAll(self: *Decoder, runs: []const Run, repair: bool) ![]Candidate {
        const a = self.a;
        var overall: []const Segmentation = &.{.{ .slices = &.{}, .cost = 0 }};
        for (runs) |run| {
            const all = try self.segmentations(run, repair);
            const options = all[0..@min(all.len, 6)];
            var next: std.ArrayList(Segmentation) = .empty;
            for (overall) |prefix| for (options) |option| {
                const slices = try a.alloc(Slice, prefix.slices.len + option.slices.len);
                @memcpy(slices[0..prefix.slices.len], prefix.slices);
                @memcpy(slices[prefix.slices.len..], option.slices);
                try next.append(a, .{ .slices = slices, .cost = prefix.cost + option.cost });
            };
            std.mem.sort(Segmentation, next.items, {}, Segmentation.better);
            overall = next.items[0..@min(next.items.len, 12)];
        }
        var found: std.ArrayList(Candidate) = .empty;
        for (overall) |seg| {
            if (seg.slices.len == 0) continue;
            const syllables = try a.alloc(Syllable, seg.slices.len);
            const options = try a.alloc([]Option, seg.slices.len);
            for (seg.slices, syllables, options) |slice, *s, *o| {
                s.* = slice.syllable;
                o.* = slice.options;
            }
            try found.appendSlice(a, try self.dec.decodeOptions(a, syllables, options, self.opts.user_lexicon, null));
        }
        return found.items;
    }
};
pub fn decode(dec: *const lexicon.Lexicon, a: A, taps: []const Hypothesis, opts: Options) ![]TouchCandidate {
    if (taps.len == 0) return &.{};
    const nearest = try a.alloc(u8, taps.len);
    const tap_options = try a.alloc([]KeyOption, taps.len);
    var runs: std.ArrayList(Run) = .empty;
    var start: ?usize = null;
    for (taps, 0..) |tap, index| {
        nearest[index] = tap.key();
        tap_options[index] = try keyOptions(a, tap, opts);
        if (keyboard.isSymbol(tap.key())) {
            if (start == null) start = index;
        } else if (keyboard.isTone(tap.key())) if (start) |lo| {
            try runs.append(a, .{ .start = lo, .end = index, .tone = tap.key() });
            start = null;
        };
    }
    if (start) |lo| try runs.append(a, .{ .start = lo, .end = taps.len, .tone = null });
    var d: Decoder = .{ .dec = dec, .a = a, .taps = taps, .nearest = nearest, .tap_options = tap_options, .opts = opts };
    const clean = try d.decodeAll(runs.items, false);
    var best: ?Candidate = null;
    for (clean) |c| if (best == null or @import("candidate.zig").better(c, best.?)) {
        best = c;
    };
    var out: std.ArrayList(TouchCandidate) = .empty;
    for (clean) |c| try merge(a, &out, .{ .sentence = c, .keys = nearest, .spatial_cost = 0 });
    if (opts.fuzzy and (opts.always_repair or best == null or best.?.unresolved > 0 or best.?.repairs > 0)) {
        for (try d.decodeAll(runs.items, true)) |c| try merge(a, &out, .{ .sentence = c, .keys = nearest, .spatial_cost = 0 });
    }
    std.mem.sort(TouchCandidate, out.items, {}, TouchCandidate.better);
    return out.items[0..@min(out.items.len, 16)];
}
test "touch centres, bounds, tones and empty input" {
    for (positions) |p| try std.testing.expectEqual(p.key, hypothesis(p.surface, p.x, p.y).?.key());
    try std.testing.expect(hypothesis(.left, -0.1, 0.5) == null);
    try std.testing.expect(hypothesis(.right, std.math.nan(f64), 0.5) == null);
    const dec = try lexicon.Lexicon.create(std.testing.allocator, &.{"ㄋㄧˇ-ㄏㄠˇ\t你好\t-3\n"}, "");
    defer dec.destroy();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const taps = try arena.allocator().alloc(Hypothesis, 6);
    for ("su3cl3", taps) |key, *tap| {
        const p = position(key).?;
        tap.* = hypothesis(p.surface, p.x, p.y).?;
    }
    try std.testing.expectEqualStrings("你好", (try decode(dec, arena.allocator(), taps, .{}))[0].sentence.text);
    try std.testing.expectEqualStrings("你好", (try decodeBeam(dec, arena.allocator(), taps, .{}))[0].sentence.text);
    try std.testing.expectEqual(@as(usize, 0), (try decode(dec, arena.allocator(), &.{}, .{})).len);
}
