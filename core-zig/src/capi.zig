//! C ABI over the Zig core: exactly the functions of
//! Sources/CMisstype/include/misstype.h, with the Swift MisstypeCAPI's
//! semantics. Strings and views returned are malloc'ed (free with
//! misstype_string_free / misstype_view_free).
//!
//! Differences from Swift: english.tsv loads synchronously in
//! misstype_engine_new; the dev-only MISSTYPE_LEXICON / MISSTYPE_BIGRAM
//! overrides are not supported (MISSTYPE_WORD_PENALTY is).

const std = @import("std");
const core = @import("root.zig");
const session_mod = core.session;
const storage = core.storage;
const Engine = session_mod.Engine;
const Session = session_mod.Session;
const KeyKind = session_mod.KeyKind;

const gpa = std.heap.c_allocator;

var io_instance: std.Io.Threaded = .init_single_threaded;

fn io() std.Io {
    return io_instance.io();
}

pub const abi_version: i32 = 1;

// MARK: - C types (layout of misstype.h)

const CKeyEvent = extern struct {
    kind: c_int,
    label: ?[*:0]const u8,
    text: ?[*:0]const u8,
    modifiers: u32,
    is_release: i32,
    native_code: i32,
    timestamp: f64,
};

const CKeyResult = extern struct {
    consumed: i32 = 0,
    commit: ?[*:0]u8 = null,
    beep: i32 = 0,
    mode_changed: i32 = 0,
};

const CView = extern struct {
    preedit: [*:0]u8,
    caret_bytes: i32,
    caret_utf16: i32,
    candidates: ?[*][*:0]u8,
    candidate_count: i32,
    selected: i32,
    selection_keys: ?[*][*:0]u8,
    selection_key_count: i32,
    keys_active: i32,
    shows_candidates: i32,
    mark_action: i32,
    mark_start_bytes: i32,
    mark_end_bytes: i32,
    mark_start_utf16: i32,
    mark_end_utf16: i32,
    mark_text: [*:0]u8,
    mark_reading: [*:0]u8,
};

const CSettings = extern struct {
    fuzzy_repair: i32,
    tone_tolerance: i32,
    user_learning: i32,
    shift_toggle: i32,
    candidate_keys: ?[*:0]const u8,
    auto_show_candidates: i32,
    return_confirms_selection: i32,
    mixed_english: i32,
    auto_commit_syllables: i32,
    page_size: i32,
    cursor_candidates: i32,
};

// Key kinds (misstype_key_kind).
const kinds = [_]KeyKind{
    .character, .space, .enter,      .tab,         .backspace, .forward_delete, .escape,  .left,      .right,
    .up,        .down,  .shift_left, .shift_right, .modifier,  .other,          .page_up, .page_down,
};

fn kindFromC(value: c_int) KeyKind {
    return if (value >= 0 and value < kinds.len) kinds[@intCast(value)] else .other;
}

fn kindToC(kind: KeyKind) c_int {
    for (kinds, 0..) |k, i| if (k == kind) return @intCast(i);
    return 14;
}

fn dupZ(text: []const u8) [*:0]u8 {
    const out = gpa.allocSentinel(u8, text.len, 0) catch @panic("out of memory");
    @memcpy(out, text);
    return out.ptr;
}

fn span(ptr: ?[*:0]const u8) ?[]const u8 {
    return if (ptr) |p| std.mem.span(p) else null;
}

// MARK: - Engine

export fn misstype_abi_version() callconv(.c) i32 {
    return abi_version;
}

export fn misstype_settings_default() callconv(.c) CSettings {
    return .{
        .fuzzy_repair = 1,
        .tone_tolerance = 1,
        .user_learning = 1,
        .shift_toggle = 1,
        .candidate_keys = null,
        .auto_show_candidates = 1,
        .return_confirms_selection = 0,
        .mixed_english = 1,
        .auto_commit_syllables = 24,
        .page_size = session_mod.default_page_size,
        .cursor_candidates = 0,
    };
}

fn joinPath(dir: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
}

fn loadDecoder(dir: []const u8) !?*core.Lexicon {
    const lexicon_path = try joinPath(dir, "lexicon.tsv");
    defer gpa.free(lexicon_path);
    const tsv = storage.read(io(), gpa, lexicon_path) orelse return null;
    defer gpa.free(tsv);
    const supplement_path = try joinPath(dir, "local_phrases.tsv");
    defer gpa.free(supplement_path);
    const supplement = storage.read(io(), gpa, supplement_path);
    defer if (supplement) |s| gpa.free(s);
    const toneless_path = try joinPath(dir, "toneless.tsv");
    defer gpa.free(toneless_path);
    const toneless = storage.read(io(), gpa, toneless_path);
    defer if (toneless) |t| gpa.free(t);
    const decoder = try core.Lexicon.create(gpa, &.{ tsv, supplement orelse "" }, toneless orelse "");
    decoder.word_penalty = 0.5;
    if (std.c.getenv("MISSTYPE_WORD_PENALTY")) |value| {
        decoder.word_penalty = std.fmt.parseFloat(f64, std.mem.span(value)) catch 0.5;
    }
    return decoder;
}

export fn misstype_engine_new(resource_dir: ?[*:0]const u8, user_lexicon_path: ?[*:0]const u8) callconv(.c) ?*Engine {
    const dir = span(resource_dir) orelse return null;
    return engineNew(dir, user_lexicon_path) catch null;
}

fn engineNew(dir: []const u8, user_lexicon_path: ?[*:0]const u8) !?*Engine {
    const decoder = (try loadDecoder(dir)) orelse return null;
    const engine = Engine.create(gpa, io(), decoder) catch |err| {
        decoder.destroy();
        return err;
    };
    errdefer engine.release();
    const english_path = try joinPath(dir, "english.tsv");
    defer gpa.free(english_path);
    if (storage.read(io(), gpa, english_path)) |tsv| {
        defer gpa.free(tsv);
        engine.english_lexicon = try core.english.EnglishLexicon.create(gpa, tsv);
    }
    if (span(user_lexicon_path)) |path| {
        if (path.len > 0) try engine.setPath(&engine.user_lexicon_path, path);
    } else {
        const path = try storage.defaultPath(gpa, "user_phrases.json");
        defer gpa.free(path);
        try engine.setPath(&engine.user_lexicon_path, path);
    }
    engine.loadUserLexicon();
    try engine.setUserDictionary(core.user_dictionary.UserDictionary.init(gpa), false);
    return engine;
}

export fn misstype_engine_free(engine: ?*Engine) callconv(.c) void {
    if (engine) |e| e.release();
}

export fn misstype_engine_set_settings(engine_: ?*Engine, settings_: ?*const CSettings) callconv(.c) void {
    const engine = engine_ orelse return;
    const c = settings_ orelse return;
    const previous = engine.settings;
    var s: session_mod.Settings = .{};
    s.repair_strength = if (c.fuzzy_repair == 0) .off else if (previous.fuzzyRepair()) previous.repair_strength else .standard;
    s.tone_tolerance = c.tone_tolerance != 0;
    s.user_learning = c.user_learning != 0;
    s.shift_toggle = c.shift_toggle != 0;
    s.auto_commit_syllables = @intCast(@max(0, c.auto_commit_syllables));
    s.auto_show_candidates = c.auto_show_candidates != 0;
    s.return_confirms_selection = c.return_confirms_selection != 0;
    s.mixed_english = c.mixed_english != 0;
    s.page_size = session_mod.clampPageSize(c.page_size);
    s.cursor_candidates = switch (c.cursor_candidates) {
        1 => .ending_at,
        2 => .beginning_at,
        else => .covering,
    };
    s.channel_learning = previous.channel_learning;
    s.candidate_keys = previous.candidate_keys;
    engine.settings = s;
    engine.setCandidateKeys(span(c.candidate_keys) orelse session_mod.default_keys) catch {};
}

export fn misstype_engine_set_repair_strength(engine_: ?*Engine, level: i32) callconv(.c) void {
    const engine = engine_ orelse return;
    if (level < 0 or level > 3) return;
    engine.settings.repair_strength = @fromBackingInt(@intCast(level));
}

export fn misstype_engine_set_channel_path(engine_: ?*Engine, path: ?[*:0]const u8) callconv(.c) void {
    const engine = engine_ orelse return;
    setDataPath(engine, &engine.channel_path, path, "channel_model.json") catch return;
    engine.loadChannel();
}

fn setDataPath(engine: *Engine, slot: *?[]u8, path: ?[*:0]const u8, default_name: []const u8) !void {
    if (span(path)) |p| {
        try engine.setPath(slot, if (p.len == 0) null else p);
    } else {
        const p = try storage.defaultPath(gpa, default_name);
        defer gpa.free(p);
        try engine.setPath(slot, p);
    }
}

export fn misstype_engine_set_channel_learning(engine_: ?*Engine, enabled: i32) callconv(.c) void {
    const engine = engine_ orelse return;
    engine.settings.channel_learning = enabled != 0;
}

export fn misstype_engine_clear_channel(engine_: ?*Engine) callconv(.c) void {
    const engine = engine_ orelse return;
    engine.clearChannel();
}

export fn misstype_engine_channel_pair_count(engine_: ?*const Engine) callconv(.c) i32 {
    const engine = engine_ orelse return 0;
    return @intCast(engine.channel_learner.pairCount());
}

export fn misstype_engine_set_user_dictionary_path(engine_: ?*Engine, path: ?[*:0]const u8) callconv(.c) void {
    const engine = engine_ orelse return;
    setDataPath(engine, &engine.user_dictionary_path, path, "user_dictionary.tsv") catch return;
    const dictionary = engine.loadUserDictionary() catch return;
    engine.setUserDictionary(dictionary, false) catch {};
}

export fn misstype_engine_is_english(engine_: ?*const Engine) callconv(.c) i32 {
    const engine = engine_ orelse return 0;
    return @intFromBool(engine.english);
}

// MARK: - Session

export fn misstype_session_new(engine_: ?*Engine) callconv(.c) ?*Session {
    const engine = engine_ orelse return null;
    return Session.create(engine) catch null;
}

export fn misstype_session_free(session: ?*Session) callconv(.c) void {
    if (session) |s| s.destroy();
}

export fn misstype_session_handle(session_: ?*Session, event_: ?*const CKeyEvent) callconv(.c) CKeyResult {
    const session = session_ orelse return .{};
    const c = event_ orelse return .{};
    var kind = kindFromC(c.kind);
    var label: []const u8 = "";
    if (kind == .character) {
        if (span(c.label)) |l| label = l else kind = .other;
    }
    const result = session.handle(.{
        .kind = kind,
        .label = label,
        .text = span(c.text),
        .mods = c.modifiers,
        .release = c.is_release != 0,
        .timestamp = if (c.timestamp >= 0) c.timestamp else null,
    }) catch return .{ .consumed = 1 };
    return .{
        .consumed = @intFromBool(result.consumed),
        .commit = if (result.commit) |text| dupZ(text) else null,
        .beep = @intFromBool(result.beep),
        .mode_changed = @intFromBool(result.mode_changed),
    };
}

export fn misstype_session_commit(session_: ?*Session) callconv(.c) ?[*:0]u8 {
    const session = session_ orelse return null;
    const text = (session.commit() catch return null) orelse return null;
    return dupZ(text);
}

export fn misstype_session_pick(session_: ?*Session, index: i32) callconv(.c) void {
    const session = session_ orelse return;
    if (index < 0) return;
    session.pick(@intCast(index)) catch {};
}

export fn misstype_session_reset_modifiers(session_: ?*Session) callconv(.c) void {
    const session = session_ orelse return;
    session.resetModifierState();
}

export fn misstype_session_raw_phonetic(session_: ?*Session) callconv(.c) ?[*:0]u8 {
    const session = session_ orelse return null;
    return dupZ(session.rawPhonetic() catch return null);
}

export fn misstype_session_latin_active(session_: ?*Session) callconv(.c) i32 {
    const session = session_ orelse return 0;
    return @intFromBool(session.latinActive());
}

fn stringArray(items: []const []const u8) ?[*][*:0]u8 {
    const out = gpa.alloc([*:0]u8, @max(items.len, 1)) catch @panic("out of memory");
    for (items, 0..) |item, i| out[i] = dupZ(item);
    return out.ptr;
}

export fn misstype_session_view(session_: ?*Session) callconv(.c) ?*CView {
    const session = session_ orelse return null;
    const v = session.view() catch return null;
    const out = gpa.create(CView) catch return null;
    const mark = v.mark;
    out.* = .{
        .preedit = dupZ(v.preedit),
        .caret_bytes = @intCast(core.unicode.byteOffset(v.preedit, v.caret)),
        .caret_utf16 = @intCast(v.caret),
        .candidates = stringArray(v.candidates),
        .candidate_count = @intCast(v.candidates.len),
        .selected = @intCast(v.selected),
        .selection_keys = stringArray(v.selection_keys),
        .selection_key_count = @intCast(v.selection_keys.len),
        .keys_active = @intFromBool(v.keys_active),
        .shows_candidates = @intFromBool(v.shows_candidates),
        .mark_action = if (mark) |m| @backingInt(m.action) else 0,
        .mark_start_bytes = if (mark) |m| @intCast(core.unicode.byteOffset(v.preedit, m.range.start)) else -1,
        .mark_end_bytes = if (mark) |m| @intCast(core.unicode.byteOffset(v.preedit, m.range.end)) else -1,
        .mark_start_utf16 = if (mark) |m| @intCast(m.range.start) else -1,
        .mark_end_utf16 = if (mark) |m| @intCast(m.range.end) else -1,
        .mark_text = dupZ(if (mark) |m| m.text else ""),
        .mark_reading = dupZ(if (mark) |m| m.reading else ""),
    };
    return out;
}

fn freeArray(items: ?[*][*:0]u8, count: i32) void {
    const list = items orelse return;
    const n: usize = @intCast(@max(count, 0));
    for (list[0..n]) |s| gpa.free(std.mem.span(s));
    gpa.free(list[0..@max(n, 1)]);
}

export fn misstype_view_free(view: ?*CView) callconv(.c) void {
    const v = view orelse return;
    gpa.free(std.mem.span(v.preedit));
    gpa.free(std.mem.span(v.mark_text));
    gpa.free(std.mem.span(v.mark_reading));
    freeArray(v.candidates, v.candidate_count);
    freeArray(v.selection_keys, v.selection_key_count);
    gpa.destroy(v);
}

export fn misstype_string_free(string: ?[*:0]u8) callconv(.c) void {
    if (string) |s| gpa.free(std.mem.span(s));
}

// MARK: - Keymap

/// Linux evdev codes -> US-ANSI labels (static strings).
fn evdevLabel(code: i32) ?[*:0]const u8 {
    return switch (code) {
        2 => "1",
        3 => "2",
        4 => "3",
        5 => "4",
        6 => "5",
        7 => "6",
        8 => "7",
        9 => "8",
        10 => "9",
        11 => "0",
        12 => "-",
        13 => "=",
        16 => "q",
        17 => "w",
        18 => "e",
        19 => "r",
        20 => "t",
        21 => "y",
        22 => "u",
        23 => "i",
        24 => "o",
        25 => "p",
        26 => "[",
        27 => "]",
        30 => "a",
        31 => "s",
        32 => "d",
        33 => "f",
        34 => "g",
        35 => "h",
        36 => "j",
        37 => "k",
        38 => "l",
        39 => ";",
        40 => "'",
        41 => "`",
        44 => "z",
        45 => "x",
        46 => "c",
        47 => "v",
        48 => "b",
        49 => "n",
        50 => "m",
        51 => ",",
        52 => ".",
        53 => "/",
        43 => "\\",
        else => null,
    };
}

export fn misstype_key_from_evdev(code: i32, label: ?*?[*:0]const u8) callconv(.c) c_int {
    if (evdevLabel(code)) |l| {
        if (label) |out| out.* = l;
        return kindToC(.character);
    }
    if (label) |out| out.* = null;
    const kind: KeyKind = switch (code) {
        57 => .space,
        28, 96 => .enter,
        15 => .tab,
        14 => .backspace,
        111 => .forward_delete,
        1 => .escape,
        105 => .left,
        106 => .right,
        103 => .up,
        104 => .page_up,
        109 => .page_down,
        108 => .down,
        42 => .shift_left,
        54 => .shift_right,
        29, 97, 56, 100, 125, 126, 58 => .modifier,
        else => .other,
    };
    return kindToC(kind);
}

const unshifted_labels = "abcdefghijklmnopqrstuvwxyz1234567890-=[];'`\\,./";
const shifted_glyphs = "!@#$%^&*()_+{}:\"~|<>?";
const shifted_labels = "1234567890-=[];'`\\,./";

/// Static label for an ASCII key character.
fn staticLabel(c: u8) [*:0]const u8 {
    const table = comptime blk: {
        var t: [128][2:0]u8 = undefined;
        for (0..128) |i| t[i] = .{ @intCast(i), 0 };
        break :blk t;
    };
    return &table[c];
}

export fn misstype_key_from_character(utf8: ?[*:0]const u8, label: ?*?[*:0]const u8, shifted: ?*i32) callconv(.c) c_int {
    const text = span(utf8) orelse return kindToC(.other);
    if (text.len != 1) return kindToC(.other);
    const c = text[0];
    if (c == ' ') {
        if (label) |out| out.* = null;
        if (shifted) |out| out.* = 0;
        return kindToC(.space);
    }
    if (std.mem.indexOfScalar(u8, unshifted_labels, c) != null) {
        if (label) |out| out.* = staticLabel(c);
        if (shifted) |out| out.* = 0;
        return kindToC(.character);
    }
    if (std.ascii.isUpper(c)) {
        if (label) |out| out.* = staticLabel(std.ascii.toLower(c));
        if (shifted) |out| out.* = 1;
        return kindToC(.character);
    }
    if (std.mem.indexOfScalar(u8, shifted_glyphs, c)) |i| {
        if (label) |out| out.* = staticLabel(shifted_labels[i]);
        if (shifted) |out| out.* = 1;
        return kindToC(.character);
    }
    return kindToC(.other);
}
