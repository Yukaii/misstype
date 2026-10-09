//! Port of tests/MisstypeCoreTests/LatinDigitTests.swift: digits inside a
//! latin run (backtick or mid-composition Shift tap) are text.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const Harness = h.Harness;

const rows = h.tsv(
    \\ㄋㄧˇ|你|-5
    \\ㄏㄠˇ|好|-5
    \\ㄋㄧˇ-ㄏㄠˇ|你好|-3
    \\
);

fn make() !*Harness {
    return Harness.init(rows);
}

test "digits stay in the Latin run" {
    const s = try make();
    defer s.deinit();
    try s.typed("`abc123");
    try s.expectPreedit("abc123");
    try s.expectRaw("abc123");
    try t.expectEqualStrings("abc123", (try s.enter()).commit.?);
}

test "Chinese resumes after the closing backtick" {
    const s = try make();
    defer s.deinit();
    try s.typed("`mp3`su3cl3");
    try s.expectPreedit("mp3你好");
}

test "digits outside a Latin run are still Zhuyin" {
    const s = try make();
    defer s.deinit();
    try s.typed("su3cl3");
    try s.expectPreedit("你好");
    // A digit right after Chinese keys is a tone/Zhuyin key, not text.
    try s.expectRaw("ㄋㄧˇㄏㄠˇ");
}

test "backspace keeps the run and digits erase" {
    const s = try make();
    defer s.deinit();
    try s.typed("`ab12");
    _ = try s.backspace();
    try s.expectPreedit("ab1");
    try s.typed("2");
    try s.expectPreedit("ab12");
}

test "global English mode passes digits through" {
    const s = try make();
    defer s.deinit();
    s.engine.english = true;
    for ("1234567890") |digit| {
        const label = [_]u8{digit};
        try t.expect(!(try s.chr(&label, 0, &label)).consumed);
    }
}

test "digits after a Shift-tap Latin run are digits" {
    // The reported case: English started with a lone Shift tap mid-composition.
    const s = try make();
    defer s.deinit();
    try s.typed("su3");
    _ = try s.send(.{ .kind = .shift_left, .mods = h.shift, .timestamp = 100 });
    try t.expect((try s.send(.{ .kind = .shift_left, .release = true, .timestamp = 100.1 })).latin_toggled);
    try s.typed("abc123");
    try s.expectPreedit("你abc123");
    // A second tap closes the run; Zhuyin resumes.
    _ = try s.send(.{ .kind = .shift_left, .mods = h.shift, .timestamp = 101 });
    try t.expect((try s.send(.{ .kind = .shift_left, .release = true, .timestamp = 101.1 })).latin_toggled);
    try s.typed("cl3");
    try s.expectPreedit("你abc123好");
}
