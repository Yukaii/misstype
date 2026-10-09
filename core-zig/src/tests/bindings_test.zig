//! Port of tests/MisstypeCoreTests/KeyBindingsTests.swift: user key
//! bindings, the rewrite into each action's canonical key before the
//! session sees the event.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const kb = @import("../keybindings.zig");
const Harness = h.Harness;
const expectRes = h.expectRes;

const rows = h.tsv(
    \\ㄋㄧˇ|你|-5
    \\ㄋㄧˇ|妳|-6
    \\ㄋㄧˇ|尼|-7
    \\ㄋㄧˇ|泥|-8
    \\ㄏㄠˇ|好|-5
    \\ㄋㄧˇ-ㄏㄠˇ|你好|-3
    \\
);

fn expectChords(want: []const kb.Chord, got: []const kb.Chord) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expect(w.eql(g));
}

test "chord text parses and rejects keys that type" {
    try t.expect(kb.Chord.parse("cmd+comma").?.eql(kb.Chord.init(.{ .character = ',' }, kb.command)));
    try t.expect(kb.Chord.parse("ctrl+shift+J").?.eql(kb.Chord.init(.{ .character = 'j' }, kb.control | kb.shift)));
    try t.expect(kb.Chord.parse("shift+space").?.eql(kb.Chord.init(.space, kb.shift)));
    try t.expect(kb.Chord.parse("pagedown").?.eql(kb.Chord.init(.page_down, 0)));
    // Printable keys need Control/Option/Command; editing keys never bind.
    try t.expect(kb.Chord.parse("j") == null);
    try t.expect(kb.Chord.parse("shift+j") == null);
    try t.expect(kb.Chord.parse("ctrl+backspace") == null);
    try t.expect(kb.Chord.parse("hyper+j") == null);
    try t.expect(kb.Chord.parse("ctrl+") == null);
}

test "parsing keeps overrides and unbound actions" {
    const bindings = kb.Bindings.parse(
        \\# comment
        \\nextCandidate = down, ctrl+n
        \\latinRun =
        \\bogus = ctrl+x
        \\cancel = j, ctrl+g
    );
    try expectChords(&.{ kb.Chord.init(.down, 0), kb.Chord.init(.{ .character = 'n' }, kb.control) }, bindings.chordsFor(.nextCandidate));
    try expectChords(&.{}, bindings.chordsFor(.latinRun));
    try expectChords(&.{kb.Chord.init(.{ .character = 'g' }, kb.control)}, bindings.chordsFor(.cancel));
    try expectChords(&.{kb.Chord.init(.enter, 0)}, bindings.chordsFor(.commit));
}

test "a bound chord acts like the canonical key" {
    const s = try Harness.init(rows);
    defer s.deinit();
    s.engine.bindings = kb.Bindings.parse("nextCandidate = down, ctrl+n");
    try s.typed("su3");
    try expectRes(.{ .consumed = true }, try s.chr("n", h.control, "\x0e"));
    const v = try s.view();
    try t.expectEqual(@as(usize, 1), v.selected);
    try t.expect(v.keys_active);
}

test "an unbound chord commits and passes like any chord" {
    const s = try Harness.init(rows);
    defer s.deinit();
    try s.typed("su3");
    try expectRes(.{ .consumed = false, .commit = "你" }, try s.chr("n", h.control, "\x0e"));
}

test "a removed default goes to the application" {
    const s = try Harness.init(rows);
    defer s.deinit();
    s.engine.bindings = kb.Bindings.parse("nextPage = pagedown");
    try s.typed("su3");
    try expectRes(.{ .consumed = false, .commit = "你" }, try s.tab());
}

test "an explicit binding wins over another action's default" {
    // Tab now walks the syllable cursor back instead of stepping the list.
    const s = try Harness.init(rows);
    defer s.deinit();
    s.engine.bindings = kb.Bindings.parse("cursorBack = left, tab");
    try s.typed("su3cl3");
    try expectRes(.{ .consumed = true }, try s.tab());
    const v = try s.view();
    try t.expectEqualStrings("你好", v.candidates[0]);
    try t.expectEqual(@as(u32, 1), v.caret);
}

test "defaults rewrite only Tab" {
    const b: kb.Bindings = .{};
    try t.expect(b.resolve(.page_down, 0, false) == .unchanged);
    const tab = b.resolve(.tab, 0, false);
    try t.expect(tab == .rewritten and tab.rewritten.chord.key == .page_down);
}
