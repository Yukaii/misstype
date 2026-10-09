//! CJK punctuation table, keyed by physical key label (port of
//! Sources/MisstypeCore/Punctuation.swift).

const std = @import("std");

/// Symbol menu: after a mark is typed, the candidate list offers its group.
pub const groups = [_][]const []const u8{
    &.{ "，", "、", "；", "：", "︐", "︑" },
    &.{ "。", "．", "…", "⋯", "‧" },
    &.{ "？", "⁇", "⁈", "﹖" },
    &.{ "！", "‼", "⁉", "﹗" },
    &.{ "「", "『", "“", "‘", "《", "〈", "﹁", "﹃" },
    &.{ "」", "』", "”", "’", "》", "〉", "﹂", "﹄" },
    &.{ "（", "【", "〔", "［", "｛", "〖", "〘" },
    &.{ "）", "】", "〕", "］", "｝", "〗", "〙" },
    &.{ "——", "─", "—", "～", "〜", "＿" },
    &.{ "·", "‧", "•", "・", "∙" },
    &.{ "＠", "©", "®", "™" },
    &.{ "＃", "♯", "№", "♭", "♮" },
    &.{ "＄", "￥", "￡", "€", "¢", "¥" },
    &.{ "％", "‰", "‱" },
    &.{ "︿", "＾", "∧", "↑", "→", "←", "↓" },
    &.{ "＆", "§", "¶" },
    &.{ "＊", "※", "★", "☆", "✱" },
    &.{ "＋", "±", "×", "÷", "－", "＝", "≠", "≈" },
};

const key_outputs = [_][]const u8{
    "，",
    "。",
    "？",
    "！",
    "：",
    "「",
    "」",
    "『",
    "』",
    "、",
    "·",
    "；",
    "——",
    "＠",
    "＃",
    "＄",
    "％",
    "︿",
    "＆",
    "＊",
    "（",
    "）",
    "＋",
    "｛",
    "｝",
    "～",
};

/// Every CJK literal this IME can insert, deduplicated. A composition stores
/// a literal as its index here.
pub const literals: []const []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    var out: []const []const u8 = &.{};
    for (key_outputs ++ flatGroups()) |text| {
        var seen = false;
        for (out) |existing| {
            if (std.mem.eql(u8, existing, text)) seen = true;
        }
        if (!seen) out = out ++ [_][]const u8{text};
    }
    break :blk out;
};

fn flatGroups() [groupsLen()][]const u8 {
    var out: [groupsLen()][]const u8 = undefined;
    var n = 0;
    for (groups) |group| for (group) |text| {
        out[n] = text;
        n += 1;
    };
    return out;
}

fn groupsLen() usize {
    var n = 0;
    for (groups) |group| n += group.len;
    return n;
}

pub const Literal = u8;

pub fn literalIndex(text: []const u8) ?Literal {
    for (literals, 0..) |existing, i| {
        if (std.mem.eql(u8, existing, text)) return @intCast(i);
    }
    return null;
}

pub fn isLiteral(text: []const u8) bool {
    return literalIndex(text) != null;
}

/// Menu choices for a just-typed literal: itself first, then the rest of
/// its group (first group holding it). Empty when it has no group.
pub fn choices(literal: []const u8, out: *[16][]const u8) []const []const u8 {
    for (groups) |group| {
        for (group) |text| {
            if (!std.mem.eql(u8, text, literal)) continue;
            out[0] = literal;
            var n: usize = 1;
            for (group) |other| {
                if (!std.mem.eql(u8, other, literal)) {
                    out[n] = other;
                    n += 1;
                }
            }
            return out[0..n];
        }
    }
    return out[0..0];
}

/// `'` and Shift+`'` pair themselves within the composition: 「 opens, and
/// stays 」 while a 「 is unclosed (Shift: 『 』).
pub fn smartQuote(label: []const u8, shift: bool, ctrl: bool, keys_literals: []const ?[]const u8) ?[]const u8 {
    if (!std.mem.eql(u8, label, "'") or ctrl) return null;
    const open: []const u8 = if (shift) "『" else "「";
    const close: []const u8 = if (shift) "』" else "」";
    var depth: usize = 0;
    for (keys_literals) |maybe| {
        const key = maybe orelse continue;
        if (std.mem.eql(u8, key, open)) {
            depth += 1;
        } else if (std.mem.eql(u8, key, close)) {
            depth -|= 1;
        }
    }
    return if (depth > 0) close else open;
}

pub fn output(label: []const u8, shift: bool, ctrl: bool) ?[]const u8 {
    if (ctrl and !shift and std.mem.eql(u8, label, ";")) return "；";
    if (label.len != 1) return null;
    if (shift) {
        const s: ?[]const u8 = switch (label[0]) {
            '1' => "！",
            '2' => "＠",
            '3' => "＃",
            '4' => "＄",
            '5' => "％",
            '6' => "︿",
            '7' => "＆",
            '8' => "＊",
            '9' => "（",
            '0' => "）",
            '=' => "＋",
            '[' => "｛",
            ']' => "｝",
            '`' => "～",
            '-' => "——",
            '\'' => "」",
            ';' => "：",
            '\\' => "·",
            ',' => "，",
            '/' => "？",
            '.' => "。",
            else => null,
        };
        if (s) |text| return text;
    }
    return switch (label[0]) {
        ']' => "』",
        '[' => "『",
        '\'' => "「",
        '\\' => "、",
        else => null,
    };
}

test "literals and menus" {
    try std.testing.expect(isLiteral("，"));
    try std.testing.expect(isLiteral("‧"));
    try std.testing.expect(!isLiteral(","));
    var buf: [16][]const u8 = undefined;
    const menu = choices("、", &buf);
    try std.testing.expectEqualStrings("、", menu[0]);
    try std.testing.expectEqualStrings("，", menu[1]);
    try std.testing.expectEqualStrings("「", smartQuote("'", false, false, &.{}).?);
    try std.testing.expectEqualStrings("」", smartQuote("'", false, false, &.{"「"}).?);
}
