//! WebAssembly build for the site demo and the video renderer: the
//! `misstype_wasm_*` exports the site's JavaScript calls (site/demo.js,
//! site/playground.js, video/src/decoder.ts, tests/wasm_test.mjs), over the
//! Zig session. One engine and one session per module instance.
//!
//! Build: `cd core-zig && zig build wasm` -> zig-out/wasm/misstype.wasm
//! (wasm32-wasi, ReleaseSmall). The module exports `_start` (an empty main)
//! so callers that run it as a WASI command keep working.

const std = @import("std");
const core = @import("misstype");
const session_mod = core.session;
const Engine = session_mod.Engine;
const Session = session_mod.Session;
const Allocator = std.mem.Allocator;

const gpa = std.heap.c_allocator;

var io_instance: std.Io.Threaded = .init_single_threaded;

var engine: ?*Engine = null;
var session: ?*Session = null;
var last: session_mod.KeyResult = .{ .consumed = false };
/// Commits since the last `clear_committed` / `reset`; null = none.
var committed: ?std.ArrayList(u8) = null;
/// Alive until the next `get_state_json` call.
var state_json: std.ArrayList(u8) = .empty;

pub fn main() void {}

fn bytes(ptr: [*]const u8, len: usize) []const u8 {
    return ptr[0..len];
}

fn appendCommit(text: []const u8) void {
    if (committed == null) committed = .empty;
    committed.?.appendSlice(gpa, text) catch {};
}

export fn misstype_wasm_alloc(size: usize) ?[*]u8 {
    const memory = std.c.malloc(@max(1, size)) orelse return null;
    return @ptrCast(memory);
}

export fn misstype_wasm_free(ptr: ?[*]u8) void {
    if (ptr) |p| std.c.free(p);
}

export fn misstype_wasm_init(lexicon_ptr: [*]const u8, lexicon_len: usize, toneless_ptr: [*]const u8, toneless_len: usize) i32 {
    const decoder = core.Lexicon.create(gpa, &.{bytes(lexicon_ptr, lexicon_len)}, if (toneless_len > 0) bytes(toneless_ptr, toneless_len) else "") catch return 0;
    decoder.word_penalty = 0.5; // LexiconLoader.defaultWordPenalty
    if (session) |s| s.destroy();
    session = null;
    if (engine) |e| e.release();
    const created = Engine.create(gpa, io_instance.io(), decoder) catch {
        decoder.destroy();
        return 0;
    };
    created.settings.return_confirms_selection = true;
    created.settings.auto_show_candidates = false;
    created.settings.shift_toggle = true;
    created.shift_tap.tap_time_limit = 0.35;
    engine = created;
    session = Session.create(created) catch return 0;
    last = .{ .consumed = false };
    if (committed) |*c| c.deinit(gpa);
    committed = null;
    return 1;
}

export fn misstype_wasm_load_english(tsv_ptr: [*]const u8, tsv_len: usize) i32 {
    const e = engine orelse return 0;
    const lexicon = core.english.EnglishLexicon.create(gpa, bytes(tsv_ptr, tsv_len)) catch return 0;
    if (e.english_lexicon) |old| old.destroy();
    e.english_lexicon = lexicon;
    return 1;
}

const Parsed = struct { kind: session_mod.KeyKind, label: []const u8 = "" };

/// DOM `KeyboardEvent.code` -> a physical key; `text` is the fallback for
/// layouts whose code is not a US position.
fn parseKeyCode(code: []const u8, text: []const u8, label_buf: *[4]u8) Parsed {
    const named = [_]struct { []const u8, session_mod.KeyKind }{
        .{ "Space", .space },          .{ "Enter", .enter },           .{ "NumpadEnter", .enter },
        .{ "Tab", .tab },              .{ "Backspace", .backspace },   .{ "Delete", .forward_delete },
        .{ "Escape", .escape },        .{ "ArrowLeft", .left },        .{ "ArrowRight", .right },
        .{ "ArrowUp", .up },           .{ "ArrowDown", .down },        .{ "PageUp", .page_up },
        .{ "PageDown", .page_down },   .{ "ShiftLeft", .shift_left },  .{ "ShiftRight", .shift_right },
        .{ "ControlLeft", .modifier }, .{ "ControlRight", .modifier }, .{ "AltLeft", .modifier },
        .{ "AltRight", .modifier },    .{ "MetaLeft", .modifier },     .{ "MetaRight", .modifier },
    };
    for (named) |n| if (std.mem.eql(u8, n[0], code)) return .{ .kind = n[1] };
    if (std.mem.startsWith(u8, code, "Key") and code.len == 4) {
        label_buf[0] = std.ascii.toLower(code[3]);
        return .{ .kind = .character, .label = label_buf[0..1] };
    }
    if (std.mem.startsWith(u8, code, "Digit") and code.len == 6) {
        label_buf[0] = code[5];
        return .{ .kind = .character, .label = label_buf[0..1] };
    }
    const punctuation = [_]struct { []const u8, []const u8 }{
        .{ "Minus", "-" },      .{ "Equal", "=" },     .{ "BracketLeft", "[" }, .{ "BracketRight", "]" },
        .{ "Backslash", "\\" }, .{ "Semicolon", ";" }, .{ "Quote", "'" },       .{ "Backquote", "`" },
        .{ "Comma", "," },      .{ "Period", "." },    .{ "Slash", "/" },
    };
    for (punctuation) |p| if (std.mem.eql(u8, p[0], code)) return .{ .kind = .character, .label = p[1] };
    if (text.len == 1) {
        label_buf[0] = std.ascii.toLower(text[0]);
        return .{ .kind = .character, .label = label_buf[0..1] };
    }
    return .{ .kind = .other };
}

export fn misstype_wasm_handle_key(code_ptr: [*]const u8, code_len: usize, text_ptr: [*]const u8, text_len: usize, modifiers: i32, phase: i32, timestamp: f64) i32 {
    const s = session orelse return 0;
    const text = bytes(text_ptr, text_len);
    var label_buf: [4]u8 = undefined;
    const parsed = parseKeyCode(bytes(code_ptr, code_len), text, &label_buf);
    const result = s.handle(.{
        .kind = parsed.kind,
        .label = parsed.label,
        .text = if (text_len > 0) text else null,
        .mods = @intCast(modifiers & 0x1f),
        .release = phase == 1,
        .timestamp = if (timestamp > 0) timestamp else null,
    }) catch return 0;
    last = result;
    last.commit = null;
    if (result.commit) |c| appendCommit(c);
    return @intFromBool(result.consumed);
}

export fn misstype_wasm_pick_candidate(index: i32) void {
    const s = session orelse return;
    if (index < 0) return;
    s.pick(@intCast(index)) catch {};
}

export fn misstype_wasm_commit() i32 {
    const s = session orelse return 0;
    const text = (s.commit() catch return 0) orelse return 0;
    appendCommit(text);
    return 1;
}

export fn misstype_wasm_reset() void {
    const e = engine orelse return;
    if (session) |s| s.destroy();
    session = Session.create(e) catch null;
    if (committed) |*c| c.deinit(gpa);
    committed = null;
    last = .{ .consumed = false };
}

export fn misstype_wasm_clear_committed() void {
    if (committed) |*c| c.deinit(gpa);
    committed = null;
}

export fn misstype_wasm_toggle_english() i32 {
    const s = session orelse return 0;
    const e = engine orelse return 0;
    if (s.commit() catch null) |text| appendCommit(text);
    e.english = !e.english;
    return @intFromBool(e.english);
}

export fn misstype_wasm_set_english(enabled: i32) i32 {
    const s = session orelse return 0;
    const e = engine orelse return 0;
    const target = enabled != 0;
    if (e.english != target) {
        if (s.commit() catch null) |text| appendCommit(text);
        e.english = target;
    }
    return @intFromBool(e.english);
}

export fn misstype_wasm_set_setting(key_ptr: [*]const u8, key_len: usize, value: i32) void {
    const e = engine orelse return;
    const key = bytes(key_ptr, key_len);
    if (std.mem.eql(u8, key, "autoShowCandidates")) {
        e.settings.auto_show_candidates = value != 0;
    } else if (std.mem.eql(u8, key, "returnConfirmsSelection")) {
        e.settings.return_confirms_selection = value != 0;
    } else if (std.mem.eql(u8, key, "shiftToggle")) {
        e.settings.shift_toggle = value != 0;
    } else if (std.mem.eql(u8, key, "pageSize")) {
        e.settings.page_size = session_mod.clampPageSize(value);
    }
}

fn jsonString(out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(gpa, '"');
    for (text) |c| switch (c) {
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '"' => try out.appendSlice(gpa, "\\\""),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0...8, 11, 12, 14...31 => try out.print(gpa, "\\u{x:0>4}", .{c}),
        else => try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

fn jsonStrings(out: *std.ArrayList(u8), items: []const []const u8) !void {
    try out.append(gpa, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try out.append(gpa, ',');
        try jsonString(out, item);
    }
    try out.append(gpa, ']');
}

fn writeState(out: *std.ArrayList(u8), e: *Engine, s: *Session) !void {
    const view = try s.view();
    const page_size = @max(1, view.page_size);
    const page = view.selected / page_size;
    const count = view.candidates.len;
    const page_count = @max(1, (count + page_size - 1) / page_size);
    const page_start = page * page_size;
    const page_end = @min(page_start + page_size, count);
    const page_candidates = if (page_start < count) view.candidates[page_start..page_end] else view.candidates[0..0];
    try out.appendSlice(gpa, "{\"preedit\":");
    try jsonString(out, view.preedit);
    try out.print(gpa, ",\"caret\":{d},\"selected\":{d},\"showsCandidates\":{},\"keysActive\":{},\"pageSize\":{d},\"page\":{d},\"pageCount\":{d},\"pageSelected\":{d},", .{
        view.caret, view.selected, view.shows_candidates, view.keys_active,
        page_size,  page,          page_count,            view.selected % page_size,
    });
    try out.appendSlice(gpa, "\"candidates\":");
    try jsonStrings(out, view.candidates);
    try out.appendSlice(gpa, ",\"pageCandidates\":");
    try jsonStrings(out, page_candidates);
    try out.appendSlice(gpa, ",\"selectionKeys\":");
    try jsonStrings(out, view.selection_keys);
    try out.appendSlice(gpa, ",\"segments\":[");
    for (view.segments, 0..) |seg, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.print(gpa, "[{d},{d}]", .{ seg.start, seg.end });
    }
    try out.appendSlice(gpa, "],\"focus\":");
    if (view.focus) |f| try out.print(gpa, "[{d},{d}]", .{ f.start, f.end }) else try out.appendSlice(gpa, "null");
    try out.appendSlice(gpa, ",\"mark\":");
    if (view.mark) |mark| {
        try out.print(gpa, "{{\"range\":[{d},{d}],\"reading\":", .{ mark.range.start, mark.range.end });
        try jsonString(out, mark.reading);
        try out.appendSlice(gpa, ",\"action\":");
        try jsonString(out, switch (mark.action) {
            .add => "add",
            .remove => "remove",
            .too_short => "tooShort",
            .too_long => "tooLong",
            .unavailable, .none => "unavailable",
        });
        try out.append(gpa, '}');
    } else try out.appendSlice(gpa, "null");
    try out.appendSlice(gpa, ",\"lastCommit\":");
    if (committed) |c| try jsonString(out, c.items) else try out.appendSlice(gpa, "null");
    try out.print(gpa, ",\"consumed\":{},\"beep\":{},\"modeChanged\":{},\"latinToggled\":{},\"english\":{},\"latinActive\":{}}}", .{
        last.consumed, last.beep, last.mode_changed, last.latin_toggled, e.english, s.latinActive(),
    });
}

export fn misstype_wasm_get_state_json() ?[*:0]const u8 {
    state_json.clearRetainingCapacity();
    if (engine != null and session != null) {
        writeState(&state_json, engine.?, session.?) catch {
            state_json.clearRetainingCapacity();
            state_json.appendSlice(gpa, "{}") catch return null;
        };
    } else {
        state_json.appendSlice(gpa, "{}") catch return null;
    }
    state_json.append(gpa, 0) catch return null;
    return @ptrCast(state_json.items.ptr);
}
