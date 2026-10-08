//! Zhuyin keyboard tables (port of ZhuyinKeyboard / Syllable in
//! Sources/MisstypeCore/Keyboard.swift). Keys are US-ANSI unshifted labels,
//! one byte each.

const std = @import("std");

/// Bopomofo symbol typed by `key`, or null for non-symbol keys.
pub fn symbol(key: u8) ?[]const u8 {
    return switch (key) {
        '1' => "ㄅ", 'q' => "ㄆ", 'a' => "ㄇ", 'z' => "ㄈ", '2' => "ㄉ", 'w' => "ㄊ", 's' => "ㄋ", 'x' => "ㄌ",
        'e' => "ㄍ", 'd' => "ㄎ", 'c' => "ㄏ", 'r' => "ㄐ", 'f' => "ㄑ", 'v' => "ㄒ", '5' => "ㄓ", 't' => "ㄔ",
        'g' => "ㄕ", 'b' => "ㄖ", 'y' => "ㄗ", 'h' => "ㄘ", 'n' => "ㄙ", 'u' => "ㄧ", 'j' => "ㄨ", 'm' => "ㄩ",
        '8' => "ㄚ", 'i' => "ㄛ", 'k' => "ㄜ", ',' => "ㄝ", '9' => "ㄞ", 'o' => "ㄟ", 'l' => "ㄠ", '.' => "ㄡ",
        '0' => "ㄢ", 'p' => "ㄣ", ';' => "ㄤ", '/' => "ㄥ", '-' => "ㄦ",
        else => null,
    };
}

/// Tone mark typed by `key` ("" = space, the explicit first tone), or null.
pub fn tone(key: u8) ?[]const u8 {
    return switch (key) {
        '3' => "ˇ", '4' => "ˋ", '6' => "ˊ", '7' => "˙", ' ' => "",
        else => null,
    };
}

pub const Syllable = struct {
    keys: []const u8,
    /// null = no tone evidence; ' ' = explicit first tone.
    tone: ?u8,

    /// Symbols of the keys, then the tone mark. Keys without a symbol are
    /// dropped, as in Swift.
    pub fn reading(self: Syllable, buf: []u8) []const u8 {
        var len: usize = 0;
        for (self.keys) |key| if (symbol(key)) |s| {
            @memcpy(buf[len..][0..s.len], s);
            len += s.len;
        };
        if (self.tone) |t| if (tone(t)) |s| {
            @memcpy(buf[len..][0..s.len], s);
            len += s.len;
        };
        return buf[0..len];
    }

    /// Longest reading: 4 symbols + tone, 3 UTF-8 bytes each, rounded up.
    pub const max_reading_bytes = 32;
};

/// The reading without tone marks (ˊˇˋ˙); `buf` must hold `text.len` bytes.
pub fn withoutTone(text: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        // ˊ U+02CA, ˇ U+02C7, ˋ U+02CB, ˙ U+02D9: all `CB xx` in UTF-8.
        if (i + 1 < text.len and text[i] == 0xCB and
            (text[i + 1] == 0x8A or text[i + 1] == 0x87 or text[i + 1] == 0x8B or text[i + 1] == 0x99))
        {
            i += 2;
            continue;
        }
        buf[len] = text[i];
        len += 1;
        i += 1;
    }
    return buf[0..len];
}

test "reading and toneless form" {
    var buf: [Syllable.max_reading_bytes]u8 = undefined;
    const ni = Syllable{ .keys = "su", .tone = '3' };
    try std.testing.expectEqualStrings("ㄋㄧˇ", ni.reading(&buf));
    const first = Syllable{ .keys = "g/", .tone = ' ' };
    try std.testing.expectEqualStrings("ㄕㄥ", first.reading(&buf));
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ㄋㄧ", withoutTone("ㄋㄧˇ", &out));
}
