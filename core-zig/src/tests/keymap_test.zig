//! Port of tests/MisstypeCoreTests/KeyMapTests.swift and the hardware-map
//! half of CoreTests: the evdev, macOS and character maps of the C ABI agree
//! on physical key labels and special keys.

const std = @import("std");
const t = std.testing;
const capi = @import("../capi.zig");
const keyboard = @import("../keyboard.zig");

const char_kind: c_int = 0;

fn kindOfEvdev(code: i32, label: *?[*:0]const u8) c_int {
    return capi.misstype_key_from_evdev(code, label);
}

fn kindOfMac(code: i32, label: *?[*:0]const u8) c_int {
    return capi.misstype_key_from_mac(code, label);
}

fn kindOfWindows(code: i32, label: *?[*:0]const u8) c_int {
    return capi.misstype_key_from_windows(code, label);
}

fn expectLabel(want: []const u8, label: ?[*:0]const u8) !void {
    try t.expect(label != null);
    try t.expectEqualStrings(want, std.mem.span(label.?));
}

fn kindNamed(name: enum { character, space, enter, tab, backspace, forward_delete, escape, left, right, up, down, page_up, page_down, shift_left, shift_right, modifier, other }) c_int {
    var label: ?[*:0]const u8 = null;
    return switch (name) {
        .character => capi.misstype_key_from_evdev(31, &label),
        .space => capi.misstype_key_from_evdev(57, &label),
        .enter => capi.misstype_key_from_evdev(28, &label),
        .tab => capi.misstype_key_from_evdev(15, &label),
        .backspace => capi.misstype_key_from_evdev(14, &label),
        .forward_delete => capi.misstype_key_from_evdev(111, &label),
        .escape => capi.misstype_key_from_evdev(1, &label),
        .left => capi.misstype_key_from_evdev(105, &label),
        .right => capi.misstype_key_from_evdev(106, &label),
        .up => capi.misstype_key_from_evdev(103, &label),
        .down => capi.misstype_key_from_evdev(108, &label),
        .page_up => capi.misstype_key_from_evdev(104, &label),
        .page_down => capi.misstype_key_from_evdev(109, &label),
        .shift_left => capi.misstype_key_from_evdev(42, &label),
        .shift_right => capi.misstype_key_from_evdev(54, &label),
        .modifier => capi.misstype_key_from_evdev(29, &label),
        .other => capi.misstype_key_from_evdev(102, &label),
    };
}

fn labelsOf(comptime kindFn: fn (i32, *?[*:0]const u8) c_int, max: i32) !std.StringArrayHashMapUnmanaged(void) {
    var set: std.StringArrayHashMapUnmanaged(void) = .empty;
    errdefer set.deinit(t.allocator);
    var code: i32 = 0;
    while (code < max) : (code += 1) {
        var label: ?[*:0]const u8 = null;
        if (kindFn(code, &label) == char_kind) try set.put(t.allocator, std.mem.span(label.?), {});
    }
    return set;
}

test "evdev and Mac labels match" {
    var evdev = try labelsOf(kindOfEvdev, 256);
    defer evdev.deinit(t.allocator);
    var mac = try labelsOf(kindOfMac, 256);
    defer mac.deinit(t.allocator);
    // Evdev and Mac key labels must be identical (47 labels).
    try t.expectEqual(@as(usize, 47), evdev.count());
    try t.expectEqual(@as(usize, 47), mac.count());
    for (evdev.keys()) |label| try t.expect(mac.contains(label));
}

test "evdev key mappings" {
    var label: ?[*:0]const u8 = null;
    try t.expectEqual(char_kind, kindOfEvdev(31, &label)); // KEY_S
    try expectLabel("s", label);
    try t.expectEqual(char_kind, kindOfEvdev(4, &label)); // KEY_3
    try expectLabel("3", label);
    try t.expectEqual(kindNamed(.space), kindOfEvdev(57, &label)); // KEY_SPACE
    try t.expectEqual(kindNamed(.enter), kindOfEvdev(96, &label)); // KEY_KPENTER
    try t.expectEqual(kindNamed(.shift_left), kindOfEvdev(42, &label));
    try t.expectEqual(kindNamed(.shift_right), kindOfEvdev(54, &label));
    try t.expectEqual(kindNamed(.modifier), kindOfEvdev(29, &label)); // KEY_LEFTCTRL
    try t.expectEqual(kindNamed(.other), kindOfEvdev(102, &label)); // KEY_HOME
    try t.expectEqual(kindNamed(.page_down), kindOfEvdev(109, &label));
    try t.expectEqual(kindNamed(.page_up), kindOfEvdev(104, &label));
}

test "the Mac hardware map covers every Zhuyin symbol once" {
    var labels = try labelsOf(kindOfMac, 256);
    defer labels.deinit(t.allocator);
    var mapped: usize = 0;
    for (labels.keys()) |label| {
        if (keyboard.isSymbol(label[0])) mapped += 1;
    }
    try t.expectEqual(@as(usize, 37), mapped);
    for (keyboard.symbol_keys) |key| try t.expect(labels.contains(&.{key}));
    // Every tone key is reachable; space is its own key.
    for ("3467") |key| try t.expect(labels.contains(&.{key}));
    var label: ?[*:0]const u8 = null;
    try t.expectEqual(char_kind, kindOfMac(45, &label));
    try expectLabel("n", label);
    try t.expectEqual(char_kind, kindOfMac(28, &label));
    try expectLabel("8", label);
    try t.expectEqual(char_kind, kindOfMac(27, &label));
    try expectLabel("-", label);
    try t.expectEqual(kindNamed(.space), kindOfMac(49, &label));
    try t.expectEqual(kindNamed(.shift_left), kindOfMac(56, &label));
    try t.expectEqual(kindNamed(.enter), kindOfMac(76, &label));
    try t.expectEqual(kindNamed(.page_down), kindOfMac(121, &label));
    try t.expectEqual(kindNamed(.page_up), kindOfMac(116, &label));
    try t.expectEqual(kindNamed(.modifier), kindOfMac(58, &label));
    // "=" is not a Zhuyin key.
    try t.expectEqual(char_kind, kindOfMac(24, &label));
    try t.expect(!keyboard.isSymbol('=') and !keyboard.isTone('='));
}

fn character(text: [:0]const u8) struct { kind: c_int, label: ?[*:0]const u8, shifted: i32 } {
    var label: ?[*:0]const u8 = null;
    var shifted: i32 = -1;
    const kind = capi.misstype_key_from_character(text.ptr, &label, &shifted);
    return .{ .kind = kind, .label = label, .shifted = shifted };
}

test "US layout mappings" {
    // Uppercase letters → shifted.
    var r = character("A");
    try t.expectEqual(char_kind, r.kind);
    try expectLabel("a", r.label);
    try t.expectEqual(@as(i32, 1), r.shifted);
    r = character("Z");
    try expectLabel("z", r.label);
    try t.expectEqual(@as(i32, 1), r.shifted);
    // Shifted symbols.
    r = character("!");
    try expectLabel("1", r.label);
    try t.expectEqual(@as(i32, 1), r.shifted);
    r = character("~");
    try expectLabel("`", r.label);
    try t.expectEqual(@as(i32, 1), r.shifted);
    // Unshifted symbols.
    r = character(";");
    try expectLabel(";", r.label);
    try t.expectEqual(@as(i32, 0), r.shifted);
    // Space.
    r = character(" ");
    try t.expectEqual(kindNamed(.space), r.kind);
    try t.expectEqual(@as(i32, 0), r.shifted);
    // Non-ASCII → other.
    r = character("中");
    try t.expectEqual(kindNamed(.other), r.kind);
}

test "the US layout covers every label" {
    // Every label from the Mac map must be mappable for its unshifted
    // character, unshifted.
    var labels = try labelsOf(kindOfMac, 256);
    defer labels.deinit(t.allocator);
    for (labels.keys()) |label| {
        var buf: [2:0]u8 = .{ label[0], 0 };
        const r = character(&buf);
        try t.expectEqual(char_kind, r.kind);
        try expectLabel(label, r.label);
        try t.expectEqual(@as(i32, 0), r.shifted);
    }
}

test "Zhuyin and tone labels are present in the evdev map" {
    var labels = try labelsOf(kindOfEvdev, 256);
    defer labels.deinit(t.allocator);
    for (keyboard.symbol_keys) |key| try t.expect(labels.contains(&.{key}));
    for ("3467") |key| try t.expect(labels.contains(&.{key}));
}

test "Windows scan codes agree with evdev on the main block" {
    // The Windows table reuses evdev's labels for 0x00...0x58; this pins the
    // coincidence so a change to either table cannot drift silently.
    var win = try labelsOf(kindOfWindows, 0x100);
    defer win.deinit(t.allocator);
    var evdev = try labelsOf(kindOfEvdev, 256);
    defer evdev.deinit(t.allocator);
    try t.expectEqual(@as(usize, 47), win.count());
    for (evdev.keys()) |label| try t.expect(win.contains(label));
    var code: i32 = 0;
    while (code <= 0x58) : (code += 1) {
        var w: ?[*:0]const u8 = null;
        var e: ?[*:0]const u8 = null;
        const wk = kindOfWindows(code, &w);
        const ek = kindOfEvdev(code, &e);
        if (wk == char_kind or ek == char_kind) {
            try t.expectEqual(ek, wk);
            try expectLabel(std.mem.span(e.?), w);
        }
    }
}

test "Windows key mappings" {
    var label: ?[*:0]const u8 = null;
    try t.expectEqual(char_kind, kindOfWindows(0x1F, &label)); // S
    try expectLabel("s", label);
    try t.expectEqual(char_kind, kindOfWindows(0x04, &label)); // 3
    try expectLabel("3", label);
    try t.expectEqual(char_kind, kindOfWindows(0x2B, &label)); // backslash
    try expectLabel("\\", label);
    try t.expectEqual(kindNamed(.space), kindOfWindows(0x39, &label));
    try t.expectEqual(kindNamed(.enter), kindOfWindows(0x1C, &label));
    try t.expectEqual(kindNamed(.enter), kindOfWindows(0xE01C, &label)); // numpad Enter
    try t.expectEqual(kindNamed(.tab), kindOfWindows(0x0F, &label));
    try t.expectEqual(kindNamed(.backspace), kindOfWindows(0x0E, &label));
    try t.expectEqual(kindNamed(.escape), kindOfWindows(0x01, &label));
    try t.expectEqual(kindNamed(.forward_delete), kindOfWindows(0xE053, &label));
    try t.expectEqual(kindNamed(.left), kindOfWindows(0xE04B, &label));
    try t.expectEqual(kindNamed(.right), kindOfWindows(0xE04D, &label));
    try t.expectEqual(kindNamed(.up), kindOfWindows(0xE048, &label));
    try t.expectEqual(kindNamed(.down), kindOfWindows(0xE050, &label));
    try t.expectEqual(kindNamed(.page_up), kindOfWindows(0xE049, &label));
    try t.expectEqual(kindNamed(.page_down), kindOfWindows(0xE051, &label));
    try t.expectEqual(kindNamed(.shift_left), kindOfWindows(0x2A, &label));
    try t.expectEqual(kindNamed(.shift_right), kindOfWindows(0x36, &label));
    for ([_]i32{ 0x1D, 0x38, 0x3A, 0xE01D, 0xE038, 0xE05B, 0xE05C }) |code| {
        try t.expectEqual(kindNamed(.modifier), kindOfWindows(code, &label));
        try t.expect(label == null);
    }
}

test "Windows extended keys are not their plain twins" {
    var label: ?[*:0]const u8 = null;
    // Plain 0x48 / 0x4B / 0x50 / 0x53 are numpad 8 / 4 / 2 / Decimal (with
    // Num Lock they type digits), the extended ones are the arrow cluster.
    for ([_]i32{ 0x47, 0x48, 0x49, 0x4B, 0x4D, 0x4F, 0x50, 0x51, 0x52, 0x53 }) |code| {
        try t.expectEqual(kindNamed(.other), kindOfWindows(code, &label));
    }
    // Fake shifts injected around numpad navigation never toggle Shift.
    try t.expectEqual(kindNamed(.other), kindOfWindows(0xE02A, &label));
    try t.expectEqual(kindNamed(.other), kindOfWindows(0xE036, &label));
    // Function keys, Num Lock, out-of-range input.
    try t.expectEqual(kindNamed(.other), kindOfWindows(0x3B, &label)); // F1
    try t.expectEqual(kindNamed(.other), kindOfWindows(0x45, &label)); // Num Lock
    try t.expectEqual(kindNamed(.other), kindOfWindows(-1, &label));
    try t.expectEqual(kindNamed(.other), kindOfWindows(0x1_0000, &label));
    // NULL label pointer is accepted.
    try t.expectEqual(char_kind, capi.misstype_key_from_windows(0x1F, null));
}

test "Zhuyin and tone labels are present in the Windows map" {
    var labels = try labelsOf(kindOfWindows, 0x100);
    defer labels.deinit(t.allocator);
    for (keyboard.symbol_keys) |key| try t.expect(labels.contains(&.{key}));
    for ("3467") |key| try t.expect(labels.contains(&.{key}));
}
