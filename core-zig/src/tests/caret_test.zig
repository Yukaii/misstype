//! Port of tests/MisstypeCoreTests/CaretEditingTests.swift: typing at the
//! syllable cursor (issue #32) and Option word editing over Latin runs and
//! words (issue #33).

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const composition_mod = @import("../composition.zig");
const layout_mod = @import("../layout.zig");
const Harness = h.Harness;
const Range = h.Range;
const expectRes = h.expectRes;

// MARK: - #32 typing at the syllable cursor

test "typing at the cursor inserts there" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3a87");
    try s.expectPreedit("你嗎");
    _ = try s.left();
    var v = try s.view();
    try t.expectEqual(@as(u32, 1), v.caret);
    try t.expect(!v.keys_active);
    for (try s.typeKeys("cl3")) |r| {
        try t.expect(r.consumed and r.commit == null and !r.beep);
    }
    try s.expectPreedit("你好嗎");
    v = try s.view();
    try t.expectEqual(@as(u32, 2), v.caret);
    try s.expectRaw("ㄋㄧˇㄏㄠˇㄇㄚ˙");
    try t.expectEqualStrings("你好嗎", (try s.enter()).commit.?);
}

test "selection keys type Zhuyin at the cursor until Tab arms them" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3cl3");
    _ = try s.left();
    try s.typed("a87"); // `a` is selection slot 1 and ㄇ
    try s.expectPreedit("你嗎好");
    // Tab arms the focused list; Esc disarms it and keeps the cursor.
    _ = try s.left();
    _ = try s.left();
    _ = try s.key(.tab, 0, null);
    try t.expect((try s.view()).keys_active);
    try expectRes(.{ .consumed = true }, try s.key(.escape, 0, null));
    const v = try s.view();
    try t.expect(!v.keys_active);
    try t.expect(v.shows_candidates);
    try t.expectEqual(@as(u32, 0), v.caret);
    try s.typed("a87");
    try s.expectPreedit("嗎你嗎好");
}

test "backspace and forward delete at the cursor" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3cl3a87");
    _ = try s.left();
    _ = try s.left(); // caret before 好
    try t.expectEqual(@as(u32, 1), (try s.view()).caret);
    try expectRes(.{ .consumed = true }, try s.key(.backspace, 0, null));
    try s.expectPreedit("好嗎");
    try t.expectEqual(@as(u32, 0), (try s.view()).caret);
    try expectRes(.{ .consumed = true }, try s.key(.forward_delete, 0, null));
    try s.expectPreedit("嗎");
    try s.typed("su3cl3");
    try s.expectPreedit("你好嗎");
    try t.expectEqual(@as(u32, 2), (try s.view()).caret);
}

test "Escape and Right past the end return the caret to the end" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3a87");
    _ = try s.left();
    try s.typed("cl3");
    try t.expectEqual(@as(u32, 2), (try s.view()).caret);
    try expectRes(.{ .consumed = true }, try s.right());
    try t.expectEqual(@as(u32, 3), (try s.view()).caret);
    try s.typed("su3");
    try s.expectPreedit("你好嗎你");

    _ = try s.left();
    try expectRes(.{ .consumed = true }, try s.key(.escape, 0, null));
    try s.expectPreedit("你好嗎你");
    const v = try s.view();
    try t.expectEqual(@as(u32, 4), v.caret);
    try t.expect(!(v.shows_candidates and v.focus != null));
    try s.typed("a87");
    try s.expectPreedit("你好嗎你嗎");
}

test "no auto-commit while editing mid-composition" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    s.settings().auto_commit_syllables = 4;
    try s.typed("su3su3");
    _ = try s.left();
    for (0..4) |_| {
        for (try s.typeKeys("a87")) |r| try t.expect(r.commit == null);
    }
    try s.expectPreedit("你嗎嗎嗎嗎你");
}

// MARK: - #33 Option word editing

test "Option+Backspace deletes a Latin word" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3`hello world");
    try s.expectPreedit("你hello world");
    _ = try s.key(.backspace, h.option, null);
    try s.expectPreedit("你hello ");
    _ = try s.key(.backspace, h.option, null);
    try s.expectPreedit("你");
    try t.expect(s.session.latinActive());
    try s.typed("ok");
    try s.expectPreedit("你ok");
}

test "Option+arrows jump by word and typing follows the caret" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3cl3`hello world");
    try expectRes(.{ .consumed = true }, try s.key(.left, h.option, null));
    try t.expectEqual(@as(u32, 8), (try s.view()).caret); // 你好hello |world
    try t.expect(s.session.latinActive());
    try s.typed("big ");
    try s.expectPreedit("你好hello big world");
    try t.expectEqual(@as(u32, 12), (try s.view()).caret);
    _ = try s.key(.left, h.option, null); // |big
    _ = try s.key(.left, h.option, null); // |hello
    try t.expectEqual(@as(u32, 2), (try s.view()).caret);
    _ = try s.key(.left, h.option, null); // |你好 (one decoded word)
    try t.expectEqual(@as(u32, 0), (try s.view()).caret);
    try expectRes(.{ .consumed = true, .beep = true }, try s.key(.left, h.option, null));
    try t.expect(!s.session.latinActive());
    try s.typed("a87");
    try s.expectPreedit("嗎你好hello big world");
    _ = try s.key(.right, h.option, null); // 嗎你好| (word end)
    _ = try s.key(.backspace, h.option, null); // a syllable, not the Latin word after it
    try s.expectPreedit("嗎你hello big world");
    _ = try s.key(.right, h.option, null);
    _ = try s.key(.right, h.option, null);
    _ = try s.key(.right, h.option, null);
    const preedit = (try s.view()).preedit;
    try t.expectEqual(@as(u32, @intCast(try std.unicode.calcUtf16LeLen(preedit))), (try s.view()).caret);
    try expectRes(.{ .consumed = true, .beep = true }, try s.key(.right, h.option, null));
    try t.expectEqualStrings("嗎你hello big world", (try s.enter()).commit.?);
}

test "Command+arrows still commit and pass" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    try expectRes(.{ .consumed = false, .commit = "你" }, try s.key(.left, h.command, null));
}

// MARK: - Building blocks

fn atCaret(c: *composition_mod.Composition, a: std.mem.Allocator, edit: enum { c, l, tone3, tone4, erase }) !bool {
    const tail = try c.splitAtCaret(a);
    const ok = switch (edit) {
        .c => try c.append(a, 'c'),
        .l => try c.append(a, 'l'),
        .tone3 => try c.append(a, '3'),
        .tone4 => try c.append(a, '4'),
        .erase => blk: {
            c.erase();
            break :blk true;
        },
    };
    try c.joinTail(a, tail);
    return ok;
}

test "a composition edits at the caret" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: composition_mod.Composition = .{};
    for ("su3a87") |k| _ = try c.append(a, k);
    c.moveCaret(3);
    try t.expect(try atCaret(&c, a, .c));
    _ = try atCaret(&c, a, .l);
    _ = try atCaret(&c, a, .tone3);
    var labels: std.ArrayList(u8) = .empty;
    for (c.keys()) |k| try labels.append(a, k.key);
    try t.expectEqualStrings("su3cl3a87", labels.items);
    try t.expectEqual(@as(?usize, 6), c.caret);
    // A tone with nothing pending before the caret is refused, as at the end.
    try t.expect(!(try atCaret(&c, a, .tone4)));
    _ = try atCaret(&c, a, .erase);
    try t.expectEqualStrings("ㄋㄧˇㄇㄚ˙", try c.rawPhonetic(a));
    try t.expectEqual(@as(?usize, 3), c.caret);
    c.removeKeys(3, 6);
    try t.expectEqual(@as(?usize, null), c.caret); // nothing after the caret: back at the end
}

test "the layout splits a fused toneless body by decoded syllables" {
    const d = try h.Dec.init(h.tsv(
        \\ㄋㄧ|你|-5
        \\ㄏㄠ|好|-5
        \\ㄋㄧ-ㄏㄠ|你好|-3
        \\
    ));
    defer d.deinit();
    var c: composition_mod.Composition = .{};
    for ("sucl ") |k| {
        if (k == ' ') _ = try c.appendSpace(d.a()) else _ = try c.append(d.a(), k);
    }
    const top = (try d.decodeSegs(c, .{}))[0];
    try t.expectEqualStrings("你好", top.text);
    const layout = (try layout_mod.Layout.init(d.a(), c.keys(), null, top, 0)).?;
    try t.expectEqual(@as(usize, 2), layout.syllable_keys.len);
    try t.expect(layout.syllable_keys[0].eql(Range.of(0, 2)) and layout.syllable_keys[1].eql(Range.of(2, 5)));
    try t.expectEqualSlices(u32, &.{ 0, 1, 1, 2, 2, 2 }, layout.offsets);
    try t.expectEqual(@as(?usize, 2), layout.keyIndex(1));
    try t.expectEqual(@as(usize, 1), layout.boundary(2));
    try t.expectEqualSlices(usize, &.{0}, layout.word_starts);
    try t.expectEqualSlices(usize, &.{5}, layout.word_ends);
}
