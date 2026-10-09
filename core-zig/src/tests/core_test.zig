//! Port of tests/MisstypeCoreTests/CoreTests.swift: composition editing,
//! decoding, repair, learning, cursor selection and the Shift-tap tracker.
//!
//! Tone arguments are tone KEYS (`h.t3` = ˇ, `h.first_tone` = Swift `""`).
//! Not ported because the Zig core has no counterpart: ContextBigrams,
//! CursorReplay and CandidateDisplay (dev/UI helpers that never shipped in
//! the core; see docs/zig-port.md, "Retiring the Swift core").

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const keyboard = @import("../keyboard.zig");
const punctuation = @import("../punctuation.zig");
const composition_mod = @import("../composition.zig");
const session_mod = @import("../session.zig");
const user_lexicon = @import("../user_lexicon.zig");
const candidate_mod = @import("../candidate.zig");
const Dec = h.Dec;
const Range = h.Range;
const UserLexicon = user_lexicon.UserLexicon;
const expectStrings = h.expectStrings;
const expectTop = h.expectTop;

const main_rows = h.tsv(
    \\ㄋㄧˇ|你|-5
    \\ㄋㄧˇ|妳|-6
    \\ㄋㄧˇ|尼|-7
    \\ㄋㄧˇ|泥|-8
    \\ㄏㄠˇ|好|-5
    \\ㄋㄧˇ-ㄏㄠˇ|你好|-3
    \\ㄇㄚ˙|嗎|-4
    \\ㄒㄧㄝˋ-ㄒㄧㄝ˙|謝謝|-3
    \\ㄒㄩㄝˊ-ㄕㄥ|學生|-3
    \\
);

fn dec() !*Dec {
    return Dec.init(main_rows);
}

const boundary_rows = h.tsv(
    \\ㄉㄚˋ|大|-3
    \\ㄉㄚˇ|打|-6
    \\ㄉㄨㄟˋ|對|-4
    \\ㄉㄚˇ-ㄉㄨㄟˋ|打對|-12
    \\ㄉㄞˋ|代|-3
    \\ㄉㄞˋ|帶|-6
    \\ㄑㄧㄢˊ|錢|-5
    \\ㄅㄠ|苞|-4
    \\ㄅㄠ|包|-5
    \\ㄉㄞˋ-ㄑㄧㄢˊ|帶錢|-9
    \\ㄑㄧㄢˊ-ㄅㄠ|錢包|-8
    \\
);

fn approx(want: f64, got: f64) !void {
    try t.expectApproxEqAbs(want, got, 1e-9);
}

fn keysOf(c: composition_mod.Composition, a: std.mem.Allocator) ![]const []const u8 {
    // Swift `rawKeys`: Zhuyin keys as labels, Latin as "L:x".
    var out: std.ArrayList([]const u8) = .empty;
    for (c.keys()) |k| switch (k) {
        .key => |b| try out.append(a, try a.dupe(u8, &.{b})),
        .latin => |b| try out.append(a, try std.fmt.allocPrint(a, "L:{c}", .{b})),
        .literal => |i| try out.append(a, punctuation.literals[i]),
    };
    return out.items;
}

// MARK: - Composition

test "tone keys and space end syllables" {
    const d = try dec();
    defer d.deinit();
    const input = try d.comp("su3cl3a87");
    try expectStrings(&.{ "ㄋㄧˇ", "ㄏㄠˇ", "ㄇㄚ˙" }, try d.readings((try input.parsed(d.a())).complete));
    const spaced = try d.comp("vm,6g/ ");
    try expectStrings(&.{ "ㄒㄩㄝˊ", "ㄕㄥ" }, try d.readings((try spaced.parsed(d.a())).complete));
}

test "backspace restores pending phonetic evidence" {
    const d = try dec();
    defer d.deinit();
    var input = try d.comp("su3");
    input.backspace();
    try expectStrings(&.{ "s", "u" }, try keysOf(input, d.a()));
    try t.expectEqualStrings("ㄋㄧ", try input.pendingText(d.a()));
    try t.expectEqual(@as(usize, 0), (try input.parsed(d.a())).complete.len);
}

test "a pending syllable waits for a tone or the commit" {
    const d = try dec();
    defer d.deinit();
    const input = try d.comp("su3cl");
    try t.expectEqual(@as(usize, 1), (try d.syllables(input, false)).len);
    const finishing = try d.syllables(input, true);
    try t.expectEqual(@as(usize, 2), finishing.len);
    try expectTop(try d.decode(finishing, .{}), "你好");
}

test "composes an unlisted sentence from multiple words" {
    const d = try dec();
    defer d.deinit();
    const input = try d.comp("su3cl3a87vu,4vu,7");
    const result = try d.decode(try d.syllables(input, true), .{});
    try expectTop(result, "你好嗎謝謝");
    try t.expectEqual(@as(i32, 0), result[0].unresolved);
    try t.expect(result.len <= 16);
}

test "fuzzy repair rescues an invalid syllable without a tone" {
    const d = try dec();
    defer d.deinit();
    const input = try d.comp("du"); // ㄎㄧ has adjacent ㄋㄧ as a hypothesis
    const syllables = try d.syllables(input, true);
    const result = try d.decode(syllables, .{});
    try expectTop(result, "你");
    try t.expectEqual(@as(i32, 1), result[0].repairs);
    try expectTop(try d.decode(syllables, .{ .fuzzy = false }), "ㄎㄧ");
}

test "valid syllables remain exact" {
    const d = try dec();
    defer d.deinit();
    const result = try d.decode(try d.syllables(try d.comp("su3"), true), .{});
    try expectTop(result, "你");
    try t.expectEqual(@as(i32, 0), result[0].repairs);
}

test "unknown input is preserved" {
    const d = try dec();
    defer d.deinit();
    const result = try d.decode(try d.syllables(try d.comp("zzzz3"), true), .{});
    try expectTop(result, "ㄈㄈㄈㄈˇ");
    try t.expectEqual(@as(i32, 1), result[0].unresolved);
}

test "a space-terminated syllable leaves the tone to the engine" {
    const d = try dec();
    defer d.deinit();
    const input = try d.comp("su cl ");
    const parsed = try input.parsed(d.a());
    // Swift's parsed.complete holds tone-terminated syllables only; a space
    // is a first-tone terminator here.
    try expectStrings(&.{ "ㄋㄧ", "ㄏㄠ" }, try d.bases(parsed.complete));
    const result = try d.decodeParsed(input, .{});
    try expectTop(result, "你好");
    try t.expectEqual(@as(i32, 0), result[0].unresolved);
}

test "continuous toneless input segments without spaces" {
    const d = try dec();
    defer d.deinit();
    const input = try d.comp("sucl");
    try t.expectEqual(@as(usize, 0), (try input.parsed(d.a())).complete.len);
    const result = try d.decodeParsed(input, .{});
    try expectTop(result, "你好");
    try t.expectEqual(@as(i32, 0), result[0].unresolved);
}

test "toned input still matches exactly" {
    const d = try dec();
    defer d.deinit();
    const result = try d.decodeParsed(try d.comp("su3cl3"), .{});
    try expectTop(result, "你好");
    try t.expectEqual(@as(i32, 0), result[0].repairs);
}

test "delete-last-syllable removes one boundary chunk" {
    const d = try dec();
    defer d.deinit();
    var input = try d.comp("su3cl3");
    input.deleteLastSyllable();
    try expectStrings(&.{ "s", "u", "3" }, try keysOf(input, d.a()));
    input.deleteLastSyllable();
    try t.expect(input.isEmpty());
}

test "the CJK punctuation table" {
    const P = punctuation;
    const cases = [_]struct { []const u8, bool, ?[]const u8 }{
        .{ ",", true, "，" },
        .{ ".", true, "。" },
        .{ "/", true, "？" },
        .{ "1", true, "！" },
        .{ ";", true, "：" },
        .{ "'", false, "「" },
        .{ "'", true, "」" },
        .{ "[", false, "『" },
        .{ "]", false, "』" },
        .{ "\\", false, "、" },
        .{ "\\", true, "·" },
        .{ "-", true, "——" },
        .{ "-", false, null },
        .{ ",", false, null },
        .{ "/", false, null },
        .{ ";", false, null },
        .{ "a", false, null },
        .{ "a", true, null },
    };
    for (cases) |c| {
        const got = P.output(c[0], c[1], false);
        if (c[2]) |want| {
            try t.expect(got != null);
            try t.expectEqualStrings(want, got.?);
        } else try t.expect(got == null);
    }
    try t.expectEqualStrings("；", P.output(";", false, true).?);
    // Ctrl/Cmd must not hijack anything else; plain letters untouched.
    try t.expect(P.output("a", false, true) == null);
}

test "the full-width Shift layer" {
    // 大千 Shift layer: digit row + = [ ] ` (selection moved off Shift+digit).
    const expected = [_][2][]const u8{
        .{ "1", "！" },
        .{ "2", "＠" },
        .{ "3", "＃" },
        .{ "4", "＄" },
        .{ "5", "％" },
        .{ "6", "︿" },
        .{ "7", "＆" },
        .{ "8", "＊" },
        .{ "9", "（" },
        .{ "0", "）" },
        .{ "=", "＋" },
        .{ "[", "｛" },
        .{ "]", "｝" },
        .{ "`", "～" },
    };
    for (expected) |e| {
        try t.expectEqualStrings(e[1], punctuation.output(e[0], true, false).?);
        try t.expect(punctuation.isLiteral(e[1]));
    }
    // Unshifted digits stay Zhuyin; unshifted ` stays the latin toggle.
    for ([_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "`" }) |label| {
        try t.expect(punctuation.output(label, false, false) == null);
    }
    const d = try dec();
    defer d.deinit();
    var input = try d.comp("su3");
    try t.expect(try input.appendLiteral(d.a(), "（"));
}

test "selection keys" {
    const a = t.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const S = session_mod;
    const keys = "asdfghjkl;";
    // One page of 8: `a`..`k`; `l` and `q` select nothing.
    try t.expectEqual(@as(?usize, 0), try S.selectionSlot(arena.allocator(), "a", keys, 8));
    try t.expectEqual(@as(?usize, 7), try S.selectionSlot(arena.allocator(), "k", keys, 8));
    try t.expectEqual(@as(?usize, null), try S.selectionSlot(arena.allocator(), "l", keys, 8));
    try t.expectEqual(@as(?usize, null), try S.selectionSlot(arena.allocator(), "q", keys, 8));
    try expectStrings(&.{ "a", "s", "d", "f", "g", "h", "j", "k" }, try S.selectionLabels(arena.allocator(), keys, 8));
    try t.expectEqualStrings("asdf", try S.sanitizeKeys(arena.allocator(), "ASdd f!", 8));
    try t.expectEqualStrings("asdfghjk", try S.sanitizeKeys(arena.allocator(), "   ", 8));
    try t.expectEqualStrings("12345678", try S.sanitizeKeys(arena.allocator(), "12345678", 8));
}

test "erase removes a whole converted syllable" {
    // Completed characters go one char per press; mid-syllable pending still
    // deletes one key (see next test).
    const d = try dec();
    defer d.deinit();
    var input = try d.comp("su3cl3");
    input.erase();
    try expectStrings(&.{ "s", "u", "3" }, try keysOf(input, d.a()));
    try expectStrings(&.{"ㄋㄧˇ"}, try d.readings((try input.parsed(d.a())).complete));
}

test "erase removes one key while pending" {
    const d = try dec();
    defer d.deinit();
    var input = try d.comp("su3cl");
    input.erase();
    try expectStrings(&.{ "s", "u", "3", "c" }, try keysOf(input, d.a()));
    try expectStrings(&.{"ㄋㄧˇ"}, try d.readings((try input.parsed(d.a())).complete));
}

test "delete-last-syllable on an incomplete tail" {
    const d = try dec();
    defer d.deinit();
    var input = try d.comp("su3cl");
    input.deleteLastSyllable();
    try expectStrings(&.{ "s", "u", "3" }, try keysOf(input, d.a()));
}

// MARK: - Repair

test "a fused toneless run repairs its tone onto the trailing piece" {
    // "sucl" fused by one mid-sentence ˇ must still read 你好.
    const d = try dec();
    defer d.deinit();
    const result = try d.decodeComplete(&.{d.syl("sucl", h.t3)}, .{});
    try expectTop(result, "你好");
    try t.expectEqual(@as(i32, 0), result[0].unresolved);
}

test "a wrong tone still resolves with a repair penalty" {
    // su4 is ㄋㄧˋ, but the fixture lexicon only knows 你 (ㄋㄧˇ): the tone
    // mismatch must stay viable instead of falling back to raw.
    const d = try dec();
    defer d.deinit();
    const result = try d.decodeComplete(&.{d.syl("su", h.t4)}, .{});
    try expectTop(result, "你");
    try t.expectEqual(@as(i32, 1), result[0].repairs);
}

test "a late tone attaches to the last boundary" {
    const d = try dec();
    defer d.deinit();
    var input = try d.comp("su cl ");
    try t.expect(try input.retoneLast(d.a(), '3'));
    try expectStrings(&.{ "ㄋㄧ", "ㄏㄠˇ" }, try d.readings((try input.parsed(d.a())).complete));
    var corrected = try d.comp("su3");
    try t.expect(try corrected.retoneLast(d.a(), '4'));
    try expectStrings(&.{"ㄋㄧˋ"}, try d.readings((try corrected.parsed(d.a())).complete));
    var empty: composition_mod.Composition = .{};
    try t.expect(!(try empty.retoneLast(d.a(), '3')));
}

test "transposed keys repair to a valid reading" {
    // "us3" is ㄧㄋˇ (invalid); swapping back gives 你 (ㄋㄧˇ).
    const d = try dec();
    defer d.deinit();
    const result = try d.decodeComplete(&.{d.syl("us", h.t3)}, .{});
    try expectTop(result, "你");
    try t.expectEqual(@as(i32, 1), result[0].repairs);
}

const slot_rows = h.tsv(
    \\ㄈㄤ|方|-6.372478
    \\ㄅㄧㄢˋ|便|-7.765845
    \\ㄅㄢˋ|半|-8.107199
    \\ㄧ|一|-4.670826
    \\ㄈㄤ-ㄅㄧㄢˋ|方便|-9.858953
    \\ㄧ-ㄅㄢˋ|一半|-10.181407
    \\
);

test "a slot-order slip beats a clean split inside a word" {
    // 方便 with ㄅㄧㄢˋ typed ㄧㄅㄢˋ (z; u104): the keys also split cleanly as
    // ㄧ|ㄅㄢˋ, which used to hide the repair (方一半).
    const d = try Dec.init(slot_rows);
    defer d.deinit();
    const result = try d.decodeComplete(&.{ d.syl("z;", h.first_tone), d.syl("u10", h.t4) }, .{});
    try expectTop(result, "方便");
    try t.expectEqual(@as(i32, 1), result[0].repairs);
}

test "slot-order repair keeps a genuine split" {
    // The same keys alone are a real toneless 一 + 半ˋ: no word pulls toward
    // 便, so the clean split must win.
    const d = try Dec.init(slot_rows);
    defer d.deinit();
    const result = try d.decodeComplete(&.{d.syl("u10", h.t4)}, .{});
    try expectTop(result, "一半");
    try t.expectEqual(@as(i32, 0), result[0].repairs);
}

test "a three-key slot misorder repairs" {
    // ㄢㄅㄧˋ is no adjacent swap away from ㄅㄧㄢˋ; slot order still is.
    var buf: [3]u8 = undefined;
    try t.expectEqualStrings("1u0", keyboard.slotOrdered("01u", &buf).?);
    try t.expect(keyboard.slotOrdered("1u0", &buf) == null);
    try t.expect(keyboard.slotOrdered("1q", &buf) == null); // two initials: not one syllable
    const d = try Dec.init(slot_rows);
    defer d.deinit();
    const result = try d.decodeComplete(&.{ d.syl("z;", h.first_tone), d.syl("01u", h.t4) }, .{});
    try expectTop(result, "方便");
}

const completion_rows = h.tsv(
    \\ㄍㄨㄥ|工|-6.589448
    \\ㄍㄨ|估|-9.096421
    \\ㄗㄨㄛˋ|作|-6.873654
    \\ㄗㄨㄛˋ|做|-6.225733
    \\ㄍㄨㄥ-ㄗㄨㄛˋ|工作|-7.607396
    \\ㄌㄠˇ|老|-7.109853
    \\ㄕ|師|-7.328932
    \\ㄕㄥ|生|-5.906531
    \\ㄌㄠˇ-ㄕ|老師|-8.458474
    \\ㄌㄠˇ-ㄕㄥ|老生|-13.762608
    \\
);

test "a dropped key leaving a valid reading completes the word" {
    // 工作 with ㄥ dropped: ㄍㄨ is a valid reading (估), which used to keep
    // insertion repair from running (估做).
    const d = try Dec.init(completion_rows);
    defer d.deinit();
    const result = try d.decodeComplete(&.{ d.syl("ej", h.first_tone), d.syl("yji", h.t4) }, .{});
    try expectTop(result, "工作");
    try t.expectEqual(@as(i32, 1), result[0].repairs);
}

test "slot completion never rewrites exact input" {
    // Word-only: a lone exact 估 stays, and exact 老師 is not "completed"
    // into 老生.
    const d = try Dec.init(completion_rows);
    defer d.deinit();
    try expectTop(try d.decodeComplete(&.{d.syl("ej", h.first_tone)}, .{}), "估");
    const word = try d.decodeComplete(&.{ d.syl("xl", h.t3), d.syl("g", h.first_tone) }, .{});
    try expectTop(word, "老師");
    try t.expectEqual(@as(i32, 0), word[0].repairs);
    const from_ej = try keyboard.slotCompletions(d.a(), "ej");
    try t.expect(for (from_ej) |c| {
        if (std.mem.eql(u8, c, "ej/")) break true;
    } else false);
    const from_j = try keyboard.slotCompletions(d.a(), "j/");
    try t.expect(for (from_j) |c| {
        if (std.mem.eql(u8, c, "ej/")) break true;
    } else false);
    try t.expectEqual(@as(usize, 0), (try keyboard.slotCompletions(d.a(), "ej/")).len);
}

test "extra-key deletion repair" {
    // "gsu3" has a stray ㄕ key; dropping it gives 你.
    const d = try dec();
    defer d.deinit();
    const result = try d.decodeComplete(&.{d.syl("gsu", h.t3)}, .{});
    try expectTop(result, "你");
    try t.expectEqual(@as(i32, 1), result[0].repairs);
}

test "missing-key insertion repair" {
    // "s3" is bare ㄋˇ (invalid); inserting ㄧ gives 你.
    const d = try dec();
    defer d.deinit();
    const result = try d.decodeComplete(&.{d.syl("s", h.t3)}, .{});
    try expectTop(result, "你");
    try t.expectEqual(@as(i32, 1), result[0].repairs);
}

test "phonetic confusion repairs a medial slip" {
    // "sm3" is ㄋㄩˇ (m=ㄩ for u=ㄧ slip: far apart on QWERTY, so neighbor
    // rescue cannot see it); the ㄧㄨㄩ group must yield 你.
    const d = try dec();
    defer d.deinit();
    const result = try d.decodeComplete(&.{d.syl("sm", h.t3)}, .{});
    try expectTop(result, "你");
    try t.expectEqual(@as(i32, 1), result[0].repairs);
}

// MARK: - Punctuation and segments

test "punctuation stays inside the composition" {
    // 你好，謝謝：words never span ，, punctuation passes through.
    const d = try dec();
    defer d.deinit();
    const segments = [_]composition_mod.Segment{
        .{ .syllable = d.syl("su", h.t3) },
        .{ .punct = "，" },
        .{ .syllable = d.syl("vu,", h.t4) },
        .{ .syllable = d.syl("vu,", h.neutral) },
    };
    const result = try d.lex.decodeSegments(d.a(), &segments, "", .{});
    try expectTop(result, "你，謝謝");
    try t.expectEqual(@as(i32, 0), result[0].unresolved);
}

test "erase across a punctuation boundary" {
    const d = try dec();
    defer d.deinit();
    var input = try d.comp("su3");
    _ = try input.appendLiteral(d.a(), "，");
    try t.expectEqual(@as(usize, 2), (try input.segments(d.a())).len);
    input.erase(); // trailing punct deletes alone…
    try expectStrings(&.{ "s", "u", "3" }, try keysOf(input, d.a()));
    input.erase(); // …then the whole converted syllable goes.
    try t.expect(input.isEmpty());
}

test "delete-last-syllable stops at punctuation" {
    const d = try dec();
    defer d.deinit();
    var input = try d.comp("su3cl3");
    _ = try input.appendLiteral(d.a(), "，");
    input.deleteLastSyllable();
    try expectStrings(&.{ "s", "u", "3", "c", "l", "3" }, try keysOf(input, d.a()));
}

test "decodeSegments repairs a fused tone run" {
    // Regression: decodeSegments once bypassed repairComplete, so a toneless
    // head fused onto a toned tail fell back to raw. su fused onto cl3 must
    // still read 你好.
    const d = try dec();
    defer d.deinit();
    const segments = [_]composition_mod.Segment{.{ .syllable = d.syl("sucl", h.t3) }};
    const result = try d.lex.decodeSegments(d.a(), &segments, "", .{});
    try expectTop(result, "你好");
    try t.expectEqual(@as(i32, 0), result[0].unresolved);
}

test "decodeSegments repairs one tone for two syllables" {
    // Same fused shape but the lone tone belongs to neither syllable exactly
    // (ˋ on 好): tolerance still yields 你好 with a repair.
    const d = try dec();
    defer d.deinit();
    const segments = [_]composition_mod.Segment{.{ .syllable = d.syl("sucl", h.t4) }};
    const result = try d.lex.decodeSegments(d.a(), &segments, "", .{});
    try expectTop(result, "你好");
    try t.expectEqual(@as(i32, 1), result[0].repairs);
}

test "space separates without committing" {
    // "su3 cl" keeps one composition: 你 + literal space + pending ㄏㄠ.
    const d = try dec();
    defer d.deinit();
    var input = try d.comp("su3");
    try t.expect(try input.appendSpace(d.a()));
    try t.expect(try input.append(d.a(), 'c'));
    try t.expect(try input.append(d.a(), 'l'));
    const parsed = try input.parsed(d.a());
    try expectStrings(&.{"ㄋㄧˇ"}, try d.readings(parsed.complete));
    try t.expectEqualStrings("cl", parsed.pending);
    try expectTop(try d.decodeSegs(input, .{}), "你 好");
}

test "a multi-word Latin run survives spaces" {
    // `hello world su3cl3: spaces stay inside the latin run; the whole span
    // still commits once.
    const d = try dec();
    defer d.deinit();
    var input: composition_mod.Composition = .{};
    for ("hello") |c| _ = try input.appendLatin(d.a(), &.{c});
    _ = try input.appendSpace(d.a());
    for ("world") |c| _ = try input.appendLatin(d.a(), &.{c});
    _ = try input.appendSpace(d.a());
    for ("su3cl3") |c| _ = try input.append(d.a(), c);
    const result = try d.decodeSegs(input, .{});
    try expectTop(result, "hello world 你好");
    try t.expectEqual(@as(i32, 0), result[0].unresolved);
}

test "a mixed Latin run passes through" {
    // `hello toneless 你好: latin seps join, Zhuyin runs decode.
    const d = try dec();
    defer d.deinit();
    var input: composition_mod.Composition = .{};
    for ("hello") |c| _ = try input.appendLatin(d.a(), &.{c});
    _ = try input.appendSpace(d.a());
    for ("sucl") |c| _ = try input.append(d.a(), c);
    try expectTop(try d.decodeSegs(input, .{}), "hello 你好");
    try t.expectEqualStrings("ㄋㄧㄏㄠ", try input.pendingText(d.a()));
}

test "Latin backspace and erase stay charwise" {
    const d = try dec();
    defer d.deinit();
    var input: composition_mod.Composition = .{};
    _ = try input.appendLatin(d.a(), "A");
    _ = try input.appendLatin(d.a(), "I");
    input.erase(); // trailing latin deletes one char…
    try expectStrings(&.{"L:A"}, try keysOf(input, d.a()));
    try t.expectEqualStrings("", try input.pendingText(d.a())); // latin shows via converted
    input.deleteLastSyllable(); // …never drags previous runs.
    try t.expect(input.isEmpty());
    var mixed = try d.comp("su3");
    _ = try mixed.appendLatin(d.a(), "x");
    mixed.deleteLastSyllable();
    try expectStrings(&.{ "s", "u", "3" }, try keysOf(mixed, d.a()));
}

test "dropping the head keeps the trailing run" {
    // Swift dropThroughLastBoundary / dropHeadKeepingTail: Zig drops by count
    // (`dropHead`) from the session, which computes the boundary itself.
    const d = try dec();
    defer d.deinit();
    var input = try d.comp("su3cl");
    input.dropHead(3);
    try expectStrings(&.{ "c", "l" }, try keysOf(input, d.a()));
    var done = try d.comp("su3cl3");
    done.dropHead(6);
    try t.expect(done.isEmpty());
    var punct = try d.comp("su3");
    _ = try punct.appendLiteral(d.a(), "，");
    _ = try punct.append(d.a(), 'c');
    punct.dropHead(4);
    try expectStrings(&.{"c"}, try keysOf(punct, d.a()));
    var latin = try d.comp("su3");
    _ = try latin.appendLatin(d.a(), "x");
    _ = try latin.appendLatin(d.a(), "y");
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("xy", composition_mod.Composition.trailingLatin(latin.keys(), &buf));
    const plain = try d.comp("su3");
    try t.expectEqualStrings("", composition_mod.Composition.trailingLatin(plain.keys(), &buf));
}

// MARK: - Tone handling

test "a space-terminated first tone ranks exact first" {
    // "vm, g/ " (space-terminated): space is a strong first tone (RIME
    // parity), so exact ㄕㄥ scores 0 while ㄒㄩㄝ has no first-tone form and
    // pays the explicit-tone mismatch (4.0): 學生 lands at -7.0, still top-1
    // as the only word. The toneless-nil twin pays 0.5+0.5.
    const d = try dec();
    defer d.deinit();
    const spaced = try d.decode(&.{ d.syl("vm,", h.first_tone), d.syl("g/", h.first_tone) }, .{});
    try expectTop(spaced, "學生");
    try approx(-7.0, spaced[0].score);
    // A typed first tone beats a more frequent other-tone rival (喝/和).
    const drink = try Dec.init(h.tsv(
        \\ㄏㄜ|喝|-9
        \\ㄏㄜˊ|和|-6
        \\
    ));
    defer drink.deinit();
    try expectTop(try drink.decode(&.{drink.syl("ck", h.first_tone)}, .{}), "喝");
    try expectTop(try drink.decode(&.{drink.syl("ck", null)}, .{}), "和");
    const bare = try d.decode(&.{ d.syl("vm,", null), d.syl("g/", null) }, .{});
    try expectTop(bare, "學生");
    try approx(-4.0, bare[0].score);
    const toneless_space = try d.decodeComplete(&.{ d.syl("su", h.first_tone), d.syl("cl", h.first_tone) }, .{});
    try expectTop(toneless_space, "你好");
}

test "strict tone rejects a mismatch" {
    // tone_tolerance off: su4 (ㄋㄧˋ) must NOT resolve to 你; with tolerance
    // it does (repairs 1). Ultra-strict falls back to raw.
    const d = try dec();
    defer d.deinit();
    const strict = try d.decode(&.{d.syl("su", h.t4)}, .{ .fuzzy = true, .tone_tolerance = false });
    try expectTop(strict, "ㄋㄧˋ");
    try t.expectEqual(@as(i32, 1), strict[0].unresolved);
    const tolerant = try d.decode(&.{d.syl("su", h.t4)}, .{ .fuzzy = true, .tone_tolerance = true });
    try expectTop(tolerant, "你");
    try t.expectEqual(@as(i32, 1), tolerant[0].repairs);
}

test "fuzzy repair off keeps toneless lookup" {
    // fuzzy off: du (ㄎㄧ) cannot rescue to 你, but toneless lookup still
    // works (policy gates rescue, not toneless decoding).
    const d = try dec();
    defer d.deinit();
    const off = try d.decode(try d.syllables(try d.comp("du"), true), .{ .fuzzy = false, .tone_tolerance = true });
    try expectTop(off, "ㄎㄧ");
    try t.expectEqual(@as(i32, 1), off[0].unresolved);
    const toneless = try d.decode(try d.syllables(try d.comp("sucl"), true), .{ .fuzzy = false, .tone_tolerance = true });
    try expectTop(toneless, "ㄋㄧㄏㄠ");
}

test "the capture is bounded and clear removes the active input" {
    const d = try dec();
    defer d.deinit();
    var input: composition_mod.Composition = .{};
    for (0..300) |_| _ = try input.append(d.a(), 'a');
    try t.expectEqual(@as(usize, 256), input.keys().len);
    input.clear();
    try t.expect(input.isEmpty());
    try t.expect(!(try input.append(d.a(), '3')));
}

// MARK: - User phrase learning

test "the user lexicon flips the top one after one explicit pick" {
    // Fixture prefers 你 (-5) over 妳 (-6); one explicit record (+6) must
    // flip the tie deterministically.
    const d = try dec();
    defer d.deinit();
    var learned = UserLexicon.init(t.allocator);
    defer learned.deinit();
    try learned.record("ㄋㄧ", "妳", 1);
    const result = try d.decode(try d.syllables(try d.comp("su3"), true), .{ .user_lexicon = &learned });
    try expectTop(result, "妳");
    try approx(0, result[0].score); // -6 + 6
}

test "a toneless retype hits the toned learn" {
    // Toneless-continuous retype must hit the toned learn: the key is
    // toneless-concatenated on both sides.
    const d = try dec();
    defer d.deinit();
    var learned = UserLexicon.init(t.allocator);
    defer learned.deinit();
    try learned.record("ㄋㄧ", "妳", 1);
    try expectTop(try d.decodeParsed(try d.comp("su"), .{ .user_lexicon = &learned }), "妳");
}

test "a learned single character does not beat a word inside a sentence" {
    // User report 2026-09-29: one learned 設 (+6) made 育+設 beat the word
    // 預設 in every sentence (育設, 與設文字). A learned single character
    // pays only when it is the whole input.
    const d = try Dec.init(h.tsv(
        \\ㄩˋ|育|-7
        \\ㄩˋ|預|-8
        \\ㄕㄜˋ|設|-8
        \\ㄩˋ-ㄕㄜˋ|預設|-11
        \\
    ));
    defer d.deinit();
    var learned = UserLexicon.init(t.allocator);
    defer learned.deinit();
    try learned.record("ㄕㄜ", "設", 1);
    const sentence = [_]h.Syllable{ d.syl("m", h.t4), d.syl("gk", h.t4) };
    try expectTop(try d.decode(&sentence, .{ .user_lexicon = &learned }), "預設");
    // Alone, the learned pick still wins its own tie.
    const alone = try d.decode(&.{d.syl("gk", h.t4)}, .{ .user_lexicon = &learned });
    try approx(-2, alone[0].score); // -8 + 6
}

test "the user lexicon bonus caps with repeats" {
    const d = try dec();
    defer d.deinit();
    var learned = UserLexicon.init(t.allocator);
    defer learned.deinit();
    for (1..7) |second| try learned.record("ㄋㄧ", "妳", @floatFromInt(second));
    try approx(10.0, learned.bonus("ㄋㄧ", "妳"));
    const result = try d.decode(try d.syllables(try d.comp("su3"), true), .{ .user_lexicon = &learned });
    try approx(4.0, result[0].score); // -6 + 10
}

test "the user lexicon leaves unrelated input alone" {
    // Empty overlay and unrelated learns must be byte-identical.
    const d = try dec();
    defer d.deinit();
    var learned = UserLexicon.init(t.allocator);
    defer learned.deinit();
    try learned.record("ㄋㄧ", "妳", 1);
    var empty = UserLexicon.init(t.allocator);
    defer empty.deinit();
    const typed = [_]h.Syllable{ d.syl("su", h.t3), d.syl("cl", h.t3) };
    const plain = try d.decodeComplete(&typed, .{});
    const with_empty = try d.decodeComplete(&typed, .{ .user_lexicon = &empty });
    try t.expectEqual(plain.len, with_empty.len);
    for (plain, with_empty) |p, e| {
        try t.expectEqualStrings(p.text, e.text);
        try t.expectEqual(p.score, e.score);
    }
    const boosted = try d.decodeComplete(&typed, .{ .user_lexicon = &learned });
    try expectTop(boosted, "你好"); // 妳-learn does not leak here
    try approx(plain[0].score, boosted[0].score);
}

test "the user lexicon boosts a multi-syllable span" {
    const d = try dec();
    defer d.deinit();
    var learned = UserLexicon.init(t.allocator);
    defer learned.deinit();
    try learned.record("ㄋㄧㄏㄠ", "你好", 1);
    const result = try d.decodeParsed(try d.comp("su3cl3"), .{ .user_lexicon = &learned });
    try expectTop(result, "你好");
    try approx(3.0, result[0].score); // -3 + 6
}

test "the user lexicon store round-trips and evicts" {
    var learned = UserLexicon.init(t.allocator);
    defer learned.deinit();
    try learned.record("ㄋㄧ", "妳", 7);
    const data = try learned.encode(t.allocator);
    defer t.allocator.free(data);
    var restored = try UserLexicon.decode(t.allocator, data);
    defer restored.deinit();
    try t.expectEqual(learned.count(), restored.count());
    try approx(6.0, restored.bonus("ㄋㄧ", "妳"));
    // Cap is enforced deterministically: the oldest lowest-count entry goes.
    var full = UserLexicon.init(t.allocator);
    defer full.deinit();
    var buf: [32]u8 = undefined;
    for (0..user_lexicon.entry_cap + 1) |index| {
        const key = try std.fmt.bufPrint(&buf, "k{d}", .{index});
        try full.record(key, "文", @floatFromInt(index));
    }
    try t.expectEqual(@as(usize, user_lexicon.entry_cap), full.count());
    try t.expect(full.get("k0") == null);
    const newest = try std.fmt.bufPrint(&buf, "k{d}", .{user_lexicon.entry_cap});
    try t.expect(full.get(newest) != null);
}

test "version one learning files load empty" {
    const v1 =
        \\{"version":1,"entries":{"ㄘㄜㄕ":{"測試":{"count":3,"updatedAt":0}}}}
    ;
    var restored = try UserLexicon.decode(t.allocator, v1);
    defer restored.deinit();
    try t.expect(restored.isEmpty());
}

// MARK: - Alignment, locks, segments

test "decode fills the word alignment" {
    const d = try dec();
    defer d.deinit();
    const result = try d.decode(try d.syllables(try d.comp("su3cl3"), true), .{});
    try expectTop(result, "你好");
    try t.expectEqual(@as(usize, 1), result[0].alignment.len);
    try t.expect(result[0].alignment[0].syllables.eql(Range.of(0, 2)));
    try t.expect(result[0].alignment[0].chars.eql(Range.of(0, 2)));
}

test "alignment covers unresolved input" {
    // "zzzz3" parses as ONE fused syllable (tone-terminated), so the raw
    // fallback covers a single span: contiguity over 0..<1.
    const d = try dec();
    defer d.deinit();
    const top = (try d.decode(try d.syllables(try d.comp("zzzz3"), true), .{}))[0];
    try t.expectEqual(@as(i32, 1), top.unresolved);
    const covered = top.alignment;
    try t.expectEqual(@as(u32, 0), covered[0].syllables.start);
    try t.expectEqual(@as(u32, 1), covered[covered.len - 1].syllables.end);
    for (covered[0 .. covered.len - 1], covered[1..]) |a, b| try t.expectEqual(a.syllables.end, b.syllables.start);
}

test "a hard lock forces the pinned word" {
    // 妳 (-6) loses to 你 (-5) without help; a session pin on the span must
    // force it, while other spans stay free.
    const d = try dec();
    defer d.deinit();
    var pins = UserLexicon.init(t.allocator);
    defer pins.deinit();
    try pins.setSingle("ㄋㄧ", "妳", .{ .count = 1, .updated_at = 1 });
    const result = try d.decode(try d.syllables(try d.comp("su3cl3"), true), .{ .locked = &pins });
    try expectTop(result, "妳好");
    // No starvation: the unpinned rival stays available below the pin.
    try t.expect(h.containsText(result, "你好"));
}

test "a hard lock leaves unpinned spans alone" {
    const d = try dec();
    defer d.deinit();
    var pins = UserLexicon.init(t.allocator);
    defer pins.deinit();
    try pins.setSingle("ㄅㄨ", "不", .{ .count = 1, .updated_at = 1 });
    const syllables = try d.syllables(try d.comp("su3cl3"), true);
    const plain = try d.decode(syllables, .{});
    const locked = try d.decode(syllables, .{ .locked = &pins });
    try t.expectEqual(plain.len, locked.len);
    for (plain, locked) |p, l| {
        try t.expectEqualStrings(p.text, l.text);
        try t.expectEqual(p.score, l.score);
    }
}

test "segment options cover the focused span" {
    const d = try dec();
    defer d.deinit();
    const syllables = try d.syllables(try d.comp("su3cl3"), true);
    const head = try d.lex.segmentOptions(d.a(), syllables, Range.of(0, 1), true, true);
    var has_ni = false;
    var has_ni2 = false;
    for (head) |o| {
        if (std.mem.eql(u8, o.text, "你")) has_ni = true;
        if (std.mem.eql(u8, o.text, "妳")) has_ni2 = true;
    }
    try t.expect(has_ni and has_ni2);
    for (head[0 .. head.len - 1], head[1..]) |a, b| try t.expect(a.score >= b.score);
    const whole = try d.lex.segmentOptions(d.a(), syllables, Range.of(0, 2), true, true);
    try t.expectEqualStrings("你好", whole[0].text);
    try t.expect(whole.len <= 16);
    try t.expectEqual(@as(usize, 0), (try d.lex.segmentOptions(d.a(), syllables, Range.of(1, 1), true, true)).len);
    try t.expectEqual(@as(usize, 0), (try d.lex.segmentOptions(d.a(), syllables, Range.of(0, 9), true, true)).len);
}

// MARK: - Cursor selection and pins

test "cursor options offer words across the top boundary" {
    const d = try Dec.init(boundary_rows);
    defer d.deinit();
    const top = (try d.decodeSegs(try d.comp("2842jo4"), .{}))[0];
    try t.expectEqualStrings("大對", top.text);
    // The top path splits 大|對; the cursor on 對 must still offer 打對.
    const options = try session_mod.cursorOptions(d.lex, d.a(), top.syllables, 1, null, true, true);
    // 打對 (typed 大's tone 4) pays the tone penalty.
    try t.expectEqualStrings("打對", options[0].text);
    try t.expect(options[0].span.eql(Range.of(0, 2)));
    var has_dui = false;
    for (options) |o| if (std.mem.eql(u8, o.text, "對") and o.span.eql(Range.of(1, 2))) {
        has_dui = true;
    };
    try t.expect(has_dui);
    for (try session_mod.cursorOptions(d.lex, d.a(), top.syllables, 1, Range.of(1, 2), true, true)) |o| {
        try t.expect(o.span.eql(Range.of(1, 2)));
    }
    try t.expectEqual(@as(usize, 0), (try session_mod.cursorOptions(d.lex, d.a(), top.syllables, 2, null, true, true)).len);
}

test "a pin keeps an earlier pick outside the new span" {
    const d = try Dec.init(boundary_rows);
    defer d.deinit();
    const input = try d.comp("294fu061l ");
    var pins = UserLexicon.init(t.allocator);
    defer pins.deinit();
    var top = (try d.decodeSegs(input, .{}))[0];
    try t.expectEqualStrings("代錢包", top.text);
    try pins.pin(.{ .text = "帶錢", .span = Range.of(0, 2), .score = -9 }, top);
    top = (try d.decodeSegs(input, .{ .locked = &pins }))[0];
    try t.expectEqualStrings("帶錢苞", top.text);
    // Picking 錢包 overlaps the 帶錢 pin; 帶 must survive, not revert to 代.
    try pins.pin(.{ .text = "錢包", .span = Range.of(1, 3), .score = -8 }, top);
    top = (try d.decodeSegs(input, .{ .locked = &pins }))[0];
    try t.expectEqualStrings("帶錢包", top.text);
}

test "pins are positional" {
    // Repeated reading: pinning the second ㄊㄚ must leave the first alone,
    // and a path can never collect the same pin twice.
    const d = try Dec.init(h.tsv(
        \\ㄊㄚ|他|-3
        \\ㄊㄚ|她|-5
        \\ㄕㄨㄛ|說|-4
        \\
    ));
    defer d.deinit();
    const input = try d.comp("w8 gji w8 ");
    var top = (try d.decodeSegs(input, .{}))[0];
    try t.expectEqualStrings("他說他", top.text);
    var pins = UserLexicon.init(t.allocator);
    defer pins.deinit();
    try pins.pin(.{ .text = "她", .span = Range.of(2, 3), .score = -5 }, top);
    top = (try d.decodeSegs(input, .{ .locked = &pins }))[0];
    try t.expectEqualStrings("他說她", top.text);
    try approx(-3 - 4 - 5 + user_lexicon.pin_bonus, top.score);
}

test "pins stay in their run" {
    const d = try Dec.init(h.tsv(
        \\ㄊㄚ|他|-3
        \\ㄊㄚ|她|-5
        \\
    ));
    defer d.deinit();
    var input = try d.comp("w8 ");
    _ = try input.appendLiteral(d.a(), "，");
    for ("w8 ") |c| {
        if (c == ' ') _ = try input.appendSpace(d.a()) else _ = try input.append(d.a(), c);
    }
    var top = (try d.decodeSegs(input, .{}))[0];
    try t.expectEqualStrings("他，他", top.text);
    try t.expectEqual(@as(usize, 2), top.runs.len);
    try t.expect(top.runs[0].eql(Range.of(0, 1)) and top.runs[1].eql(Range.of(1, 2)));
    var pins = UserLexicon.init(t.allocator);
    defer pins.deinit();
    try pins.pin(.{ .text = "她", .span = Range.of(1, 2), .score = -5 }, top);
    try t.expectEqual(@as(usize, 1), pins.entries.count());
    try t.expectEqualStrings("1#0@ㄊㄚ", pins.entries.keys()[0]);
    top = (try d.decodeSegs(input, .{ .locked = &pins }))[0];
    try t.expectEqualStrings("他，她", top.text);
}

test "learning records picked words, not sentences" {
    const d = try Dec.init(boundary_rows);
    defer d.deinit();
    const input = try d.comp("294fu061l ");
    const plain = (try d.decodeSegs(input, .{}))[0];
    var pins = UserLexicon.init(t.allocator);
    defer pins.deinit();
    try pins.pin(.{ .text = "帶錢", .span = Range.of(0, 2), .score = -9 }, plain);
    const picked = (try d.decodeSegs(input, .{ .locked = &pins }))[0];
    try t.expectEqualStrings("帶錢苞", picked.text);
    // The pinned word is learned; the untouched single char is not, and the
    // sentence itself never is (the decoder only boosts words).
    const words = try user_lexicon.learnedWords(d.a(), picked, &pins, null);
    try t.expectEqual(@as(usize, 1), words.len);
    try t.expectEqualStrings("帶錢", words[0].text);
    try t.expectEqualStrings("ㄉㄞㄑㄧㄢ", words[0].key);
    // Single-character picks inside a sentence stay unlearned.
    var single = UserLexicon.init(t.allocator);
    defer single.deinit();
    try single.pin(.{ .text = "帶", .span = Range.of(0, 1), .score = -6 }, plain);
    const one = (try d.decodeSegs(input, .{ .locked = &single }))[0];
    try t.expectEqualStrings("帶錢包", one.text);
    try t.expectEqual(@as(usize, 0), (try user_lexicon.learnedWords(d.a(), one, &single, null)).len);
    // A whole-sentence pick learns what differs from top-1: the word
    // globally, the single char in the context of the word before it.
    var none = UserLexicon.init(t.allocator);
    defer none.deinit();
    const sentence_pick = try user_lexicon.learnedWords(d.a(), picked, &none, plain);
    try t.expectEqual(@as(usize, 2), sentence_pick.len);
    try t.expectEqualStrings("帶錢", sentence_pick[0].text);
    try t.expectEqualStrings("苞", sentence_pick[1].text);
    try t.expectEqualStrings("ㄉㄞㄑㄧㄢ", sentence_pick[0].key);
    try t.expectEqualStrings("帶錢|ㄅㄠ", sentence_pick[1].key);
    try t.expectEqual(@as(usize, 0), (try user_lexicon.learnedWords(d.a(), plain, &none, null)).len);
}

const next_time_rows = h.tsv(
    \\ㄒㄧㄚˋ-ㄘˋ|下次|-5
    \\ㄗㄞˋ|在|-3
    \\ㄗㄞˋ|再|-5
    \\ㄌㄧㄠˊ|聊|-6
    \\ㄨㄛˇ|我|-3
    \\
);

test "a single-character pick is learned only in context" {
    const d = try Dec.init(next_time_rows);
    defer d.deinit();
    const input = try d.comp("vu84h4y94xul6");
    const plain = (try d.decodeSegs(input, .{}))[0];
    try t.expectEqualStrings("下次在聊", plain.text);
    var pins = UserLexicon.init(t.allocator);
    defer pins.deinit();
    try pins.pin(.{ .text = "再", .span = Range.of(2, 3), .score = -5 }, plain);
    const picked = (try d.decodeSegs(input, .{ .locked = &pins }))[0];
    try t.expectEqualStrings("下次再聊", picked.text);
    const words = try user_lexicon.learnedWords(d.a(), picked, &pins, null);
    try t.expectEqual(@as(usize, 1), words.len);
    try t.expectEqualStrings("下次|ㄗㄞ", words[0].key);
    try t.expectEqualStrings("再", words[0].text);
    var learned = UserLexicon.init(t.allocator);
    defer learned.deinit();
    for (words) |word| try learned.record(word.key, word.text, 0);
    // Applies after 下次 only; 在 stays the default elsewhere.
    try t.expectEqualStrings("下次再聊", (try d.decodeSegs(input, .{ .user_lexicon = &learned }))[0].text);
    const elsewhere = try d.comp("ji3y94xul6");
    try t.expectEqualStrings("我在聊", (try d.decodeSegs(elsewhere, .{ .user_lexicon = &learned }))[0].text);
}

test "toneless overrides apply only to toneless input" {
    // 持 (ㄔˊ) outranks 吃 (ㄔ) in the corpus; standalone use says 吃.
    const rows = h.tsv(
        \\ㄔ|吃|-9
        \\ㄔˊ|持|-7
        \\
    );
    const plain = try Dec.init(rows);
    defer plain.deinit();
    const over = try Dec.initWith(rows, "ㄔ\t吃\t-7\nㄔˊ\t持\t-9\n");
    defer over.deinit();
    try expectTop(try plain.decodeSegs(try plain.comp("t"), .{}), "持");
    try expectTop(try over.decodeSegs(try over.comp("t"), .{}), "吃");
    // An explicit tone keeps the corpus scores (ˊ: 持 exact, 吃 pays 4.0).
    try expectTop(try over.decodeSegs(try over.comp("t6"), .{}), "持");
    try expectTop(try over.decodeSegs(try over.comp("t "), .{}), "吃");
}

test "the word penalty favors whole words over splits" {
    // 面試 loses to 面+是 on raw scores (-11.9 vs -11.1); two tokens pay the
    // penalty twice, one word once.
    const d = try Dec.init(h.tsv(
        \\ㄇㄧㄢˋ|面|-6.5
        \\ㄕˋ|是|-4.6
        \\ㄕˋ|試|-8.1
        \\ㄇㄧㄢˋ-ㄕˋ|面試|-11.9
        \\
    ));
    defer d.deinit();
    const typed = try d.comp("au04g4");
    try expectTop(try d.decodeSegs(typed, .{}), "面是");
    d.lex.word_penalty = 1.0;
    try expectTop(try d.decodeSegs(typed, .{}), "面試");
}

test "learning keeps single-word input" {
    const d = try dec();
    defer d.deinit();
    const top = (try d.decodeSegs(try d.comp("su3"), .{}))[1];
    try t.expectEqualStrings("妳", top.text);
    var none = UserLexicon.init(t.allocator);
    defer none.deinit();
    const words = try user_lexicon.learnedWords(d.a(), top, &none, null);
    try t.expectEqual(@as(usize, 1), words.len);
    try t.expectEqualStrings("妳", words[0].text);
}

test "a sentence pick survives as pins" {
    const d = try Dec.init(boundary_rows);
    defer d.deinit();
    const input = try d.comp("294fu061l ");
    const list = try d.decodeSegs(input, .{});
    try t.expectEqualStrings("代錢包", list[0].text);
    var picked: ?candidate_mod.Candidate = null;
    for (list) |c| if (std.mem.eql(u8, c.text, "帶錢包")) {
        picked = c;
    };
    try t.expect(picked != null);
    var pins = UserLexicon.init(t.allocator);
    defer pins.deinit();
    try pins.pinDifferences(picked.?, list[0]);
    try t.expectEqual(@as(usize, 1), pins.count()); // only the differing word (帶), not 錢包
    try t.expectEqualStrings("帶錢包", (try d.decodeSegs(input, .{ .locked = &pins }))[0].text);
}

test "tone-run candidates carry decoded syllables" {
    // A toneless run ended by space is ONE fused syllable in the composition;
    // the candidate must expose the decoder's own split so the IME cursor can
    // index it (the rebuild check rejected all of these).
    const d = try dec();
    defer d.deinit();
    const input = try d.comp("sucl ");
    try t.expectEqual(@as(usize, 1), (try input.parsed(d.a())).complete.len);
    const top = (try d.decodeSegs(input, .{}))[0];
    try t.expectEqualStrings("你好", top.text);
    try expectStrings(&.{ "ㄋㄧ", "ㄏㄠ" }, try d.bases(top.syllables));
    try t.expectEqual(@as(u32, @intCast(top.syllables.len)), top.alignment[top.alignment.len - 1].syllables.end);
    try t.expect(top.run(1).?.eql(Range.of(0, 2)));
    try t.expectEqual(@as(?u32, 1), top.charOffset(1));
}

test "tone-run repair keeps a long final syllable" {
    // Regression: tail lengths were emitted shortest-first, so a one-symbol
    // tail (ㄟ 欸) with many lead splits filled the caller's top-6 and the
    // real final syllable (ㄉㄨㄟ) was never decoded.
    const d = try Dec.init(h.tsv(
        \\ㄨㄚ|挖|-4
        \\ㄨ|屋|-5
        \\ㄚ|啊|-5
        \\ㄉㄚˇ|打|-6
        \\ㄉㄨ|都|-6
        \\ㄟ|欸|-6
        \\ㄉㄨㄟˋ|對|-4
        \\ㄉㄚˇ-ㄉㄨㄟˋ|打對|-5
        \\
    ));
    defer d.deinit();
    const top = (try d.decodeSegs(try d.comp("j8j8j8282jo "), .{}))[0];
    try t.expectEqualStrings("挖挖挖打對", top.text);
}

test "a later tone run does not drop an earlier run split" {
    // User report 2026-10-06: ㄖㄨㄍㄨㄛˇ + ㄐㄧㄡㄓㄜㄧㄤㄧ␣ + ㄓˊ turned 如果
    // into 如故喔 once ㄓˊ completed. Round-robin lists the shorter tail
    // (ㄍㄨ|ㄛˇ) first; the cross-run product kept combos in arrival order, so
    // the third complete syllable truncated it to the first head option only
    // and ㄍㄨㄛˇ never reached decode.
    const d = try Dec.init(h.tsv(
        \\ㄖㄨˊ|如|-5
        \\ㄍㄨㄛˇ|果|-6
        \\ㄖㄨˊ-ㄍㄨㄛˇ|如果|-4
        \\ㄍㄨˋ|故|-5
        \\ㄖㄨˊ-ㄍㄨˋ|如故|-6
        \\ㄛ|喔|-5
        \\ㄐㄧㄡˋ|就|-4
        \\ㄓㄜˋ|這|-4
        \\ㄧㄤˋ|樣|-4
        \\ㄓㄜˋ-ㄧㄤˋ|這樣|-4
        \\ㄧ|一|-3
        \\ㄓˊ|直|-5
        \\ㄧ-ㄓˊ|一直|-5
        \\ㄐㄧ|機|-6
        \\ㄡ|歐|-7
        \\ㄓ|之|-6
        \\ㄜ|鵝|-7
        \\ㄤ|骯|-8
        \\
    ));
    defer d.deinit();
    const input = try d.comp("bjeji3ru.5ku;u 56");
    try t.expectEqual(@as(usize, 3), (try input.parsed(d.a())).complete.len);
    const top = (try d.decodeSegs(input, .{}))[0];
    try t.expectEqualStrings("如果就這樣一直", top.text);
    try t.expectEqual(@as(i32, 0), top.repairs);
}

test "a tone-closed run keeps its lead when the tail is invalid" {
    // 你好 + ㄉ + Space: the run must not collapse into ㄋㄧㄏㄠㄉ.
    const d = try dec();
    defer d.deinit();
    const top = (try d.decodeSegs(try d.comp("sucl2 "), .{ .fuzzy = false }))[0];
    try t.expectEqualStrings("你好ㄉ", top.text);
    try t.expectEqual(@as(i32, 1), top.unresolved);
    try expectStrings(&.{ "ㄋㄧ", "ㄏㄠ", "ㄉ" }, try d.bases(top.syllables));
}

test "settled pins freeze accepted text but not the tail" {
    const d = try Dec.init(boundary_rows);
    defer d.deinit();
    var input = try d.comp("2842jo4"); // 大對
    _ = try input.appendLiteral(d.a(), "，");
    for ("294fu061l ") |c| {
        if (c == ' ') _ = try input.appendSpace(d.a()) else _ = try input.append(d.a(), c);
    }
    const top = (try d.decodeSegs(input, .{}))[0];
    try t.expectEqualStrings("大對，代錢包", top.text);
    var settled = try UserLexicon.settled(t.allocator, top, 3);
    defer settled.deinit();
    // The closed run settles whole; the run being typed is too short.
    var texts: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer texts.deinit(t.allocator);
    for (settled.entries.values()) |entry| for (entry.keys()) |text| try texts.put(t.allocator, text, {});
    try t.expectEqual(@as(usize, 2), texts.count());
    try t.expect(texts.contains("大") and texts.contains("對"));
    // The settled prefix holds the decode to 大對，… (live-preview behavior).
    const frozen = try d.decodeSegs(input, .{ .locked = &settled });
    for (frozen) |c| try t.expect(std.mem.startsWith(u8, c.text, "大對，"));
    // An explicit pin overrides a settled one on the same key.
    var explicit = UserLexicon.init(t.allocator);
    defer explicit.deinit();
    try explicit.pin(.{ .text = "打對", .span = Range.of(0, 2), .score = -16 }, top);
    try t.expectEqualStrings("打對，代錢包", (try d.decodeSegs(input, .{ .locked = &explicit }))[0].text);
}

test "the live pending cut leaves only the syllable in progress raw" {
    const d = try dec();
    defer d.deinit();
    const cut = struct {
        fn at(dd: *Dec, keys: []const u8) !usize {
            return dd.lex.livePendingCut(dd.a(), keys, true);
        }
    }.at;
    try t.expectEqual(@as(usize, 4), try cut(d, "sucl")); // 你好: all converts
    try t.expectEqual(@as(usize, 4), try cut(d, "sucl2")); // 你好 + raw ㄉ
    try t.expectEqual(@as(usize, 0), try cut(d, "2")); // lone initial stays raw
    try t.expectEqual(@as(usize, 0), try cut(d, ""));
    // A typo inside a run that starts clean: convert it all (repair).
    try t.expectEqual(@as(usize, 8), try cut(d, "su,,,,cl"));
    // No syllable can even start: 注音文, left raw whole (ㄏㄏㄏㄏ, ㄋㄝㄝ…).
    try t.expectEqual(@as(usize, 0), try cut(d, "cccc"));
    try t.expectEqual(@as(usize, 0), try cut(d, "s,,,,cl"));
}

test "segmentations split a pending run" {
    const d = try dec();
    defer d.deinit();
    const segmentations = try d.lex.segmentations(d.a(), "sucl", false, true);
    try t.expect(segmentations.len > 0);
    try expectStrings(&.{ "ㄋㄧ", "ㄏㄠ" }, try d.readings(segmentations[0]));
}

test "the node cap keeps candidates beyond the top three" {
    // Regression: per-node cap 3 hid daily chars (鍵 sat at #22 under
    // ㄐㄧㄢˋ, unreachable by paging or learning). Fixture 尼/泥 are 4th/5th
    // under ㄋㄧˇ and must be reachable; top-1 must not move.
    const d = try dec();
    defer d.deinit();
    const syllables = try d.syllables(try d.comp("su3"), true);
    const options = try d.lex.segmentOptions(d.a(), syllables, Range.of(0, 1), true, true);
    var ni = false;
    var ni2 = false;
    for (options) |o| {
        if (std.mem.eql(u8, o.text, "尼")) ni = true;
        if (std.mem.eql(u8, o.text, "泥")) ni2 = true;
    }
    try t.expect(ni and ni2);
    const decoded = try d.decode(syllables, .{});
    try t.expect(h.containsText(decoded, "尼"));
    try expectTop(decoded, "你");
}

// MARK: - Explicit tone weight

test "an explicit tone beats a frequency gap" {
    // 作ˋ outscores 左ˇ on frequency (-6 vs -8); the typed third tone must
    // still win top-1 (2026-09-18: mismatch 2.0 let 作 win).
    const d = try Dec.init(h.tsv(
        \\ㄗㄨㄛˇ|左|-8
        \\ㄗㄨㄛˋ|作|-6
        \\
    ));
    defer d.deinit();
    const toned = try d.decode(try d.syllables(try d.comp("yji3"), true), .{});
    try expectTop(toned, "左");
    try t.expect(toned[0].score - toned[1].score > 1.0);
    // Toneless stays frequency-first: no assertion, no penalty.
    try expectTop(try d.decode(try d.syllables(try d.comp("yji"), true), .{}), "作");
}

test "the neutral tone resolves via the toneless base" {
    // No ㄌㄨㄛ˙ entry anywhere: the neutral tone must fall back to the
    // toneless-base variants, not raw fallback.
    const d = try Dec.init(h.tsv(
        \\ㄌㄨㄛ|囉|-10
        \\
    ));
    defer d.deinit();
    const tops = try d.decode(try d.syllables(try d.comp("xji7"), true), .{});
    try expectTop(tops, "囉");
    try t.expectEqual(@as(i32, 0), tops[0].unresolved);
}

// MARK: - Shift tap

fn feed(tracker: *session_mod.ShiftTapTracker, shift: ?u1, held: bool, key_down: bool, other: bool, now: f64) bool {
    return tracker.feed(shift, held, key_down, other, now);
}

test "a Shift tap within the limit toggles" {
    var tracker: session_mod.ShiftTapTracker = .{};
    try t.expect(!feed(&tracker, 0, true, false, false, 100.0));
    try t.expect(feed(&tracker, 0, false, false, false, 100.1));
    // One-shot: release without press does nothing.
    try t.expect(!feed(&tracker, 0, false, false, false, 100.2));
}

test "a Shift hold past the limit does not toggle" {
    var tracker: session_mod.ShiftTapTracker = .{};
    try t.expect(!feed(&tracker, 1, true, false, false, 100.0));
    try t.expect(!feed(&tracker, 1, false, false, false, 100.5));
}

test "a Shift tap is cancelled by an intervening key down" {
    // Shift+A capital inline: press, real keyDown, release → no toggle.
    var tracker: session_mod.ShiftTapTracker = .{};
    try t.expect(!feed(&tracker, 0, true, false, false, 100.0));
    try t.expect(!feed(&tracker, null, true, true, false, 100.05));
    try t.expect(!feed(&tracker, 0, false, false, false, 100.1));
}

test "a Shift tap rejects chords and mismatched keys" {
    var tracker: session_mod.ShiftTapTracker = .{};
    // Cmd+Shift press never arms.
    try t.expect(!feed(&tracker, 0, true, false, true, 100.0));
    try t.expect(!feed(&tracker, 0, false, false, false, 100.1));
    // Left press + right release never completes.
    try t.expect(!feed(&tracker, 0, true, false, false, 101.0));
    try t.expect(!feed(&tracker, 1, false, false, false, 101.1));
}

test "the Shift tap duplicate-cycle guard" {
    // Electron-style duplicate press/release pair right after a trigger.
    var tracker: session_mod.ShiftTapTracker = .{};
    try t.expect(!feed(&tracker, 0, true, false, false, 100.0));
    try t.expect(feed(&tracker, 0, false, false, false, 100.1));
    try t.expect(!feed(&tracker, 0, true, false, false, 100.12));
    try t.expect(!feed(&tracker, 0, false, false, false, 100.14));
    // After cooldown, tapping works again.
    try t.expect(!feed(&tracker, 0, true, false, false, 101.0));
    try t.expect(feed(&tracker, 0, false, false, false, 101.1));
}

// MARK: - Local phrase supplement

test "a supplement concatenation parses and competes" {
    const base = "ㄒㄩㄢˇ\t選\t-12\n";
    const supplement = "# curated additions\n\nㄒㄩㄢˇ-ㄘˊ\t選詞\t-9.2\n";
    const d = try Dec.init(base ++ "\n" ++ supplement);
    defer d.deinit();
    // Toneless run: the supplemented word must beat the single-char fallback.
    var input: composition_mod.Composition = .{};
    for ("vm0h") |c| _ = try input.append(d.a(), c);
    try expectTop(try d.decodeSegs(input, .{}), "選詞");
}
