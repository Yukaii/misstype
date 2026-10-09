//! Port of tests/MisstypeCoreTests/InputSessionTests.swift: replayable key
//! traces through the platform-neutral session, the rules every adapter
//! (IMK, fcitx5) inherits.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const session_mod = @import("../session.zig");
const keybindings = @import("../keybindings.zig");
const Harness = h.Harness;
const Range = h.Range;
const expectRes = h.expectRes;

const learning_lexicon = h.tsv(
    \\ㄋㄧˇ|你|-5
    \\ㄏㄠˇ|好|-5
    \\ㄏㄠˇ|郝|-9
    \\ㄋㄧˇ-ㄏㄠˇ|你好|-3
    \\
);

/// 10 homophones of ㄋㄧˇ: two pages (8 + 2) in the focused list.
fn homophoneSession() !*Harness {
    const rows = try h.homophones(t.allocator, "ㄋㄧˇ", &h.ten_ni);
    defer t.allocator.free(rows);
    const s = try Harness.init(rows);
    errdefer s.deinit();
    try s.typed("su3");
    return s;
}

fn expectRanges(want: []const Range, got: []const Range) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expect(w.eql(g));
}

test "typing converts live and Return commits the preview" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    for (try s.typeKeys("su3cl3")) |r| {
        try t.expect(r.consumed);
        try t.expect(r.commit == null);
    }
    try s.expectPreedit("你好");
    try t.expectEqual(@as(u32, 2), (try s.view()).caret);
    try s.expectRaw("ㄋㄧˇㄏㄠˇ");
    try expectRes(.{ .consumed = true, .commit = "你好" }, try s.enter());
    const v = try s.view();
    try t.expectEqualStrings("", v.preedit);
    try t.expectEqual(@as(u32, 0), v.caret);
    try t.expectEqual(@as(usize, 0), v.candidates.len);
    try t.expect(!v.shows_candidates);
}

test "an empty composition passes keys through" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try expectRes(.{ .consumed = false }, try s.enter());
    try expectRes(.{ .consumed = false }, try s.backspace());
    try expectRes(.{ .consumed = false }, try s.key(.left, 0, "\u{F702}"));
    // Space is inserted by the IME itself (never a tone without keys).
    try expectRes(.{ .consumed = true, .commit = " " }, try s.space());
}

test "backspace edits without committing" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3cl3");
    try expectRes(.{ .consumed = true }, try s.backspace());
    try s.expectPreedit("你");
    try s.typed("cl");
    try expectRes(.{ .consumed = true }, try s.key(.backspace, h.command, "\x7f"));
    try s.expectPreedit("");
    try s.expectRaw("");
}

test "tab selects and selection keys pick then learn" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    var v = try s.view();
    try t.expect(v.shows_candidates);
    try t.expect(!v.keys_active);
    // One page: Tab arms the selection keys without moving the highlight.
    try expectRes(.{ .consumed = true }, try s.tab());
    v = try s.view();
    try t.expectEqual(@as(usize, 0), v.selected);
    try t.expect(v.keys_active);
    // Home-row "d" is slot 2 in selection mode (it types ㄎ elsewhere).
    try expectRes(.{ .consumed = true }, try s.chr("d", 0, "d"));
    v = try s.view();
    try t.expectEqualStrings("尼", v.preedit);
    try t.expect(!v.keys_active);
    const r = try s.enter();
    try t.expectEqualStrings("尼", r.commit.?);
    try t.expectEqual(@as(usize, 1), s.engine.user_lexicon.count());
}

test "the panel stays closed until selection when auto-show is off" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    s.settings().auto_show_candidates = false;
    try s.typed("su3");
    try t.expect(!(try s.view()).shows_candidates);
    try expectRes(.{ .consumed = true }, try s.tab());
    const v = try s.view();
    try t.expect(v.shows_candidates);
    try t.expect(v.keys_active);
    // Esc leaves selection and the panel closes again.
    _ = try s.escape();
    try t.expect(!(try s.view()).shows_candidates);
}

test "arrows and the symbol menu open the panel when auto-show is off" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    s.settings().auto_show_candidates = false;
    try s.typed("su3");
    try expectRes(.{ .consumed = true }, try s.key(.down, 0, "\u{F701}"));
    var v = try s.view();
    try t.expect(v.shows_candidates);
    try t.expectEqual(@as(usize, 1), v.selected);
    _ = try s.escape();
    try expectRes(.{ .consumed = true }, try s.key(.up, 0, "\u{F700}"));
    try t.expect((try s.view()).shows_candidates);
    _ = try s.escape();
    _ = try s.escape();
    try s.typed("su3");
    _ = try s.chr(",", h.shift, "<");
    try t.expect(!(try s.view()).shows_candidates);
    _ = try s.tab();
    v = try s.view();
    try t.expect(v.shows_candidates);
    try t.expect(v.keys_active);
}

test "arrows still open the list after space then backspace" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    var before: std.ArrayList([]const u8) = .empty;
    for ((try s.view()).candidates) |c| try before.append(s.scratch.allocator(), try s.scratch.allocator().dupe(u8, c));
    _ = try s.space();
    _ = try s.backspace();
    try s.expectCandidates(before.items);
    try expectRes(.{ .consumed = true }, try s.key(.down, 0, "\u{F701}"));
    try t.expect((try s.view()).keys_active);
}

test "Return confirms the selection before committing when enabled" {
    {
        const s = try Harness.init(h.nihao);
        defer s.deinit();
        s.settings().return_confirms_selection = true;
        try s.typed("su3");
        _ = try s.key(.down, 0, "\u{F701}");
        try s.expectPreedit("妳");
        try expectRes(.{ .consumed = true }, try s.enter());
        try t.expect(!(try s.view()).keys_active);
        try s.expectPreedit("妳");
        try t.expectEqualStrings("妳", (try s.enter()).commit.?);
    }
    {
        // Without a selection Return still commits at once.
        const plain = try Harness.init(h.nihao);
        defer plain.deinit();
        plain.settings().return_confirms_selection = true;
        try plain.typed("su3");
        try t.expectEqualStrings("你", (try plain.enter()).commit.?);
    }
    {
        // Symbol menu: Return accepts the stepped mark, the next one commits.
        const menu = try Harness.init(h.nihao);
        defer menu.deinit();
        menu.settings().return_confirms_selection = true;
        try menu.typed("su3");
        _ = try menu.chr(",", h.shift, "<");
        _ = try menu.key(.down, 0, "\u{F701}");
        try expectRes(.{ .consumed = true }, try menu.enter());
        try t.expectEqualStrings("你、", (try menu.enter()).commit.?);
    }
}

test "Return commits at once when confirm is off" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    _ = try s.key(.down, 0, "\u{F701}");
    try t.expectEqualStrings("妳", (try s.enter()).commit.?);
}

test "a selection key picks from the second page in a sentence" {
    // Homophones past the decoder's per-node cap (page 2 of the picker)
    // must still win once picked; they used to be pinned but unreachable.
    const rows = try h.homophones(t.allocator, "ㄋㄧˇ", &h.ten_ni);
    defer t.allocator.free(rows);
    const all = try std.mem.concat(t.allocator, u8, &.{ rows, "ㄏㄠˇ\t好\t-5\n" });
    defer t.allocator.free(all);
    const s = try Harness.init(all);
    defer s.deinit();
    try s.typed("su3cl3");
    _ = try s.key(.left, 0, null);
    _ = try s.key(.left, 0, null);
    for (0..8) |_| _ = try s.down();
    try t.expectEqual(@as(usize, 8), (try s.view()).selected);
    try t.expect((try s.chr("a", 0, "a")).consumed);
    try s.expectPreedit("溺好");
}

test "page keys flip pages keeping the row" {
    const s = try homophoneSession();
    defer s.deinit();
    try expectRes(.{ .consumed = true }, try s.key(.page_down, 0, null));
    var v = try s.view();
    try t.expectEqual(@as(usize, 8), v.selected);
    try t.expect(v.keys_active);
    _ = try s.key(.page_down, 0, null); // wraps to page 1, row 0
    v = try s.view();
    try t.expectEqual(@as(usize, 0), v.selected);
    try t.expectEqual(@as(usize, 11), v.candidates.len); // 10 homophones + the raw fallback
    for (0..5) |_| _ = try s.down(); // row 5
    _ = try s.key(.page_down, 0, null); // page 2 has 3 rows: clamp to last
    try t.expectEqual(@as(usize, 10), (try s.view()).selected);
    _ = try s.key(.page_up, 0, null);
    try t.expectEqual(@as(usize, 2), (try s.view()).selected);
}

test "minus and equals page only in selection mode" {
    const s = try homophoneSession();
    defer s.deinit();
    // Not selecting: `-` is ㄦ and types.
    _ = try s.chr("-", 0, "-");
    var v = try s.view();
    try t.expect(!v.keys_active);
    try t.expect(std.mem.endsWith(u8, v.preedit, "ㄦ"));
    _ = try s.key(.backspace, 0, null);
    _ = try s.down();
    _ = try s.chr("=", 0, "=");
    try t.expectEqual(@as(usize, 9), (try s.view()).selected);
    _ = try s.chr("-", 0, "-");
    v = try s.view();
    try t.expectEqual(@as(usize, 1), v.selected);
}

test "page size sets rows, selection keys and paging" {
    const rows = try h.homophones(t.allocator, "ㄋㄧˇ", &h.ten_ni);
    defer t.allocator.free(rows);
    const s = try Harness.init(rows);
    defer s.deinit();
    s.settings().page_size = 5;
    try s.typed("su3");
    _ = try s.down(); // row 1
    var v = try s.view();
    try t.expectEqual(@as(usize, 5), v.page_size);
    try t.expectEqual(@as(usize, 5), v.selection_keys.len);
    for ([_][]const u8{ "a", "s", "d", "f", "g" }, v.selection_keys) |want, got| try t.expectEqualStrings(want, got);
    _ = try s.key(.page_down, 0, null);
    try t.expectEqual(@as(usize, 6), (try s.view()).selected);
    // Selection keys address the visible page of 5: `d` is row 3 → 7.
    _ = try s.chr("d", 0, "d");
    v = try s.view();
    try t.expectEqual(@as(usize, 7), v.selected);
    try t.expect(!v.keys_active);
    try t.expectEqualStrings(v.candidates[7], v.preedit);
    // Out-of-range sizes clamp.
    try t.expectEqual(@as(usize, 10), session_mod.clampPageSize(99));
    try t.expectEqual(@as(usize, 4), session_mod.clampPageSize(0));
}

test "a selection key wins over the page key" {
    const rows = try h.homophones(t.allocator, "ㄋㄧˇ", &h.ten_ni);
    defer t.allocator.free(rows);
    const s = try Harness.init(rows);
    defer s.deinit();
    try s.engine.setCandidateKeys("asdfghj-");
    try s.typed("su3");
    _ = try s.down();
    _ = try s.chr("-", 0, "-"); // slot 7, not previous page
    const v = try s.view();
    try t.expectEqual(@as(usize, 7), v.selected);
    try t.expect(!v.keys_active);
}

test "a page key on one page enters selection then beeps" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    try expectRes(.{ .consumed = true }, try s.key(.page_down, 0, null));
    const v = try s.view();
    try t.expect(v.keys_active);
    try t.expectEqual(@as(usize, 0), v.selected);
    try expectRes(.{ .consumed = true, .beep = true }, try s.key(.page_down, 0, null));
}

test "tab and shift-tab turn pages" {
    const s = try homophoneSession();
    defer s.deinit();
    try expectRes(.{ .consumed = true }, try s.tab());
    var v = try s.view();
    try t.expectEqual(@as(usize, 8), v.selected);
    try t.expect(v.keys_active);
    _ = try s.key(.tab, h.shift, "\t");
    v = try s.view();
    try t.expectEqual(@as(usize, 0), v.selected);
}

test "a page key passes through without a composition" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try expectRes(.{ .consumed = false }, try s.key(.page_down, 0, null));
}

test "escape leaves selection first then clears" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    _ = try s.key(.down, 0, "\u{F701}");
    try s.expectPreedit("妳");
    try expectRes(.{ .consumed = true }, try s.escape());
    try s.expectPreedit("妳");
    try t.expect(!(try s.view()).keys_active);
    try expectRes(.{ .consumed = true }, try s.escape());
    try s.expectPreedit("");
}

test "punctuation and shift-Latin stay inside the composition" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    try expectRes(.{ .consumed = true }, try s.chr(",", h.shift, "<"));
    try s.expectPreedit("你，");
    try expectRes(.{ .consumed = true }, try s.chr("a", h.shift, "A"));
    try s.expectPreedit("你，A");
    try t.expectEqualStrings("你，A", (try s.enter()).commit.?);
}

test "view segments tile the preedit at word boundaries" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3`hi");
    // 你 | hi : the decoded word and the Latin run underline separately.
    try s.expectPreedit("你hi");
    var v = try s.view();
    try expectRanges(&.{ Range.of(0, 1), Range.of(1, 3) }, v.segments);
    try t.expect(v.focus == null);
    _ = try s.key(.escape, 0, null);
    try s.typed("`su3cl3"); // Esc keeps the run open; the backtick closes it
    v = try s.view();
    try expectRanges(&.{Range.of(0, 2)}, v.segments); // one word 你好
    _ = try s.key(.left, 0, null);
    v = try s.view();
    try t.expect(v.focus != null and v.focus.?.eql(Range.of(0, 2)));
}

test "a backtick opens a Latin run" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3`hi");
    try s.expectPreedit("你hi");
    // Letters and digits stay latin (a tone key is just a digit here; the run
    // used to end on it, which turned "mp3" into Zhuyin). The closing
    // backtick returns to Zhuyin.
    try expectRes(.{ .consumed = true }, try s.chr("3", 0, "3"));
    try s.expectPreedit("你hi3");
    try s.typed("`cl3");
    try s.expectPreedit("你hi3好");
}

test "periods inside a Latin run stay literal" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    // `.` is ㄡ in Zhuyin but plain text inside a latin run ("..." used to
    // become 歐歐歐).
    try s.typed("su3`hi...");
    try s.expectPreedit("你hi...");
}

test "a comma and friends inside a Latin run stay literal" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    // `,` is ㄝ (誒) in Zhuyin; mid-run it is the comma of the sentence.
    try s.typed("su3`hi, a-b/c;");
    try s.expectPreedit("你hi, a-b/c;");
    try t.expect(s.session.latinActive());
    // Shift+, is still the full-width comma and ends the run.
    _ = try s.chr(",", h.shift, "<");
    try s.expectPreedit("你hi, a-b/c;，");
}

test "backspace inside a Latin run keeps the run" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3`hx");
    try expectRes(.{ .consumed = true }, try s.backspace());
    try s.typed("i");
    try s.expectPreedit("你hi");
    // Deleting the whole word keeps the run open for retyping.
    _ = try s.backspace();
    _ = try s.backspace();
    try s.typed("yo");
    try s.expectPreedit("你yo");
    // Ended by punctuation, then edited back into the word: the run resumes.
    _ = try s.chr(",", h.shift, "<");
    try s.expectPreedit("你yo，");
    _ = try s.backspace();
    try s.typed("u");
    try s.expectPreedit("你you");
}

test "backspace after a fused toneless run deletes one syllable" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    // Toneless continuous typing, then one first-tone Space: the raw keys are
    // a single fused body (ㄋㄧㄏㄠ + Space) but the user typed two syllables,
    // so one Backspace must not drop both.
    try s.typed("sucl ");
    try s.expectPreedit("你好");
    _ = try s.backspace();
    try s.expectRaw("ㄋㄧ");
}

test "a long composition commits the settled head in chunks" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    s.settings().auto_commit_syllables = 6;
    var committed: std.ArrayList(u8) = .empty;
    defer committed.deinit(t.allocator);
    var chunks: usize = 0;
    for (0..20) |_| {
        for (try s.typeKeys("su3")) |r| {
            try t.expect(r.consumed);
            if (r.commit) |text| {
                try committed.appendSlice(t.allocator, text);
                chunks += 1;
            }
        }
        // The composition stays bounded and keeps its look-ahead tail.
        try t.expect(try std.unicode.utf8CountCodepoints(try s.raw()) <= 6 * 3);
    }
    try t.expect(chunks > 1); // one chunk per overflow, not one big commit
    try t.expect(committed.items.len != 0);
    try t.expect(try std.unicode.utf8CountCodepoints(try s.preedit()) >= 3);
    // Chunks plus the final Return reproduce everything that was typed.
    const rest = (try s.enter()).commit orelse "";
    try committed.appendSlice(t.allocator, rest);
    const want = try std.mem.concat(t.allocator, u8, &@as([20][]const u8, @splat("你")));
    defer t.allocator.free(want);
    try t.expectEqualStrings(want, committed.items);
}

test "auto-commit off keeps everything in the composition" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    s.settings().auto_commit_syllables = 0;
    for (0..10) |_| {
        for (try s.typeKeys("su3")) |r| try t.expect(r.commit == null);
    }
    const want = try std.mem.concat(t.allocator, u8, &@as([10][]const u8, @splat("你")));
    defer t.allocator.free(want);
    try s.expectPreedit(want);
}

test "unresolved tail does not strand an exact head after earlier chunks" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    s.settings().auto_commit_syllables = 6;
    s.settings().repair_strength = .off;
    for (0..8) |_| try s.typed("su3");
    // Simulate a long tail entered while auto-commit is disabled, then turn
    // it back on. The last syllable is absent from this synthetic lexicon.
    s.settings().auto_commit_syllables = 0;
    for (0..8) |_| try s.typed("su3");
    try s.typed("g0");
    s.settings().auto_commit_syllables = 6;
    const r = try s.chr("4", 0, "4");
    try t.expect(r.commit != null);
    try t.expect(std.mem.indexOf(u8, r.commit.?, "ㄕ") == null);
    try t.expect(std.mem.endsWith(u8, try s.raw(), "ㄕㄢˋ"));
    try t.expect(s.session.candidates[s.session.selected].unresolved > 0);
}

test "chunking preserves inline Latin punctuation and spaces" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    s.settings().auto_commit_syllables = 6;
    var committed: std.ArrayList(u8) = .empty;
    defer committed.deinit(t.allocator);
    for (0..5) |_| for (try s.typeKeys("su3cl3`hello `su3cl3su3cl3")) |r| {
        if (r.commit) |text| try committed.appendSlice(t.allocator, text);
    };
    try t.expect(committed.items.len > 0);
    try committed.appendSlice(t.allocator, (try s.enter()).commit orelse "");
    const want = try std.mem.concat(t.allocator, u8, &@as([5][]const u8, @splat("你好hello 你好你好")));
    defer t.allocator.free(want);
    try t.expectEqualStrings(want, committed.items);
}

test "auto-commit keeps a repaired head available for correction" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    s.settings().auto_commit_syllables = 6;
    for (0..10) |_| for (try s.typeKeys("wu3")) |r| try t.expect(r.commit == null);
    try t.expect(s.session.candidates[s.session.selected].repairs > 0);
}

test "chunking resumes after a manually shifted Latin run" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    s.settings().auto_commit_syllables = 6;
    var committed: std.ArrayList(u8) = .empty;
    defer committed.deinit(t.allocator);
    for (0..4) |_| {
        for (try s.typeKeys("su3cl3")) |r| if (r.commit) |text| try committed.appendSlice(t.allocator, text);
        for ("hello") |ch| {
            const label = [_]u8{ch};
            const r = try s.chr(&label, h.shift, &label);
            if (r.commit) |text| try committed.appendSlice(t.allocator, text);
        }
        for (try s.typeKeys(" su3cl3su3cl3")) |r| if (r.commit) |text| try committed.appendSlice(t.allocator, text);
    }
    try t.expect(committed.items.len > 0);
    try committed.appendSlice(t.allocator, (try s.enter()).commit orelse "");
    try t.expect(std.mem.indexOf(u8, committed.items, "hello") != null);
}

test "smart quotes open then close and nest with shift" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    _ = try s.chr("'", 0, "'");
    try s.typed("su3cl3");
    try s.expectPreedit("「你好");
    _ = try s.chr("'", 0, "'");
    try s.expectPreedit("「你好」");
    // Balanced again, so the next one opens; Shift pairs 『』 on its own.
    _ = try s.chr("'", h.shift, "\"");
    _ = try s.chr("'", h.shift, "\"");
    try s.expectPreedit("「你好」『』");
    // The direct bracket keys keep working.
    _ = try s.chr("[", 0, "[");
    try s.expectPreedit("「你好」『』『");
}

test "the symbol menu steps, picks and accepts on any other key" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    _ = try s.chr(",", h.shift, "<");
    try s.expectPreedit("你，");
    var v = try s.view();
    try t.expect(v.shows_candidates);
    for ([_][]const u8{ "，", "、", "；" }, v.candidates[0..3]) |want, got| try t.expectEqualStrings(want, got);
    try t.expect(!v.keys_active);
    // Down swaps the mark live and arms the selection keys.
    _ = try s.key(.down, 0, "\u{F701}");
    try s.expectPreedit("你、");
    try t.expect((try s.view()).keys_active);
    // Selection key `d` = slot 2 on the page: 「；」.
    try expectRes(.{ .consumed = true }, try s.chr("d", 0, "d"));
    try s.expectPreedit("你；");
    v = try s.view();
    try t.expect(!v.shows_candidates);
    try t.expectEqualStrings("你；", (try s.enter()).commit.?);
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |c| if (std.mem.eql(u8, c, item)) return true;
    return false;
}

test "the symbol menu: any other key accepts, Esc keeps, a click picks" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    _ = try s.chr(".", h.shift, ">");
    try s.expectPreedit("你。");
    // Typing on accepts the mark and composes normally.
    try s.typed("cl3");
    try s.expectPreedit("你。好");
    try t.expect(!contains((try s.view()).candidates, "．"));
    // Esc closes the menu but keeps the composition.
    _ = try s.chr("1", h.shift, "!");
    try t.expect(contains((try s.view()).candidates, "‼"));
    try expectRes(.{ .consumed = true }, try s.escape());
    try s.expectPreedit("你。好！");
    try t.expect(!contains((try s.view()).candidates, "‼"));
    // Panel click picks a row.
    _ = try s.chr("/", h.shift, "?");
    try s.session.pick(1);
    try s.expectPreedit("你。好！⁇");
    try t.expect(!(try s.view()).shows_candidates);
}

test "the syllable cursor focuses a word" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3cl3");
    try expectRes(.{ .consumed = true, .beep = true }, try s.key(.right, 0, "\u{F703}"));
    try expectRes(.{ .consumed = true }, try s.key(.left, 0, "\u{F702}"));
    // The cursor shows the focused list but types there (issue #32);
    // Tab arms the selection keys.
    var v = try s.view();
    try t.expect(!v.keys_active);
    try t.expect(v.shows_candidates);
    try t.expectEqualStrings("你好", v.candidates[0]);
    try t.expectEqual(@as(u32, 1), v.caret);
    try expectRes(.{ .consumed = true }, try s.tab());
    try t.expect((try s.view()).keys_active);
    try expectRes(.{ .consumed = true }, try s.key(.right, 0, "\u{F703}"));
    v = try s.view();
    try t.expectEqual(@as(u32, 2), v.caret);
}

test "Return on an unchanged focused word does not learn" {
    // User report 2026-10-06: walking the cursor back and pressing Return on
    // each word confirmed the decoder's own split, and learning stored it
    // (如故|ㄛ -> 喔). A pin that changes nothing must not train.
    for ([_]bool{ true, false }) |confirms| {
        const s = try Harness.init(learning_lexicon);
        defer s.deinit();
        s.settings().return_confirms_selection = confirms;
        try s.typed("su3cl3");
        _ = try s.key(.left, 0, "\u{F702}");
        try t.expectEqualStrings("你好", (try s.view()).candidates[0]);
        var result = try s.enter();
        if (confirms) result = try s.enter();
        try t.expectEqualStrings("你好", result.commit.?);
        try t.expectEqual(@as(usize, 0), s.engine.user_lexicon.count());
    }
}

test "a focused pick that changes text still learns only that word" {
    const s = try Harness.init(learning_lexicon);
    defer s.deinit();
    s.settings().cursor_candidates = .ending_at;
    try s.typed("su3cl3");
    _ = try s.key(.left, 0, "\u{F702}");
    try s.expectCandidates(&.{ "你好", "好", "郝" });
    _ = try s.tab();
    _ = try s.chr("d", 0, "d"); // row 3: 郝
    try s.expectPreedit("你郝");
    try t.expectEqualStrings("你郝", (try s.enter()).commit.?);
    const entries = s.engine.user_lexicon.entries;
    try t.expectEqual(@as(usize, 1), entries.count());
    try t.expectEqualStrings("你|ㄏㄠ", entries.keys()[0]);
    try t.expect(entries.values()[0].contains("郝"));
}

test "a cursor before the caret lists words ending there" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    s.settings().cursor_candidates = .ending_at;
    try s.typed("su3cl3");
    // First Left: caret stays after 好, the words ending there are listed.
    _ = try s.key(.left, 0, "\u{F702}");
    try s.expectCandidates(&.{ "你好", "好" });
    var v = try s.view();
    try t.expectEqual(@as(usize, 0), v.selected);
    try t.expectEqual(@as(u32, 2), v.caret);
    // Second Left: words ending after 你; 你好 does not, so 你 is highlighted.
    _ = try s.key(.left, 0, "\u{F702}");
    try s.expectCandidates(&.{ "你", "妳", "尼", "泥" });
    v = try s.view();
    try t.expectEqual(@as(u32, 1), v.caret);
    _ = try s.tab();
    _ = try s.chr("d", 0, "d"); // row 3: 尼
    try s.expectPreedit("尼好");
}

test "a cursor after the caret lists words starting there" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    s.settings().cursor_candidates = .beginning_at;
    try s.typed("su3cl3");
    _ = try s.key(.left, 0, "\u{F702}");
    try s.expectCandidates(&.{"好"});
    try t.expectEqual(@as(u32, 1), (try s.view()).caret);
    _ = try s.key(.left, 0, "\u{F702}");
    const v = try s.view();
    try t.expectEqualStrings("你好", v.candidates[0]);
    try t.expect(!contains(v.candidates, "好"));
    try t.expectEqual(@as(u32, 0), v.caret);
}

test "chords and caps lock commit then pass through" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    try expectRes(.{ .consumed = false, .commit = "你" }, try s.chr("c", h.command, "c"));
    try s.typed("su3");
    try expectRes(.{ .consumed = false, .commit = "你" }, try s.chr("a", h.caps_lock, "A"));
    // A bare modifier press is swallowed and leaves the composition alone.
    try s.typed("su3");
    try expectRes(.{ .consumed = true }, try s.key(.modifier, h.control, null));
    try s.expectPreedit("你");
}

test "Shift+Space toggles English, committing first" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    try expectRes(.{ .consumed = true, .commit = "你", .mode_changed = true }, try s.key(.space, h.shift, " "));
    try t.expect(s.engine.english);
    try expectRes(.{ .consumed = false }, try s.chr("s", 0, "s"));
    _ = try s.key(.space, h.shift, " ");
    try t.expect(!s.engine.english);
}

test "a lone Shift tap toggles unless disabled" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try expectRes(.{ .consumed = true }, try s.send(.{ .kind = .shift_left, .mods = h.shift, .timestamp = 100 }));
    try expectRes(.{ .consumed = true, .mode_changed = true }, try s.send(.{ .kind = .shift_left, .release = true, .timestamp = 100.1 }));
    try t.expect(s.engine.english);
    // Shift+letter in between is a capital, not a tap.
    _ = try s.send(.{ .kind = .shift_left, .mods = h.shift, .timestamp = 101 });
    _ = try s.send(.{ .kind = .character, .label = "a", .mods = h.shift, .text = "A", .timestamp = 101.05 });
    try t.expect(!(try s.send(.{ .kind = .shift_left, .release = true, .timestamp = 101.1 })).mode_changed);
    s.settings().shift_toggle = false;
    _ = try s.send(.{ .kind = .shift_right, .mods = h.shift, .timestamp = 102 });
    try t.expect(!(try s.send(.{ .kind = .shift_right, .release = true, .timestamp = 102.1 })).mode_changed);
}

test "the Shift+Space toggle can be turned off" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    s.engine.bindings = keybindings.Bindings.parse("toggleEnglish =\n");
    try s.typed("su3");
    const result = try s.key(.space, h.shift, " ");
    try t.expect(!result.mode_changed);
    try t.expect(result.commit == null);
    try t.expect(!s.engine.english);
    try t.expectEqualStrings("你", (try s.enter()).commit.?);
}

test "a Latin run survives Escape and delete-all until a Shift tap closes it" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    try t.expect((try s.tapShift(100)).latin_toggled);
    try s.typed("hi");
    // Esc wipes the text but the user is still typing English.
    _ = try s.key(.escape, 0, null);
    try t.expect(s.session.latinActive());
    try s.typed("ok");
    try s.expectPreedit("ok");
    // Delete-all, then one more Backspace on the empty composition.
    _ = try s.key(.backspace, 0, null);
    _ = try s.key(.backspace, 0, null);
    _ = try s.key(.backspace, 0, null);
    try t.expect(s.session.latinActive());
    try s.typed("a");
    try s.expectPreedit("a");
    // With the run open and nothing composed, the tap closes the run (no
    // global flip).
    _ = try s.key(.escape, 0, null);
    const closed = try s.tapShift(101);
    try t.expect(closed.latin_toggled);
    try t.expect(!closed.mode_changed);
    try t.expect(!s.session.latinActive());
}

test "a Shift tap rereads stranded Zhuyin as English keys" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    // "world is" typed in Zhuyin mode: nothing decodes, raw Zhuyin stays.
    try s.typed("world is");
    try t.expect(!std.mem.eql(u8, try s.raw(), "world is"));
    try expectRes(.{ .consumed = true, .latin_toggled = true }, try s.tapShift(100));
    try s.expectPreedit("world is");
    try t.expect(s.session.latinActive());
    // The run stays open: more English keeps typing verbatim.
    try s.typed("ok");
    try s.expectPreedit("world isok");
    try t.expectEqualStrings("world isok", (try s.enter()).commit.?);
}

test "a Shift tap after decoded Chinese still just opens a run" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3c"); // 你 + one raw syllable in progress
    try t.expect((try s.tapShift(100)).latin_toggled);
    try s.expectPreedit("你ㄏ");
    try s.expectRaw("ㄋㄧˇㄏ");
}

test "a lone Shift tap mid-composition opens a Latin run without committing" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    _ = try s.send(.{ .kind = .shift_left, .mods = h.shift, .timestamp = 100 });
    // No commit, no global mode flip.
    try expectRes(.{ .consumed = true, .latin_toggled = true }, try s.send(.{ .kind = .shift_left, .release = true, .timestamp = 100.1 }));
    try t.expect(s.session.latinActive());
    try t.expect(!s.engine.english);
    try s.typed("hi");
    try s.expectPreedit("你hi");
    // A second tap closes the run: letters are Zhuyin again.
    _ = try s.send(.{ .kind = .shift_left, .mods = h.shift, .timestamp = 101 });
    try t.expect((try s.send(.{ .kind = .shift_left, .release = true, .timestamp = 101.1 })).latin_toggled);
    try t.expect(!s.session.latinActive());
    try s.typed("cl3");
    try s.expectPreedit("你hi好");
    try t.expectEqualStrings("你hi好", (try s.enter()).commit.?);
    // With nothing composed the tap still flips 中/英.
    _ = try s.send(.{ .kind = .shift_left, .mods = h.shift, .timestamp = 102 });
    try t.expect((try s.send(.{ .kind = .shift_left, .release = true, .timestamp = 102.1 })).mode_changed);
}

test "a panel pick and a host commit" {
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3");
    try s.session.pick(3);
    try s.expectPreedit("泥");
    try t.expectEqualStrings("泥", (try s.session.commit()).?);
    try t.expect((try s.session.commit()) == null);
}
