//! Port of tests/MisstypeCoreTests/TouchTests.swift: the coordinate-aware
//! touch layer (mapper, beam, lattice) against the recorded fixtures.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const touch = @import("../touch.zig");
const keyboard = @import("../keyboard.zig");
const Dec = h.Dec;

const rows = h.tsv(
    \\ㄋㄧˇ|你|-5
    \\ㄏㄠˇ|好|-5
    \\ㄋㄧˇ-ㄏㄠˇ|你好|-3
    \\ㄗㄠˇ-ㄕㄤˋ-ㄏㄠˇ|早上好|-3
    \\
);

const Tap = struct { surface: touch.Surface, x: f64, y: f64, key: u8 };

/// (surface, x, y, key) rows of a Python-recorded fixture.
fn fixtureTaps(a: std.mem.Allocator, name: []const u8) ![]Tap {
    const path = try std.fmt.allocPrint(a, "../tests/fixtures/{s}.jsonl", .{name});
    const text = try h.readRepoFile(a, path);
    var out: std.ArrayList(Tap) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const row = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        const payload = row.object.get("payload").?.object;
        const surface = row.object.get("surface").?.string;
        try out.append(a, .{
            .surface = if (std.mem.eql(u8, surface, "left")) .left else .right,
            .x = jsonNumber(payload.get("x").?),
            .y = jsonNumber(payload.get("y").?),
            .key = payload.get("key").?.string[0],
        });
    }
    return out.items;
}

fn jsonNumber(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => unreachable,
    };
}

fn hypotheses(a: std.mem.Allocator, taps: []const Tap) ![]touch.Hypothesis {
    const out = try a.alloc(touch.Hypothesis, taps.len);
    for (taps, out) |tap, *o| o.* = touch.hypothesis(tap.surface, tap.x, tap.y).?;
    return out;
}

test "the layout covers every Zhuyin and tone key once" {
    var seen: [128]bool = @splat(false);
    for (touch.positions) |p| {
        try t.expect(!seen[p.key]);
        seen[p.key] = true;
    }
    for (keyboard.symbol_keys) |k| try t.expect(seen[k]);
    for ("3467") |k| try t.expect(seen[k]);
    try t.expectEqual(keyboard.symbol_keys.len + 4, touch.positions.len);
}

test "the mapper picks the keys recorded in Python fixtures" {
    const d = try Dec.init(rows);
    defer d.deinit();
    for ([_][]const u8{ "touch-ni-hao", "touch-zao-shang-hao" }) |name| {
        for (try fixtureTaps(d.a(), name)) |tap| {
            const hyp = touch.hypothesis(tap.surface, tap.x, tap.y).?;
            try t.expectEqual(tap.key, hyp.key());
        }
    }
}

test "neighbor ranking and weights match Python" {
    // Golden values computed by `misstype.touch.nearest_key(...).spatial`
    // (fixtures predate the neighbors payload, so they cannot carry them).
    const Golden = struct { surface: touch.Surface, x: f64, y: f64, expected: [5]struct { u8, f64 } };
    const golden = [_]Golden{
        .{ .surface = .left, .x = 0.7, .y = 0.58, .expected = .{ .{ 'x', 0.94 }, .{ 'c', 0.865 }, .{ '5', 0.745 }, .{ 'g', 0.723413666281 }, .{ 'v', 0.698130823038 } } },
        .{ .surface = .right, .x = 0.31, .y = 0.52, .expected = .{ .{ 'k', 0.966458980338 }, .{ 'o', 0.713425402382 }, .{ ',', 0.579732228216 }, .{ 'i', 0.519765682193 }, .{ 'l', 0.492432270529 } } },
        .{ .surface = .left, .x = 0.5, .y = 0.8, .expected = .{ .{ 's', 1.0 }, .{ 'z', 0.7 }, .{ '5', 0.690767078079 }, .{ 't', 0.676890111572 }, .{ 'x', 0.596391278588 } } },
        .{ .surface = .right, .x = 0.8, .y = 0.3, .expected = .{ .{ 'j', 0.85 }, .{ 'u', 0.840547812809 }, .{ 'h', 0.825071443155 }, .{ 'y', 0.816901665764 }, .{ 'm', 0.690767078079 } } },
    };
    for (golden) |g| {
        const ranked = touch.hypothesis(g.surface, g.x, g.y).?.ranked;
        for (ranked, g.expected) |mine, theirs| {
            try t.expectEqual(theirs[0], mine.key);
            try t.expectApproxEqAbs(theirs[1], mine.weight, 1e-9);
        }
    }
}

test "an out-of-surface point is rejected" {
    try t.expect(touch.hypothesis(.left, 1.1, 0.5) == null);
    try t.expect(touch.hypothesis(.right, 0.5, -0.01) == null);
}

test "replay of recorded touch traces decodes" {
    const d = try Dec.init(rows);
    defer d.deinit();
    const cases = [_]struct { []const u8, []const u8 }{ .{ "touch-ni-hao", "你好" }, .{ "touch-zao-shang-hao", "早上好" } };
    for (cases) |c| {
        const taps = try hypotheses(d.a(), try fixtureTaps(d.a(), c[0]));
        const lattice = try touch.decode(d.lex, d.a(), taps, .{});
        try t.expectEqualStrings(c[1], lattice[0].sentence.text);
        const beam = try touch.decodeBeam(d.lex, d.a(), taps, .{});
        try t.expectEqualStrings(c[1], beam[0].sentence.text);
        try t.expectEqual(@as(f64, 0), beam[0].spatial_cost);
    }
}

test "spatial neighbors rescue a miss without keyboard repair" {
    // ㄏ (c) tapped low: x is nearer, so the nearest-key reading is ㄌㄠˇ.
    const d = try Dec.init(rows);
    defer d.deinit();
    const keys = "su3cl3";
    var taps: std.ArrayList(touch.Hypothesis) = .empty;
    for (keys) |key| {
        const p = touch.position(key).?;
        const y = if (key == 'c') p.y + 0.09 else p.y;
        try taps.append(d.a(), touch.hypothesis(p.surface, p.x, y).?);
    }
    try t.expectEqual(@as(u8, 'x'), taps.items[3].key());
    const with = touch.Options{ .spatial = true, .fuzzy = false };
    const without = touch.Options{ .spatial = false, .fuzzy = false };
    const beam_off = try touch.decodeBeam(d.lex, d.a(), taps.items, without);
    try t.expect(beam_off.len == 0 or !std.mem.eql(u8, beam_off[0].sentence.text, "你好"));
    const lattice_off = try touch.decode(d.lex, d.a(), taps.items, without);
    try t.expect(lattice_off.len == 0 or !std.mem.eql(u8, lattice_off[0].sentence.text, "你好"));
    const beam = try touch.decodeBeam(d.lex, d.a(), taps.items, with);
    try t.expectEqualStrings("你好", beam[0].sentence.text);
    try t.expectEqualStrings("你好", (try touch.decode(d.lex, d.a(), taps.items, with))[0].sentence.text);
    try t.expect(beam[0].spatial_cost > 0);
    try t.expectEqualStrings(keys, beam[0].keys);
}

test "tone taps stay exact" {
    // A tap nearer the 3 key than anything else never becomes a Zhuyin key.
    const d = try Dec.init(rows);
    defer d.deinit();
    const tap = touch.hypothesis(.left, 0.70, 0.16).?;
    try t.expectEqual(@as(u8, '3'), tap.key());
    for (try touch.decode(d.lex, d.a(), &.{tap}, .{})) |c| try t.expectEqualStrings("3", c.keys);
    for (try touch.decodeBeam(d.lex, d.a(), &.{tap}, .{})) |c| try t.expectEqualStrings("3", c.keys);
}
