//! Port of tests/MisstypeCoreTests/UserDictionaryTests.swift: the file
//! format, the decoder overlay (new paths, exclusions, exact restore) and
//! the Shift+arrow marking gesture that fills it.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const ud = @import("../user_dictionary.zig");
const lexicon_mod = @import("../lexicon.zig");
const Dec = h.Dec;
const Harness = h.Harness;
const Range = h.Range;
const expectRes = h.expectRes;
const UserDictionary = ud.UserDictionary;

const lexicon_rows = h.tsv(
    \\ㄋㄧˇ|你|-5
    \\ㄋㄧˇ|妳|-6
    \\ㄏㄠˇ|好|-5
    \\ㄇㄚ˙|嗎|-4
    \\ㄋㄧˇ-ㄏㄠˇ|你好|-3
    \\ㄉㄚˇ|打|-6
    \\ㄉㄨㄟˋ|對|-6
    \\ㄉㄚˋ|大|-5
    \\ㄉㄚˇ-ㄉㄨㄟˋ|打對|-7
    \\
);

fn parse(a: std.mem.Allocator, source: []const u8) !struct { UserDictionary, []const ud.Problem } {
    var problems: std.ArrayList(ud.Problem) = .empty;
    const dict = try UserDictionary.parse(a, source, &problems);
    return .{ dict, problems.items };
}

fn expectLines(want: []const usize, problems: []const ud.Problem) !void {
    try t.expectEqual(want.len, problems.len);
    for (want, problems) |w, p| try t.expectEqual(w, p.line);
}

fn session(path: []const u8) !*Harness {
    const s = try Harness.init(lexicon_rows);
    errdefer s.deinit();
    try s.useUserDictionary(path);
    return s;
}

fn markShift(s: *Harness, kind: h.KeyKind, times: usize) !void {
    for (0..times) |_| try t.expect((try s.key(kind, h.shift, null)).consumed);
}

// MARK: - File format

test "parse and serialize keep additions, weights and exclusions" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dict, const problems = try parse(a,
        \\# comment
        \\黃昱愷 ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ
        \\你好 ㄋㄧˇ-ㄏㄠˇ -1.5
        \\
        \\!打對 ㄉㄚˇ-ㄉㄨㄟˋ
    );
    try expectLines(&.{}, problems);
    try t.expectEqual(@as(usize, 2), dict.added.items.len);
    try t.expectEqualStrings("黃昱愷", dict.added.items[0].text);
    try t.expectEqualStrings("你好", dict.added.items[1].text);
    try t.expectEqual(@as(f64, -1.5), dict.added.items[1].weight);
    try t.expect(dict.isExcluded("ㄉㄚˇ-ㄉㄨㄟˋ", "打對"));
    const text = try dict.serialized(a);
    const again, _ = try parse(a, text);
    try t.expectEqual(dict.added.items.len, again.added.items.len);
    try t.expectEqual(dict.excluded.items.len, again.excluded.items.len);
    try t.expect(std.mem.indexOf(u8, text, "\n黃昱愷 ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ\n") != null); // vChewing order, space separated
}

test "vChewing userdata is read as is" {
    // Output of vChewing-userdata-generator: used to be rejected line by line.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const dict, const problems = try parse(arena.allocator(), "# 我的語彙\n免費試聽 ㄇㄧㄢˇ-ㄈㄟˋ-ㄕˋ-ㄊㄧㄥ\n談什麼原則\tㄊㄢˊ-ㄕㄜˊ-ㄇㄛ˙-ㄩㄢˊ-ㄗㄜˊ\t-3.5\n斷訊  ㄉㄨㄢˋ-ㄒㄩㄣˋ\n");
    try expectLines(&.{}, problems);
    try t.expectEqual(@as(usize, 3), dict.added.items.len);
    try t.expectEqualStrings("免費試聽", dict.added.items[0].text);
    try t.expectEqualStrings("談什麼原則", dict.added.items[1].text);
    try t.expectEqualStrings("斷訊", dict.added.items[2].text);
    try t.expectEqual(@as(f64, -3.5), dict.added.items[1].weight);
    try t.expect(dict.contains("ㄉㄨㄢˋ-ㄒㄩㄣˋ", "斷訊"));
}

test "a real generator output fixture is read" {
    // First 20 lines of vChewing-userdata-generator's idiom output (MOE 成語典
    // headwords, no personal text): a real file, not a hand-written one.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try h.readRepoFile(a, "../tests/fixtures/vchewing-userdata-idioms.txt");
    const dict, const problems = try parse(a, source);
    try expectLines(&.{}, problems);
    try t.expectEqual(@as(usize, 20), dict.added.items.len);
    try t.expect(dict.contains("ㄧˋ-ㄇㄠˊ-ㄅㄨˋ-ㄅㄚˊ", "一毛不拔"));
    try t.expect(dict.contains("ㄏㄨˊ-ㄌㄨㄣˊ-ㄊㄨㄣ-ㄗㄠˇ", "囫圇吞棗"));
}

test "import appends only new entries and keeps existing text" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const existing = "# mine\n你好 ㄋㄧˇ-ㄏㄠˇ";
    const result = try ud.importing(a,
        \\你好 ㄋㄧˇ-ㄏㄠˇ
        \\斷訊 ㄉㄨㄢˋ-ㄒㄩㄣˋ
        \\壞掉
        \\!打對 ㄉㄚˇ-ㄉㄨㄟˋ
    , existing);
    try t.expectEqual(@as(usize, 2), result.added);
    try t.expectEqual(@as(usize, 1), result.duplicates);
    try t.expectEqual(@as(usize, 1), result.skipped);
    try t.expectEqualStrings("# mine\n你好 ㄋㄧˇ-ㄏㄠˇ\n斷訊 ㄉㄨㄢˋ-ㄒㄩㄣˋ\n!打對 ㄉㄚˇ-ㄉㄨㄟˋ\n", result.text);
    try t.expectEqual(@as(usize, 0), (try ud.importing(a, "斷訊 ㄉㄨㄢˋ-ㄒㄩㄣˋ", result.text)).added); // idempotent
}

test "legacy reading-first lines still load and rewrite in the new order" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dict, const problems = try parse(a, "ㄋㄧˇ-ㄏㄠˇ\t你好\t-2\n!ㄉㄚˇ-ㄉㄨㄟˋ\t打對\n");
    try expectLines(&.{}, problems);
    try t.expect(dict.contains("ㄋㄧˇ-ㄏㄠˇ", "你好"));
    try t.expect(dict.isExcluded("ㄉㄚˇ-ㄉㄨㄟˋ", "打對"));
    const text = try dict.serialized(a);
    try t.expect(std.mem.indexOf(u8, text, "你好 ㄋㄧˇ-ㄏㄠˇ -2.0") != null);
    try t.expect(std.mem.indexOf(u8, text, "!打對 ㄉㄚˇ-ㄉㄨㄟˋ") != null);
}

test "bad lines are reported and skipped, never fatal" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const dict, const problems = try parse(arena.allocator(), h.tsv(
        \\ㄋㄧˇ-ㄏㄠˇ|你好
        \\ㄋㄧˇ-ㄏㄠˇ|你
        \\hello|world
        \\ㄋㄧˇ|你|3
        \\lonely
        \\ㄇㄚ˙|嗎
    ));
    try t.expectEqual(@as(usize, 2), dict.added.items.len);
    try t.expectEqualStrings("你好", dict.added.items[0].text);
    try t.expectEqualStrings("嗎", dict.added.items[1].text);
    try expectLines(&.{ 2, 3, 4, 5 }, problems);
}

test "adding lifts an exclusion and excluding drops the addition" {
    var dict = UserDictionary.init(t.allocator);
    defer dict.deinit();
    _ = try dict.exclude("ㄋㄧˇ-ㄏㄠˇ", "你好");
    _ = try dict.add("ㄋㄧˇ-ㄏㄠˇ", "你好", 0);
    try t.expectEqual(@as(usize, 0), dict.excluded.items.len);
    _ = try dict.exclude("ㄋㄧˇ-ㄏㄠˇ", "你好");
    try t.expectEqual(@as(usize, 0), dict.added.items.len);
    try t.expect(!(try dict.add("ㄋㄧˇ", "你好", 0))); // rejects a length mismatch
}

test "a missing file loads empty" {
    const s = try Harness.init(lexicon_rows);
    defer s.deinit();
    var tmp = try h.TmpPath.init(s.scratch.allocator(), "user_dictionary.tsv");
    defer tmp.deinit();
    try s.useUserDictionary(tmp.path);
    try t.expect(s.engine.user_dictionary.isEmpty());
}

// MARK: - Decoder overlay

test "an added word creates a path the lexicon never had" {
    const d = try Dec.init(lexicon_rows);
    defer d.deinit();
    const syllables = [_]h.Syllable{ d.syl("su", h.t3), d.syl("cl", h.t3), d.syl("a8", h.neutral) };
    try t.expectEqual(@as(usize, 2), (try d.decode(&syllables, .{}))[0].alignment.len); // 你好 + 嗎
    var dict = UserDictionary.init(t.allocator);
    defer dict.deinit();
    _ = try dict.add("ㄋㄧˇ-ㄏㄠˇ-ㄇㄚ˙", "你好嗎", 0);
    const words = try dict.words(d.a());
    try d.lex.applyUserDictionary(words.added, words.excluded);
    const top = (try d.decode(&syllables, .{}))[0];
    try t.expectEqualStrings("你好嗎", top.text);
    try t.expectEqual(@as(usize, 1), top.alignment.len); // one word, not three chars
    try t.expect(top.alignment[0].syllables.eql(Range.of(0, 3)));
}

test "an exclusion hides a built-in word and clearing restores it exactly" {
    const d = try Dec.init(lexicon_rows);
    defer d.deinit();
    const syllables = [_]h.Syllable{ d.syl("28", h.t3), d.syl("2jo", h.t4) };
    const before = try d.decode(&syllables, .{});
    try t.expectEqualStrings("打對", before[0].text);
    var dict = UserDictionary.init(t.allocator);
    defer dict.deinit();
    _ = try dict.exclude("ㄉㄚˇ-ㄉㄨㄟˋ", "打對");
    const words = try dict.words(d.a());
    try d.lex.applyUserDictionary(words.added, words.excluded);
    try t.expectEqual(@as(usize, 2), (try d.decode(&syllables, .{}))[0].alignment.len); // 打 + 對, no longer the word
    try d.lex.applyUserDictionary(&.{}, &.{});
    const after = try d.decode(&syllables, .{});
    try t.expectEqual(before.len, after.len);
    for (before, after) |b, f| {
        try t.expectEqualStrings(b.text, f.text);
        try t.expectEqual(b.score, f.score);
    }
}

test "readings lookup follows the typed tones" {
    const d = try Dec.init(lexicon_rows);
    defer d.deinit();
    const toneless = [_]h.Syllable{ d.syl("su", null), d.syl("cl", null) };
    const found = try d.lex.readingsOf(d.a(), "你好", &toneless, Range.of(0, 2), true, true);
    try t.expectEqualStrings("ㄋㄧˇ-ㄏㄠˇ", found.?);
    try t.expect((try d.lex.readingsOf(d.a(), "您好", &toneless, Range.of(0, 2), true, true)) == null);
}

// MARK: - Marking

test "Shift+arrows mark the trailing syllables and report the action" {
    const s = try Harness.init(lexicon_rows);
    defer s.deinit();
    try s.typed("su3cl3a87"); // 你好嗎
    try t.expect((try s.view()).mark == null);
    try markShift(s, .left, 2);
    var v = try s.view();
    var mark = v.mark.?;
    try t.expect(mark.range.eql(Range.of(1, 3)));
    try t.expectEqualStrings("好嗎", mark.text);
    try t.expectEqualStrings("ㄏㄠˇ-ㄇㄚ˙", mark.reading);
    try t.expectEqual(session_mark.add, mark.action);
    try t.expect(v.shows_candidates);
    try t.expectEqual(@as(usize, 0), v.candidates.len);
    try markShift(s, .left, 1);
    mark = (try s.view()).mark.?;
    try t.expect(mark.range.eql(Range.of(0, 3)));
    try markShift(s, .right, 2);
    v = try s.view();
    try t.expect(v.mark.?.range.eql(Range.of(2, 3)));
    try t.expectEqual(session_mark.too_short, v.mark.?.action);
    try markShift(s, .right, 1);
    try t.expect((try s.view()).mark == null); // collapsed back onto the anchor
}

const session_mark = @import("../session.zig").MarkAction;

test "Return files the phrase without committing and the decode uses it" {
    var tmp = try h.TmpPath.init(t.allocator, "nested/user_dictionary.tsv");
    defer tmp.deinit();
    defer t.allocator.free(tmp.path);
    const s = try session(tmp.path);
    defer s.deinit();
    try s.typed("su3cl3a87");
    try markShift(s, .left, 3);
    try t.expectEqualStrings("你好嗎", (try s.view()).mark.?.text);
    try expectRes(.{ .consumed = true }, try s.enter());
    try t.expect((try s.view()).mark == null);
    try s.expectPreedit("你好嗎"); // still composing, nothing committed
    try t.expect(s.engine.user_dictionary.contains("ㄋㄧˇ-ㄏㄠˇ-ㄇㄚ˙", "你好嗎"));
    const saved = try h.readRepoFile(t.allocator, tmp.path);
    defer t.allocator.free(saved);
    try t.expect(std.mem.indexOf(u8, saved, "你好嗎 ㄋㄧˇ-ㄏㄠˇ-ㄇㄚ˙") != null);
    // Marking the same span again offers removal, and Return undoes it.
    try markShift(s, .left, 3);
    try t.expectEqual(session_mark.remove, (try s.view()).mark.?.action);
    _ = try s.enter();
    try t.expect(s.engine.user_dictionary.isEmpty());
    try t.expectEqualStrings("你好嗎", (try s.enter()).commit.?);
}

test "a mark starts at the cursor and extends both ways" {
    const s = try Harness.init(lexicon_rows);
    defer s.deinit();
    try s.typed("su3cl3a87");
    try t.expect((try s.left()).consumed); // cursor on 嗎
    try t.expect((try s.left()).consumed); // cursor on 好
    try markShift(s, .right, 1); // 好 → mark 好嗎 starting at the cursor
    try t.expect((try s.view()).mark.?.range.eql(Range.of(1, 2)));
    try markShift(s, .right, 1);
    try t.expectEqualStrings("好嗎", (try s.view()).mark.?.text);
    try markShift(s, .left, 3);
    const mark = (try s.view()).mark.?;
    try t.expectEqualStrings("你", mark.text);
    try t.expectEqual(session_mark.too_short, mark.action);
}

test "Escape drops the mark and keeps the composition; other keys abandon it" {
    const s = try Harness.init(lexicon_rows);
    defer s.deinit();
    try s.typed("su3cl3");
    try markShift(s, .left, 2);
    try expectRes(.{ .consumed = true }, try s.key(.escape, 0, null));
    try t.expect((try s.view()).mark == null);
    try s.expectPreedit("你好");
    try markShift(s, .left, 2);
    try s.typed("a87");
    try t.expect((try s.view()).mark == null);
    try s.expectPreedit("你好嗎");
    try t.expect(s.engine.user_dictionary.isEmpty());
}

test "Return on an unusable mark beeps and leaves the dictionary alone" {
    var tmp = try h.TmpPath.init(t.allocator, "user_dictionary.tsv");
    defer tmp.deinit();
    defer t.allocator.free(tmp.path);
    const s = try session(tmp.path);
    defer s.deinit();
    try s.typed("su3cl3");
    try markShift(s, .left, 1);
    try t.expectEqual(session_mark.too_short, (try s.view()).mark.?.action);
    try expectRes(.{ .consumed = true, .beep = true }, try s.enter());
    try t.expect(s.engine.user_dictionary.isEmpty());
    try t.expect(h.readRepoFile(t.allocator, tmp.path) == error.FileNotFound);
}

test "a mark cannot span punctuation" {
    const s = try Harness.init(lexicon_rows);
    defer s.deinit();
    try s.typed("su3");
    _ = try s.chr(",", h.shift, "，");
    try s.typed("cl3");
    try markShift(s, .left, 2);
    try t.expectEqual(session_mark.unavailable, (try s.view()).mark.?.action);
    try expectRes(.{ .consumed = true, .beep = true }, try s.enter());
    try t.expect(s.engine.user_dictionary.isEmpty());
}

test "edits made outside the process load when the next composition starts" {
    var tmp = try h.TmpPath.init(t.allocator, "user_dictionary.tsv");
    defer tmp.deinit();
    defer t.allocator.free(tmp.path);
    const s = try session(tmp.path);
    defer s.deinit();
    try s.typed("su3cl3a87");
    try s.expectPreedit("你好嗎");
    _ = try s.escape();
    _ = try s.escape();
    try tmp.tmp.dir.writeFile(s.threaded.io(), .{ .sub_path = "user_dictionary.tsv", .data = "ㄋㄧˇ-ㄏㄠˇ-ㄇㄚ˙\t你好嗎\t0\n" });
    try s.typed("su3cl3a87");
    try t.expectEqual(@as(usize, 1), s.engine.user_dictionary.added.items.len);
    try t.expectEqualStrings("你好嗎", s.engine.user_dictionary.added.items[0].text);
    try s.expectPreedit("你好嗎");
}

test "conformance C13: mark and file a phrase" {
    // docs/cross-platform.md C13, on the shared conformance lexicon.
    const s = try Harness.init(h.nihao);
    defer s.deinit();
    try s.typed("su3cl3");
    try markShift(s, .left, 2);
    const v = try s.view();
    const mark = v.mark.?;
    try t.expect(mark.range.eql(Range.of(0, 2)));
    try t.expectEqualStrings("你好", mark.text);
    try t.expectEqualStrings("ㄋㄧˇ-ㄏㄠˇ", mark.reading);
    try t.expectEqual(session_mark.add, mark.action);
    try t.expectEqual(@as(usize, 0), v.candidates.len);
    try t.expect(v.shows_candidates);
    try expectRes(.{ .consumed = true }, try s.enter());
    try t.expect((try s.view()).mark == null);
    try s.expectPreedit("你好");
    try t.expect(s.engine.user_dictionary.contains("ㄋㄧˇ-ㄏㄠˇ", "你好"));
}
