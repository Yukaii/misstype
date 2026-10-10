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
    } else if (std.mem.eql(u8, key, "userLearning")) {
        e.settings.user_learning = value != 0;
    } else if (std.mem.eql(u8, key, "channelLearning")) {
        e.settings.channel_learning = value != 0;
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

// MARK: - User dictionary
//
// The same file the desktop IMEs keep (`user_dictionary.tsv`, vChewing user
// data: `text reading [weight]`, `!text reading` hides a built-in word). The
// module has no storage of its own: the host loads the text at start, saves it
// when `user_dictionary_count` changes (a phrase marked with Shift+←/→ and
// filed with Return changes it) and applies edits with `set_user_dictionary`.

/// Alive until the next dictionary call.
var dictionary_reply: std.ArrayList(u8) = .empty;

fn dictionaryReply() ?[*:0]const u8 {
    dictionary_reply.append(gpa, 0) catch return null;
    return @ptrCast(dictionary_reply.items.ptr);
}

/// Canonical text of the current dictionary.
export fn misstype_wasm_user_dictionary_text() ?[*:0]const u8 {
    dictionary_reply.clearRetainingCapacity();
    if (engine) |e| {
        const text = e.user_dictionary.serialized(gpa) catch return null;
        defer gpa.free(text);
        dictionary_reply.appendSlice(gpa, text) catch return null;
    }
    return dictionaryReply();
}

/// Added plus hidden words; changes whenever a phrase is filed or removed.
export fn misstype_wasm_user_dictionary_count() i32 {
    const e = engine orelse return 0;
    return @intCast(e.user_dictionary.added.items.len + e.user_dictionary.excluded.items.len);
}

/// Replaces the dictionary with the parsed text (bad lines are skipped, as in
/// `check`). Returns 1 on success.
export fn misstype_wasm_set_user_dictionary(text_ptr: [*]const u8, text_len: usize) i32 {
    const e = engine orelse return 0;
    const dictionary = core.user_dictionary.UserDictionary.parse(gpa, bytes(text_ptr, text_len), null) catch return 0;
    e.setUserDictionary(dictionary, false) catch return 0;
    return 1;
}

/// `{"added":n,"hidden":n,"problems":[{"line":n,"message":"…"}]}` for editor text.
export fn misstype_wasm_check_user_dictionary(text_ptr: [*]const u8, text_len: usize) ?[*:0]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var problems: std.ArrayList(core.user_dictionary.Problem) = .empty;
    const dictionary = core.user_dictionary.UserDictionary.parse(a, bytes(text_ptr, text_len), &problems) catch return null;
    dictionary_reply.clearRetainingCapacity();
    dictionary_reply.print(gpa, "{{\"added\":{d},\"hidden\":{d},\"problems\":[", .{ dictionary.added.items.len, dictionary.excluded.items.len }) catch return null;
    for (problems.items, 0..) |p, i| {
        if (i > 0) dictionary_reply.append(gpa, ',') catch return null;
        dictionary_reply.print(gpa, "{{\"line\":{d},\"message\":", .{p.line}) catch return null;
        jsonString(&dictionary_reply, p.message) catch return null;
        dictionary_reply.append(gpa, '}') catch return null;
    }
    dictionary_reply.appendSlice(gpa, "]}") catch return null;
    return dictionaryReply();
}

/// Merges `source` (vChewing user data) into the editor text:
/// `{"text":"…","added":n,"duplicates":n,"skipped":n}`. Nothing is applied.
export fn misstype_wasm_import_user_dictionary(source_ptr: [*]const u8, source_len: usize, text_ptr: [*]const u8, text_len: usize) ?[*:0]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const result = core.user_dictionary.importing(arena.allocator(), bytes(source_ptr, source_len), bytes(text_ptr, text_len)) catch return null;
    dictionary_reply.clearRetainingCapacity();
    dictionary_reply.appendSlice(gpa, "{\"text\":") catch return null;
    jsonString(&dictionary_reply, result.text) catch return null;
    dictionary_reply.print(gpa, ",\"added\":{d},\"duplicates\":{d},\"skipped\":{d}}}", .{ result.added, result.duplicates, result.skipped }) catch return null;
    return dictionaryReply();
}

// MARK: - Learning
//
// What the decoder learns from explicit picks (`user_lexicon.json`) and, when
// enabled, from typing slips (`channel_model.json`): the same JSON the desktop
// IMEs keep. The module has no storage of its own: the host saves
// `learned_data` / `channel_data` when `learning_revision` changes and feeds
// them back with `load_learned` / `load_channel` at start.

/// Alive until the next learning call.
var learning_reply: std.ArrayList(u8) = .empty;

fn learningReply() ?[*:0]const u8 {
    learning_reply.append(gpa, 0) catch return null;
    return @ptrCast(learning_reply.items.ptr);
}

/// Changes whenever a phrase is learned or forgotten, or a typing slip noted.
export fn misstype_wasm_learning_revision() i32 {
    const e = engine orelse return 0;
    return @bitCast(e.learning_revision);
}

export fn misstype_wasm_learned_count() i32 {
    const e = engine orelse return 0;
    return @intCast(e.user_lexicon.count());
}

/// The learned phrases as the desktop `user_lexicon.json`.
export fn misstype_wasm_learned_data() ?[*:0]const u8 {
    learning_reply.clearRetainingCapacity();
    if (engine) |e| {
        const data = e.user_lexicon.encode(gpa) catch return null;
        defer gpa.free(data);
        learning_reply.appendSlice(gpa, data) catch return null;
    }
    return learningReply();
}

/// Replaces the learned phrases; 1 on success, 0 (nothing changed) if `data`
/// is not a learned-phrases file.
export fn misstype_wasm_load_learned(data_ptr: [*]const u8, data_len: usize) i32 {
    const e = engine orelse return 0;
    e.installUserLexicon(bytes(data_ptr, data_len)) catch return 0;
    return 1;
}

/// `[{"reading":"ㄋㄧㄏㄠ","text":"你好","count":n,"updatedAt":secs}]`, newest first.
export fn misstype_wasm_learned_phrases() ?[*:0]const u8 {
    learning_reply.clearRetainingCapacity();
    learning_reply.append(gpa, '[') catch return null;
    if (engine) |e| {
        const Row = struct { key: []const u8, text: []const u8, record: core.user_lexicon.Record };
        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(gpa);
        var it = e.user_lexicon.entries.iterator();
        while (it.next()) |entry| {
            var texts = entry.value_ptr.iterator();
            while (texts.next()) |t| rows.append(gpa, .{ .key = entry.key_ptr.*, .text = t.key_ptr.*, .record = t.value_ptr.* }) catch return null;
        }
        std.mem.sort(Row, rows.items, {}, struct {
            fn newer(_: void, a: Row, b: Row) bool {
                return a.record.updated_at > b.record.updated_at;
            }
        }.newer);
        for (rows.items, 0..) |row, i| {
            if (i > 0) learning_reply.append(gpa, ',') catch return null;
            learning_reply.appendSlice(gpa, "{\"reading\":") catch return null;
            jsonString(&learning_reply, row.key) catch return null;
            learning_reply.appendSlice(gpa, ",\"text\":") catch return null;
            jsonString(&learning_reply, row.text) catch return null;
            learning_reply.print(gpa, ",\"count\":{d},\"updatedAt\":{d}}}", .{ row.record.count, row.record.updated_at }) catch return null;
        }
    }
    learning_reply.append(gpa, ']') catch return null;
    return learningReply();
}

/// Forgets one learned phrase.
export fn misstype_wasm_forget_learned(key_ptr: [*]const u8, key_len: usize, text_ptr: [*]const u8, text_len: usize) void {
    const e = engine orelse return;
    e.forgetLearned(bytes(key_ptr, key_len), bytes(text_ptr, text_len)) catch {};
}

export fn misstype_wasm_clear_learned() void {
    const e = engine orelse return;
    e.clearUserLexicon() catch {};
}

export fn misstype_wasm_channel_count() i32 {
    const e = engine orelse return 0;
    return @intCast(e.channel_learner.pairCount());
}

/// The learned typing slips as the desktop `channel_model.json`.
export fn misstype_wasm_channel_data() ?[*:0]const u8 {
    learning_reply.clearRetainingCapacity();
    if (engine) |e| {
        const data = e.channel_learner.encode(gpa) catch return null;
        defer gpa.free(data);
        learning_reply.appendSlice(gpa, data) catch return null;
    }
    return learningReply();
}

export fn misstype_wasm_load_channel(data_ptr: [*]const u8, data_len: usize) i32 {
    const e = engine orelse return 0;
    e.installChannel(bytes(data_ptr, data_len)) catch return 0;
    return 1;
}

/// `[{"typed":"ㄥ","intended":"ㄣ","cost":c}]`, cheapest (most likely) first;
/// `exp(-cost)` is how often the slip happens.
export fn misstype_wasm_channel_pairs() ?[*:0]const u8 {
    learning_reply.clearRetainingCapacity();
    learning_reply.append(gpa, '[') catch return null;
    if (engine) |e| if (e.channel_learner.model()) |model| {
        const Pair = struct { typed: u8, intended: u8, cost: f64 };
        var pairs: std.ArrayList(Pair) = .empty;
        defer pairs.deinit(gpa);
        for (model.rows, 0..) |row, typed| for (row) |sub| {
            pairs.append(gpa, .{ .typed = @intCast(typed), .intended = sub.intended, .cost = sub.raw }) catch return null;
        };
        std.mem.sort(Pair, pairs.items, {}, struct {
            fn cheaper(_: void, a: Pair, b: Pair) bool {
                if (a.cost != b.cost) return a.cost < b.cost;
                return (@as(u16, a.typed) << 8 | a.intended) < (@as(u16, b.typed) << 8 | b.intended);
            }
        }.cheaper);
        for (pairs.items, 0..) |p, i| {
            if (i > 0) learning_reply.append(gpa, ',') catch return null;
            const typed = [1]u8{p.typed};
            const intended = [1]u8{p.intended};
            learning_reply.appendSlice(gpa, "{\"typed\":") catch return null;
            jsonString(&learning_reply, core.keyboard.symbol(p.typed) orelse &typed) catch return null;
            learning_reply.appendSlice(gpa, ",\"intended\":") catch return null;
            jsonString(&learning_reply, core.keyboard.symbol(p.intended) orelse &intended) catch return null;
            learning_reply.print(gpa, ",\"cost\":{d}}}", .{p.cost}) catch return null;
        }
    };
    learning_reply.append(gpa, ']') catch return null;
    return learningReply();
}

export fn misstype_wasm_clear_channel() void {
    const e = engine orelse return;
    e.clearChannel();
}
