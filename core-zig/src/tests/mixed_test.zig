//! Port of tests/MisstypeCoreTests/MixedTests.swift and
//! MixedSessionTests.swift: English words recognized from bare keys with no
//! mode switch, and the English pass inside the session.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const english_mod = @import("../english.zig");
const Dec = h.Dec;
const Harness = h.Harness;
const expectRes = h.expectRes;

const zh_rows = h.tsv(
    \\ㄋㄧˇ|你|-5
    \\ㄏㄠˇ|好|-5
    \\ㄋㄧˇ-ㄏㄠˇ|你好|-3
    \\ㄒㄧㄝˋ-ㄒㄧㄝ˙|謝謝|-3
    \\
);

const en_rows = "python\t-12.9\nscript\t-11.0\nmeeting\t-9.2\nthe\t-3.4\n";

fn topMixed(d: *Dec, en: *const h.EnglishLexicon, typed: []const u8, opts: english_mod.PassOptions) !?[]const u8 {
    const c = try d.comp(typed);
    const pass = try english_mod.mixedPass(d.lex, d.a(), c.keys(), en, opts);
    if (pass.candidates.len == 0) return null;
    return pass.candidates[0].sentence.text;
}

// MARK: - MixedTests

test "an English word typed without a toggle is recognized" {
    const d = try Dec.init(zh_rows);
    defer d.deinit();
    const en = try h.EnglishLexicon.create(t.allocator, en_rows);
    defer en.destroy();
    try t.expectEqualStrings("你好python", (try topMixed(d, en, "su3cl3python", .{})).?);
}

test "English between Chinese and after toneless" {
    const d = try Dec.init(zh_rows);
    defer d.deinit();
    const en = try h.EnglishLexicon.create(t.allocator, en_rows);
    defer en.destroy();
    try t.expectEqualStrings("你好python謝謝", (try topMixed(d, en, "sucl3pythonvu,4vu,7", .{})).?);
}

test "a one-letter typo in an English word is corrected" {
    const d = try Dec.init(zh_rows);
    defer d.deinit();
    const en = try h.EnglishLexicon.create(t.allocator, en_rows);
    defer en.destroy();
    for ([_][]const u8{ "pyhton", "pythn", "pythoon", "pytnon" }) |typed| {
        const keys = try std.mem.concat(d.a(), u8, &.{ "su3cl3", typed });
        try t.expectEqualStrings("你好python", (try topMixed(d, en, keys, .{})).?);
    }
    const strict = (try topMixed(d, en, "su3cl3pyhton", .{ .fuzzy_english = false })).?;
    try t.expect(!std.mem.eql(u8, strict, "你好python"));
}

test "pure Chinese is never switched" {
    const d = try Dec.init(zh_rows);
    defer d.deinit();
    const en = try h.EnglishLexicon.create(t.allocator, en_rows);
    defer en.destroy();
    for ([_][]const u8{ "su3cl3", "sucl", "vu,4vu,7", "su3cl3vu,4vu,7" }) |typed| {
        const mixed = (try topMixed(d, en, typed, .{})).?;
        const plain = (try d.decodeSegs(try d.comp(typed), .{}))[0].text;
        try t.expectEqualStrings(plain, mixed);
    }
}

test "short words need length and a fair score" {
    // Two-letter runs are never English; "the" (3 letters) is allowed.
    const d = try Dec.init(zh_rows);
    defer d.deinit();
    const en = try h.EnglishLexicon.create(t.allocator, en_rows);
    defer en.destroy();
    const top = (try topMixed(d, en, "th", .{})).?;
    try t.expect(std.mem.indexOf(u8, top, "the") == null);
    try t.expectEqual(@as(usize, 0), (try en.matches(d.a(), "ths", true)).len); // below fuzzy length
}

test "edit distance one kinds" {
    const d = try Dec.init(zh_rows);
    defer d.deinit();
    const lexicon = try h.EnglishLexicon.create(t.allocator, "deadline\t-9\n");
    defer lexicon.destroy();
    for ([_][]const u8{ "deadline", "deadlin", "deadlinee", "daedline", "deadlune" }) |typed| {
        const m = try lexicon.matches(d.a(), typed, true);
        try t.expect(m.len > 0);
        try t.expectEqualStrings("deadline", m[0].word);
    }
    try t.expectEqual(@as(usize, 0), (try lexicon.matches(d.a(), "deadlnn", true)).len); // two edits
    try t.expectEqual(@as(u8, 0), (try lexicon.matches(d.a(), "deadline", true))[0].edits);
    try t.expectEqual(@as(u8, 1), (try lexicon.matches(d.a(), "daedline", true))[0].edits);
}

// MARK: - MixedSessionTests

fn makeSession(with_english: bool) !*Harness {
    const s = try Harness.init(zh_rows);
    errdefer s.deinit();
    s.settings().auto_show_candidates = true;
    if (with_english) s.engine.english_lexicon = try h.EnglishLexicon.create(t.allocator, en_rows);
    return s;
}

test "bare keys that spell an English word show as English" {
    const s = try makeSession(true);
    defer s.deinit();
    try s.typed("su3cl3python");
    try s.expectPreedit("你好python");
    try t.expectEqualStrings("你好python", (try s.enter()).commit.?);
}

test "a typo is repaired in the preview" {
    const s = try makeSession(true);
    defer s.deinit();
    try s.typed("su3cl3pyhton");
    try s.expectPreedit("你好python");
}

test "a space after English is a literal space and Chinese resumes" {
    const s = try makeSession(true);
    defer s.deinit();
    try s.typed("su3cl3python vu,4vu,7");
    try s.expectPreedit("你好python 謝謝");
}

test "pure Chinese is untouched and shows no English candidate" {
    const s = try makeSession(true);
    defer s.deinit();
    try s.typed("su3cl3");
    try s.expectPreedit("你好");
    for ((try s.view()).candidates) |c| try t.expect(std.mem.indexOf(u8, c, "python") == null);
}

test "setting off or no word list changes nothing" {
    const off = try makeSession(true);
    defer off.deinit();
    off.settings().mixed_english = false;
    try off.typed("su3cl3python");
    try t.expect(std.mem.indexOf(u8, try off.preedit(), "python") == null);
    const none = try makeSession(false);
    defer none.deinit();
    try none.typed("su3cl3python");
    try t.expect(std.mem.indexOf(u8, try none.preedit(), "python") == null);
}

test "backspace edits the keys and the reading follows" {
    const s = try makeSession(true);
    defer s.deinit();
    try s.typed("su3cl3python");
    // "pyth" is two deletions from python, so the reading falls back to
    // Zhuyin (what "pytho" does is a borderline call, not asserted).
    _ = try s.key(.backspace, 0, "\x7f");
    _ = try s.key(.backspace, 0, "\x7f");
    try t.expect(std.mem.indexOf(u8, try s.preedit(), "python") == null);
    try s.typed("on");
    try s.expectPreedit("你好python");
}

test "Option+Backspace deletes an English word read from bare keys" {
    // Issue #33: the word goes whole, not one letter per press.
    const s = try makeSession(true);
    defer s.deinit();
    try s.typed("su3cl3python");
    _ = try s.key(.backspace, h.option, "\x7f");
    try s.expectPreedit("你好");
}

test "Option+arrows over an English reading still commit and pass" {
    // No layout for the English reading (its syllables belong to a rewritten
    // composition): the pre-#33 behavior stays.
    const s = try makeSession(true);
    defer s.deinit();
    try s.typed("su3cl3python");
    try expectRes(.{ .consumed = false, .commit = "你好python" }, try s.key(.left, h.option, null));
}

test "the syllable cursor and learning stay out of English readings" {
    const s = try makeSession(true);
    defer s.deinit();
    try s.typed("su3cl3python");
    // Plain Left would enter the syllable cursor; over an English reading it
    // must not (no syllable indexes of the composition's own).
    const before = try s.gpa.dupe(u8, try s.preedit());
    defer s.gpa.free(before);
    _ = try s.key(.left, 0, "\u{F702}");
    try s.expectPreedit(before);
    try t.expectEqualStrings("你好python", (try s.enter()).commit.?);
    try t.expect(s.engine.user_lexicon.isEmpty());
}

test "English can be picked as a suggestion and the list keeps the Chinese reading" {
    // A word whose English reading wins by less than the auto margin is
    // listed beside the Chinese reading, never forced.
    const s = try makeSession(true);
    defer s.deinit();
    try s.typed("su3cl3python");
    var found = false;
    for ((try s.view()).candidates) |c| {
        if (std.mem.eql(u8, c, "你好python")) found = true;
    }
    try t.expect(found);
}

test "English survives punctuation and the Chinese that follows" {
    // Reported bug: English was recognized, then the next live conversion
    // (here a CJK comma) reverted it to Zhuyin text.
    const s = try makeSession(true);
    defer s.deinit();
    try s.typed("su3cl3python");
    try s.expectPreedit("你好python");
    _ = try s.chr(",", h.shift, "<");
    try s.expectPreedit("你好python，");
    try s.typed("su3cl3");
    try s.expectPreedit("你好python，你好");
    try t.expectEqualStrings("你好python，你好", (try s.enter()).commit.?);
}

test "capitalized English is recognized across a Shift-leading letter" {
    const s = try makeSession(true);
    defer s.deinit();
    try s.typed("su3cl3");
    _ = try s.chr("p", h.shift, "P");
    try s.typed("ython");
    try s.expectPreedit("你好Python");
    try t.expectEqualStrings("你好Python", (try s.enter()).commit.?);
}

test "the syllable being typed after English stays visible as raw Zhuyin" {
    const s = try makeSession(true);
    defer s.deinit();
    try s.typed("su3cl3python");
    try s.typed("v");
    try s.expectPreedit("你好pythonㄒ");
}
