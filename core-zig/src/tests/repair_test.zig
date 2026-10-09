//! Port of tests/MisstypeCoreTests/RepairStrengthTests.swift: when a
//! keyboard repair beats exact input, per repair-strength level.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const channel = @import("../channel.zig");
const keyboard = @import("../keyboard.zig");
const Dec = h.Dec;
const Harness = h.Harness;
const Range = h.Range;

// g = ㄕ, p = ㄣ, / = ㄥ, s = ㄋ, u = ㄧ; Space = first tone.
fn top(d: *Dec, keys: []const u8) !?h.Candidate {
    const c = try d.decodeSegs(try d.comp(keys), .{});
    return if (c.len == 0) null else c[0];
}

fn applyLevel(d: *Dec, level: channel.RepairStrength) void {
    d.lex.repair_cost_offset = level.costOffset();
    d.lex.repair_valid_readings = level.repairsValidReadings();
}

test "the offset decides when a repair beats exact input" {
    // Exact 升 (-9) against 深 via the generic ㄥ→ㄣ confusion (-4.5 - 5).
    const d = try Dec.init("ㄕㄣ\t深\t-4.5\nㄕㄥ\t升\t-9\n");
    defer d.deinit();
    for ([_]channel.RepairStrength{ .light, .standard, .strong }) |level| {
        applyLevel(d, level);
        try t.expectEqualStrings("升", (try top(d, "g/ ")).?.text);
    }
    d.lex.repair_cost_offset = -1;
    const cheaper = (try top(d, "g/ ")).?;
    try t.expectEqualStrings("深", cheaper.text);
    try t.expectEqual(@as(i32, 1), cheaper.repairs);
}

test "light keeps exact input that standard repairs" {
    // Exact 升 (-9) against 深 (-3.5) via ㄥ→ㄣ: -8.5 standard, -10.5 light.
    const d = try Dec.init("ㄕㄣ\t深\t-3.5\nㄕㄥ\t升\t-9\n");
    defer d.deinit();
    try t.expectEqualStrings("深", (try top(d, "g/ ")).?.text);
    d.lex.repair_cost_offset = channel.RepairStrength.light.costOffset();
    try t.expectEqualStrings("升", (try top(d, "g/ ")).?.text);
}

test "light still rescues input with no reading" {
    // Bare ㄋˇ is no reading at all; inserting ㄧ is the only way to 你.
    const d = try Dec.init("ㄋㄧˇ\t你\t-5\n");
    defer d.deinit();
    d.lex.repair_cost_offset = channel.RepairStrength.light.costOffset();
    try t.expectEqualStrings("你", (try top(d, "s3")).?.text);
}

test "strong undoes a slip onto another real syllable inside a word" {
    // ㄕㄥ is a real reading, so a neighbor-key repair of it is gated off
    // unless the level repairs valid readings too; then it may complete the
    // word 好對 (c = ㄏ, l = ㄠ).
    const neighbor = keyboard.neighbors('g')[0];
    const symbol = keyboard.symbol(neighbor).?;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const rows = try std.fmt.allocPrint(arena.allocator(), "ㄏㄠˇ\t好\t-6\nㄕㄥ\t升\t-12\n{s}ㄥ\t對\t-12\nㄏㄠˇ-{s}ㄥ\t好對\t-5\n", .{ symbol, symbol });
    const d = try Dec.init(rows);
    defer d.deinit();
    try t.expectEqualStrings("好升", (try top(d, "cl3g/ ")).?.text);
    d.lex.repair_valid_readings = true;
    const strong = (try top(d, "cl3g/ ")).?;
    try t.expectEqualStrings("好對", strong.text);
    try t.expectEqual(@as(i32, 1), strong.repairs);
}

test "strong never turns a real single syllable into a more common neighbor" {
    // 好喔 (i = ㄛ) must not become 好一 (u = ㄧ, a neighbor key): a single
    // character has only frequency to argue for a repair.
    const d = try Dec.init("ㄏㄠˇ\t好\t-6\nㄛ\t喔\t-11\nㄧ\t一\t-2\n");
    defer d.deinit();
    d.lex.repair_valid_readings = channel.RepairStrength.strong.repairsValidReadings();
    try t.expectEqualStrings("好喔", (try top(d, "cl3i")).?.text);
    try t.expectEqualStrings("喔", (try top(d, "i ")).?.text);
    const picker = try d.lex.segmentOptions(d.a(), &.{d.syl("i", h.first_tone)}, Range.of(0, 1), true, true);
    for (picker) |o| try t.expect(!std.mem.eql(u8, o.text, "一"));
}

test "a learned pair ignores the offset" {
    const d = try Dec.init("ㄕㄣ\t深\t-5\nㄕㄥ\t升\t-9\n");
    defer d.deinit();
    var model: channel.ChannelModel = .{};
    model.rows['/'] = &.{.{ .intended = 'p', .raw = 1.2 }};
    d.lex.channel = &model;
    d.lex.repair_cost_offset = channel.RepairStrength.light.costOffset();
    try t.expectEqualStrings("深", (try top(d, "g/ ")).?.text);
}

test "the session applies the level per keystroke" {
    const neighbor = keyboard.neighbors('g')[0];
    const symbol = keyboard.symbol(neighbor).?;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const rows = try std.fmt.allocPrint(arena.allocator(), "ㄏㄠˇ\t好\t-6\nㄕㄥ\t升\t-12\n{s}ㄥ\t對\t-12\nㄏㄠˇ-{s}ㄥ\t好對\t-5\nㄋㄧˇ\t你\t-5\n", .{ symbol, symbol });
    const s = try Harness.init(rows);
    defer s.deinit();
    const typeAndCommit = struct {
        fn run(hh: *Harness, keys: []const u8) !?[]const u8 {
            try hh.typed(keys);
            return (try hh.enter()).commit;
        }
    }.run;
    try t.expectEqualStrings("好升", (try typeAndCommit(s, "cl3g/ ")).?);
    s.settings().repair_strength = .strong;
    try t.expectEqualStrings("好對", (try typeAndCommit(s, "cl3g/ ")).?);
    s.settings().repair_strength = .off;
    try t.expect(!s.settings().fuzzyRepair());
    const off = try typeAndCommit(s, "s3");
    try t.expect(off == null or !std.mem.eql(u8, off.?, "你"));
    s.settings().repair_strength = .light;
    try t.expectEqualStrings("你", (try typeAndCommit(s, "s3")).?);
}
