//! Port of tests/MisstypeCoreTests/ChannelModelTests.swift: personal
//! repair costs learned from retypes and reverts.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const channel = @import("../channel.zig");
const Dec = h.Dec;
const Harness = h.Harness;
const Learner = channel.ChannelLearner;

// g = ㄕ, p = ㄣ, / = ㄥ; Space = first tone.
fn top(d: *Dec, keys: []const u8) !?h.Candidate {
    const c = try d.decodeSegs(try d.comp(keys), .{});
    return if (c.len == 0) null else c[0];
}

fn model(subs: []const channel.Sub) channel.ChannelModel {
    var m: channel.ChannelModel = .{};
    m.rows['/'] = subs;
    return m;
}

fn costOf(l: *const Learner, typed: u8, intended: u8) ?f64 {
    const m = l.model() orelse return null;
    for (m.substitutes(typed)) |s| if (s.intended == intended) return s.raw;
    return null;
}

fn pairValue(map: anytype, typed: u8, intended: u8) f64 {
    return map.get(@as(u16, typed) << 8 | intended) orelse 0;
}

fn retype(a: std.mem.Allocator, typed: u8, intended: u8, opportunities: []const u8) !channel.Evidence {
    var evidence: channel.Evidence = .{};
    try evidence.intended.appendSlice(a, opportunities);
    const pairs = try a.alloc(channel.Pair, 1);
    pairs[0] = .{ .typed = typed, .intended = intended };
    evidence.retypes = pairs;
    return evidence;
}

test "a personal pair cheapens only that repair" {
    const d = try Dec.init("ㄕㄣ\t深\t-5\nㄕㄥ\t升\t-9\n");
    defer d.deinit();
    // Generic: 深 via ㄥ→ㄣ pays 5.0 (-10) and loses to the exact 升 (-9).
    try t.expectEqualStrings("升", (try top(d, "g/ ")).?.text);
    var m = model(&.{.{ .intended = 'p', .raw = 1.2 }});
    d.lex.channel = &m;
    const personal = (try top(d, "g/ ")).?;
    try t.expectEqualStrings("深", personal.text);
    try t.expectEqual(@as(i32, 1), personal.repairs);
    // Directional: typing ㄣ gains nothing toward ㄥ.
    const reverse = try Dec.init("ㄕㄣ\t深\t-9\nㄕㄥ\t升\t-5\n");
    defer reverse.deinit();
    reverse.lex.channel = &m;
    try t.expectEqualStrings("深", (try top(reverse, "gp ")).?.text);
}

test "the floor keeps exact input ahead" {
    const d = try Dec.init("ㄕㄣ\t深\t-9\nㄕㄥ\t升\t-9\n");
    defer d.deinit();
    var m = model(&.{.{ .intended = 'p', .raw = 0 }});
    d.lex.channel = &m;
    try t.expectEqualStrings("升", (try top(d, "g/ ")).?.text);
}

test "an empty channel decodes like none" {
    const d = try Dec.init("ㄕㄣ\t深\t-5\nㄕㄥ\t升\t-9\nㄕㄥ-ㄧㄣ\t聲音\t-6\n");
    defer d.deinit();
    const inputs = [_][]const u8{ "g/ ", "g/up", "gp ", "g/", "gpu/" };
    var plain: [inputs.len][]const u8 = undefined;
    for (inputs, &plain) |input, *out| out.* = if (try top(d, input)) |c| c.text else "";
    var empty: channel.ChannelModel = .{};
    d.lex.channel = &empty;
    for (inputs, plain) |input, want| {
        const got = if (try top(d, input)) |c| c.text else "";
        try t.expectEqualStrings(want, got);
    }
}

// MARK: - Learning

test "steady slips walk down slowly to the learned floor" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var learner = Learner.init(t.allocator);
    defer learner.deinit();
    var previous: f64 = Learner.generic_cost;
    var last: f64 = previous;
    // Every other ㄣ is typed ㄥ and re-typed: a 50% slip rate.
    for (0..200) |round| {
        const evidence = if (round % 2 == 0) try retype(a, '/', 'p', "gp") else blk: {
            var e: channel.Evidence = .{};
            try e.intended.appendSlice(a, "gp");
            break :blk e;
        };
        try learner.observe(&evidence);
        last = costOf(&learner, '/', 'p') orelse Learner.generic_cost;
        // Bounded step: never more than step_down per commit.
        try t.expect(previous - last <= Learner.step_down + 1e-9);
        previous = last;
    }
    try t.expectApproxEqAbs(Learner.learned_floor, last, 1e-9);
    // Only the learned pair, and only in that direction.
    const m = learner.model().?;
    for (0..128) |k| {
        const subs = m.substitutes(@intCast(k));
        if (k == '/') try t.expectEqual(@as(usize, 1), subs.len) else try t.expectEqual(@as(usize, 0), subs.len);
    }
}

test "no slips keep generic costs" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var learner = Learner.init(t.allocator);
    defer learner.deinit();
    for (0..500) |_| {
        var evidence: channel.Evidence = .{};
        try evidence.intended.appendSlice(a, "gp/");
        try learner.observe(&evidence);
    }
    try t.expect(learner.model() == null);
    // A rare slip against a large history stays near generic.
    try learner.observe(&(try retype(a, '/', 'p', "p")));
    try t.expect((costOf(&learner, '/', 'p') orelse 5) > 4.7);
}

test "reverts push back faster than slips pull" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var learner = Learner.init(t.allocator);
    defer learner.deinit();
    for (0..60) |_| try learner.observe(&(try retype(a, '/', 'p', "p")));
    try t.expectApproxEqAbs(Learner.learned_floor, costOf(&learner, '/', 'p') orelse 5, 1e-9);
    var revert: channel.Evidence = .{};
    try revert.intended.appendSlice(a, "g/");
    try revert.reverts.append(a, .{ .typed = '/', .intended = 'p' });
    var steps: usize = 0;
    while (costOf(&learner, '/', 'p') != null and steps < 100) {
        try learner.observe(&revert);
        steps += 1;
    }
    // 60 slips undone by 20 reverts, at step_up per commit.
    try t.expect(steps <= 25);
}

test "a dropped habit decays back to generic" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var learner = Learner.init(t.allocator);
    defer learner.deinit();
    for (0..60) |_| try learner.observe(&(try retype(a, '/', 'p', "p")));
    try t.expect(learner.model() != null);
    var clean: channel.Evidence = .{};
    try clean.intended.appendNTimes(a, 'p', 20);
    for (0..2000) |_| try learner.observe(&clean);
    try t.expect(learner.model() == null);
}

test "the learner round-trips through its file form" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var learner = Learner.init(t.allocator);
    defer learner.deinit();
    for (0..10) |_| try learner.observe(&(try retype(a, '/', 'p', "p")));
    const data = try learner.encode(t.allocator);
    defer t.allocator.free(data);
    var restored = try Learner.decode(t.allocator, data);
    defer restored.deinit();
    const again = try restored.encode(t.allocator);
    defer t.allocator.free(again);
    try t.expectEqualStrings(data, again);
    try t.expectEqual(learner.pairCount(), restored.pairCount());
}

// MARK: - Evidence in the session

test "evidence reads repairs and reverts" {
    const s = try Harness.init("ㄕㄣ\t深\t-5\nㄕㄥ\t升\t-9\n");
    defer s.deinit();
    s.settings().channel_learning = true;
    // A learned pair makes the repair the top reading (cost 1.2).
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    for (0..60) |_| try s.engine.channel_learner.observe(&(try retype(arena.allocator(), '/', 'p', "p")));
    // Unchallenged repair: one weak slip, ㄕㄣ as the opportunity.
    const slips_before = pairValue(s.engine.channel_learner.slips, '/', 'p');
    try s.typed("g/ ");
    try s.expectPreedit("深");
    try t.expectEqualStrings("深", (try s.enter()).commit.?);
    try t.expect(pairValue(s.engine.channel_learner.slips, '/', 'p') > slips_before);
    // The user picked the exact text over the repair: a revert.
    const reverts_before = pairValue(s.engine.channel_learner.reverts, '/', 'p');
    try s.typed("g/ ");
    _ = try s.down();
    try s.expectPreedit("升");
    try t.expectEqualStrings("升", (try s.enter()).commit.?);
    try t.expect(pairValue(s.engine.channel_learner.reverts, '/', 'p') > reverts_before);
}

test "the session records a backspace retype on commit" {
    const s = try Harness.init("ㄕㄣ\t深\t-5\nㄕㄥ\t升\t-9\n");
    defer s.deinit();
    s.settings().channel_learning = true;
    try s.typed("g/");
    _ = try s.key(.backspace, 0, null);
    try s.typed("p ");
    try t.expectEqualStrings("深", (try s.enter()).commit.?);
    const learner = &s.engine.channel_learner;
    try t.expectApproxEqAbs(@as(f64, 1), pairValue(learner.slips, '/', 'p'), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 1), learner.opportunities.get('p') orelse 0, 1e-9);
    // A rewrite of more than one key is not a slip.
    try s.typed("g/");
    _ = try s.key(.backspace, 0, null);
    _ = try s.key(.backspace, 0, null);
    try s.typed("ap ");
    _ = try s.enter();
    try t.expectApproxEqAbs(@as(f64, 1), pairValue(learner.slips, '/', 'p'), 0.01);
    // Off: nothing learned, decoder overlay cleared.
    s.settings().channel_learning = false;
    const before = try learner.encode(t.allocator);
    defer t.allocator.free(before);
    try s.typed("g/");
    _ = try s.key(.backspace, 0, null);
    try s.typed("p ");
    _ = try s.enter();
    const after = try learner.encode(t.allocator);
    defer t.allocator.free(after);
    try t.expectEqualStrings(before, after);
    try t.expect(s.engine.decoder.channel == null);
}
