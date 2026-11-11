//! C ABI over the Zig core: exactly the functions of
//! Sources/CMisstype/include/misstype.h (the retired Swift MisstypeCAPI had the
//! same semantics). Strings and views returned are malloc'ed (free with
//! misstype_string_free / misstype_view_free).
//!
//! english.tsv loads synchronously in misstype_engine_new; the dev-only
//! MISSTYPE_LEXICON / MISSTYPE_BIGRAM overrides do not exist
//! (MISSTYPE_WORD_PENALTY does).

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

pub const abi_version: i32 = 3;

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
    latin_toggled: i32 = 0,
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
    page_size: i32,
    segment_count: i32,
    segments_utf16: ?[*]i32,
    focus_start_utf16: i32,
    focus_end_utf16: i32,
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
    // Optional homophone word-bigram table; absent or malformed = decode as before.
    const homophone_path = try joinPath(dir, "homophone.bin");
    defer gpa.free(homophone_path);
    if (storage.readBytes(io(), gpa, homophone_path)) |bytes| {
        defer gpa.free(bytes);
        decoder.setHomophoneTable(bytes) catch {};
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
        .latin_toggled = @intFromBool(result.latin_toggled),
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
        .page_size = @intCast(v.page_size),
        .segment_count = @intCast(v.segments.len),
        .segments_utf16 = rangeArray(v.segments),
        .focus_start_utf16 = if (v.focus) |f| @intCast(f.start) else -1,
        .focus_end_utf16 = if (v.focus) |f| @intCast(f.end) else -1,
    };
    return out;
}

/// Ranges as flat start/end pairs (2 * count values).
fn rangeArray(ranges: []const core.candidate.Range) ?[*]i32 {
    const out = gpa.alloc(i32, @max(1, 2 * ranges.len)) catch @panic("out of memory");
    for (ranges, 0..) |r, i| {
        out[2 * i] = @intCast(r.start);
        out[2 * i + 1] = @intCast(r.end);
    }
    return out.ptr;
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
    if (v.segments_utf16) |segs| gpa.free(segs[0..@max(1, 2 * @as(usize, @intCast(@max(v.segment_count, 0))))]);
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

pub export fn misstype_key_from_evdev(code: i32, label: ?*?[*:0]const u8) callconv(.c) c_int {
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

pub export fn misstype_key_from_character(utf8: ?[*:0]const u8, label: ?*?[*:0]const u8, shifted: ?*i32) callconv(.c) c_int {
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

// MARK: - ABI v2

/// macOS virtual key codes (ANSI positions) -> US-ANSI labels.
fn macLabel(code: i32) ?u8 {
    return switch (code) {
        0 => 'a',
        1 => 's',
        2 => 'd',
        3 => 'f',
        4 => 'h',
        5 => 'g',
        6 => 'z',
        7 => 'x',
        8 => 'c',
        9 => 'v',
        11 => 'b',
        12 => 'q',
        13 => 'w',
        14 => 'e',
        15 => 'r',
        16 => 'y',
        17 => 't',
        18 => '1',
        19 => '2',
        20 => '3',
        21 => '4',
        22 => '6',
        23 => '5',
        24 => '=',
        25 => '9',
        26 => '7',
        27 => '-',
        28 => '8',
        29 => '0',
        30 => ']',
        31 => 'o',
        32 => 'u',
        33 => '[',
        34 => 'i',
        35 => 'p',
        37 => 'l',
        38 => 'j',
        39 => '\'',
        40 => 'k',
        41 => ';',
        42 => '\\',
        43 => ',',
        44 => '/',
        45 => 'n',
        46 => 'm',
        47 => '.',
        50 => '`',
        else => null,
    };
}

pub export fn misstype_key_from_mac(code: i32, label: ?*?[*:0]const u8) callconv(.c) c_int {
    if (macLabel(code)) |c| {
        if (label) |out| out.* = staticLabel(c);
        return kindToC(.character);
    }
    if (label) |out| out.* = null;
    const kind: KeyKind = switch (code) {
        49 => .space,
        36, 76 => .enter,
        48 => .tab,
        51 => .backspace,
        117 => .forward_delete,
        53 => .escape,
        123 => .left,
        124 => .right,
        125 => .down,
        126 => .up,
        116 => .page_up,
        121 => .page_down,
        56 => .shift_left,
        60 => .shift_right,
        55, 54, 57, 58, 61, 59, 62, 63, 114 => .modifier,
        else => .other,
    };
    return kindToC(kind);
}

export fn misstype_engine_set_key_bindings(engine_: ?*Engine, text: ?[*:0]const u8) callconv(.c) void {
    const engine = engine_ orelse return;
    engine.bindings = core.keybindings.Bindings.parse(span(text) orelse "");
}

export fn misstype_engine_learned_phrase_count(engine_: ?*const Engine) callconv(.c) i32 {
    const engine = engine_ orelse return 0;
    return @intCast(engine.user_lexicon.count());
}

export fn misstype_engine_reload_learned_phrases(engine_: ?*Engine) callconv(.c) void {
    const engine = engine_ orelse return;
    engine.loadUserLexicon();
}

export fn misstype_engine_save_learned_phrases(engine_: ?*Engine) callconv(.c) void {
    const engine = engine_ orelse return;
    engine.saveUserLexicon() catch {};
}

export fn misstype_engine_clear_learned_phrases(engine_: ?*Engine) callconv(.c) void {
    const engine = engine_ orelse return;
    engine.clearUserLexicon() catch {};
}

/// One "readings<TAB>text<TAB>count<TAB>updatedAt" row per learned phrase,
/// newest first. Positional session pins never reach the file, so every row
/// is a word the user picked on purpose.
export fn misstype_engine_learned_phrases(engine_: ?*const Engine) callconv(.c) ?[*:0]u8 {
    const engine = engine_ orelse return dupZ("");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const Row = struct { key: []const u8, text: []const u8, record: core.user_lexicon.Record };
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    var entries = engine.user_lexicon.entries.iterator();
    while (entries.next()) |entry| {
        var texts = entry.value_ptr.iterator();
        while (texts.next()) |t| rows.append(gpa, .{ .key = entry.key_ptr.*, .text = t.key_ptr.*, .record = t.value_ptr.* }) catch return dupZ("");
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn newer(_: void, a: Row, b: Row) bool {
            if (a.record.updated_at != b.record.updated_at) return a.record.updated_at > b.record.updated_at;
            return core.unicode.lessThan(a.text, b.text);
        }
    }.newer);
    for (rows.items) |row| {
        out.writer.print("{s}\t{s}\t{d}\t{d}\n", .{ row.key, row.text, row.record.count, row.record.updated_at }) catch return dupZ("");
    }
    return dupZ(out.written());
}

export fn misstype_engine_forget_learned_phrase(engine_: ?*Engine, readings: ?[*:0]const u8, text: ?[*:0]const u8) callconv(.c) void {
    const engine = engine_ orelse return;
    engine.forgetLearned(span(readings) orelse return, span(text) orelse return) catch {};
}

export fn misstype_engine_channel_pairs(engine_: ?*const Engine) callconv(.c) ?[*:0]u8 {
    const engine = engine_ orelse return dupZ("");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = channelPairs(arena.allocator(), &engine.channel_learner) catch return dupZ("");
    return dupZ(text);
}

const Pair = struct { typed: []const u8, intended: []const u8, cost: f64 };

/// ChannelLearner.learnedPairs: model pairs as symbols, cheapest first,
/// ties by typed+intended.
fn channelPairs(a: std.mem.Allocator, learner: *const core.channel.ChannelLearner) ![]const u8 {
    var pairs: std.ArrayList(Pair) = .empty;
    const model = learner.model() orelse return "";
    for (model.rows, 0..) |row, typed| for (row) |sub| {
        const t: u8 = @intCast(typed);
        try pairs.append(a, .{
            .typed = core.keyboard.symbol(t) orelse std.mem.span(staticLabel(t)),
            .intended = core.keyboard.symbol(sub.intended) orelse std.mem.span(staticLabel(sub.intended)),
            .cost = sub.raw,
        });
    };
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lt(_: void, x: Pair, y: Pair) bool {
            if (x.cost != y.cost) return x.cost < y.cost;
            // Swift compares the concatenated strings typed + intended.
            var bx: [16]u8 = undefined;
            var by: [16]u8 = undefined;
            const jx = std.fmt.bufPrint(&bx, "{s}{s}", .{ x.typed, x.intended }) catch return false;
            const jy = std.fmt.bufPrint(&by, "{s}{s}", .{ y.typed, y.intended }) catch return false;
            return std.mem.order(u8, jx, jy) == .lt;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    for (pairs.items) |p| {
        try out.print(a, "{s}\t{s}\t", .{ p.typed, p.intended });
        try core.user_dictionary.appendSwiftDouble(&out, a, p.cost);
        try out.append(a, '\n');
    }
    return out.items;
}

export fn misstype_engine_user_dictionary_text(engine_: ?*const Engine) callconv(.c) ?[*:0]u8 {
    const engine = engine_ orelse return dupZ("");
    const text = engine.user_dictionary.serialized(gpa) catch return dupZ("");
    defer gpa.free(text);
    return dupZ(text);
}

export fn misstype_user_dictionary_check(text: ?[*:0]const u8, added: ?*i32, hidden: ?*i32) callconv(.c) ?[*:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var problems: std.ArrayList(core.user_dictionary.Problem) = .empty;
    const dict = core.user_dictionary.UserDictionary.parse(a, span(text) orelse "", &problems) catch return dupZ("");
    if (added) |out| out.* = @intCast(dict.added.items.len);
    if (hidden) |out| out.* = @intCast(dict.excluded.items.len);
    var rows: std.ArrayList(u8) = .empty;
    for (problems.items) |p| rows.print(a, "{d}\t{s}\n", .{ p.line, p.message }) catch return dupZ("");
    return dupZ(rows.items);
}

export fn misstype_user_dictionary_import(text: ?[*:0]const u8, source: ?[*:0]const u8, added: ?*i32, duplicates: ?*i32, skipped: ?*i32) callconv(.c) ?[*:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const original = span(text) orelse "";
    const result = core.user_dictionary.importing(arena.allocator(), span(source) orelse "", original) catch return dupZ(original);
    if (added) |out| out.* = @intCast(result.added);
    if (duplicates) |out| out.* = @intCast(result.duplicates);
    if (skipped) |out| out.* = @intCast(result.skipped);
    return dupZ(result.text);
}

// MARK: - ABI v3: hosts without a filesystem
//
// Everything a host needs when it cannot hand the engine paths (the browser,
// sandboxed extensions): resources and learned state go in and out as bytes,
// keys arrive as DOM `KeyboardEvent.code`, the view is available as JSON,
// and results can be written through a pointer for FFIs that cannot receive
// structs by value. The WebAssembly module is this file compiled for
// wasm32-wasi (src/wasm.zig), so C and JavaScript hosts share one ABI.
// Byte arguments are (pointer, length) and need no terminating NUL.

fn bytesOf(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

export fn misstype_alloc(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(@max(1, size));
}

export fn misstype_free(ptr: ?*anyopaque) callconv(.c) void {
    std.c.free(ptr);
}

/// An engine over in-memory lexicons, with no files: learning, the user
/// dictionary and typing slips stay in memory until the host saves them
/// (`misstype_engine_learned_data` and friends).
export fn misstype_engine_new_from_data(lexicon: ?[*]const u8, lexicon_len: usize, toneless: ?[*]const u8, toneless_len: usize) callconv(.c) ?*Engine {
    if (lexicon_len == 0) return null;
    const decoder = core.Lexicon.create(gpa, &.{bytesOf(lexicon, lexicon_len)}, bytesOf(toneless, toneless_len)) catch return null;
    decoder.word_penalty = 0.5; // as misstype_engine_new
    const engine = Engine.create(gpa, io(), decoder) catch {
        decoder.destroy();
        return null;
    };
    engine.setUserDictionary(core.user_dictionary.UserDictionary.init(gpa), false) catch {
        engine.release();
        return null;
    };
    return engine;
}

/// english.tsv; replaces any loaded list. 1 on success.
export fn misstype_engine_load_english(engine_: ?*Engine, data: ?[*]const u8, len: usize) callconv(.c) i32 {
    const engine = engine_ orelse return 0;
    const lexicon = core.english.EnglishLexicon.create(gpa, bytesOf(data, len)) catch return 0;
    if (engine.english_lexicon) |old| old.destroy();
    engine.english_lexicon = lexicon;
    return 1;
}

/// homophone.bin (word-bigram table); 0 on a malformed table, which leaves
/// decoding as it was.
export fn misstype_engine_load_homophone(engine_: ?*Engine, data: ?[*]const u8, len: usize) callconv(.c) i32 {
    const engine = engine_ orelse return 0;
    engine.decoder.setHomophoneTable(bytesOf(data, len)) catch return 0;
    return 1;
}

/// Experimental sparse word model (`MSLM`, at most 8 MiB, one per engine),
/// mixed in at `weight` (0...1). 0 when refused; decoding is then unchanged.
export fn misstype_engine_load_word_model(engine_: ?*Engine, data: ?[*]const u8, len: usize, weight: f64) callconv(.c) i32 {
    const engine = engine_ orelse return 0;
    const model = bytesOf(data, len);
    if (engine.decoder.word_model != null or model.len > 8 * 1024 * 1024 or model.len < 4 or
        !std.mem.eql(u8, model[0..4], "MSLM") or !std.math.isFinite(weight) or weight < 0 or weight > 1) return 0;
    engine.decoder.setWordModel(model) catch return 0;
    engine.decoder.word_model_weight = weight;
    return 1;
}

/// One setting by name, for hosts that store settings as key/value pairs.
/// Booleans take 0/1. Returns 1 when the name is known.
///   autoShowCandidates returnConfirmsSelection shiftToggle userLearning
///   channelLearning mixedEnglish toneTolerance pageSize autoCommitSyllables
///   repairStrength (0 off, 1 light, 2 standard, 3 strong)
///   shiftTapLimitMs (longest Shift press that still toggles 中/英)
export fn misstype_engine_set_setting(engine_: ?*Engine, name_: ?[*:0]const u8, value: i32) callconv(.c) i32 {
    const engine = engine_ orelse return 0;
    const name = span(name_) orelse return 0;
    const s = &engine.settings;
    const on = value != 0;
    const Flag = enum { autoShowCandidates, returnConfirmsSelection, shiftToggle, userLearning, channelLearning, mixedEnglish, toneTolerance, pageSize, autoCommitSyllables, repairStrength, shiftTapLimitMs };
    switch (std.meta.stringToEnum(Flag, name) orelse return 0) {
        .autoShowCandidates => s.auto_show_candidates = on,
        .returnConfirmsSelection => s.return_confirms_selection = on,
        .shiftToggle => s.shift_toggle = on,
        .userLearning => s.user_learning = on,
        .channelLearning => s.channel_learning = on,
        .mixedEnglish => s.mixed_english = on,
        .toneTolerance => s.tone_tolerance = on,
        .pageSize => s.page_size = session_mod.clampPageSize(value),
        .autoCommitSyllables => s.auto_commit_syllables = @intCast(@max(0, value)),
        .repairStrength => {
            if (value < 0 or value > 3) return 0;
            s.repair_strength = @fromBackingInt(@intCast(value));
        },
        .shiftTapLimitMs => engine.shift_tap.tap_time_limit = @as(f64, @floatFromInt(@max(0, value))) / 1000,
    }
    return 1;
}

/// Changes whenever a phrase is learned or forgotten or a typing slip noted:
/// save `learned_data` / `channel_data` when it moves.
export fn misstype_engine_learning_revision(engine_: ?*const Engine) callconv(.c) i32 {
    const engine = engine_ orelse return 0;
    return @bitCast(engine.learning_revision);
}

/// The learned phrases as the desktop `user_lexicon.json`.
export fn misstype_engine_learned_data(engine_: ?*const Engine) callconv(.c) ?[*:0]u8 {
    const engine = engine_ orelse return dupZ("");
    const data = engine.user_lexicon.encode(gpa) catch return dupZ("");
    defer gpa.free(data);
    return dupZ(data);
}

/// Replaces the learned phrases; 0 (nothing changed) when `data` does not parse.
export fn misstype_engine_load_learned_data(engine_: ?*Engine, data: ?[*]const u8, len: usize) callconv(.c) i32 {
    const engine = engine_ orelse return 0;
    engine.installUserLexicon(bytesOf(data, len)) catch return 0;
    return 1;
}

/// The learned typing slips as the desktop `channel_model.json`.
export fn misstype_engine_channel_data(engine_: ?*const Engine) callconv(.c) ?[*:0]u8 {
    const engine = engine_ orelse return dupZ("");
    const data = engine.channel_learner.encode(gpa) catch return dupZ("");
    defer gpa.free(data);
    return dupZ(data);
}

export fn misstype_engine_load_channel_data(engine_: ?*Engine, data: ?[*]const u8, len: usize) callconv(.c) i32 {
    const engine = engine_ orelse return 0;
    engine.installChannel(bytesOf(data, len)) catch return 0;
    return 1;
}

/// Added plus hidden words; changes when a phrase is filed (Shift+←/→, Return).
export fn misstype_engine_user_dictionary_count(engine_: ?*const Engine) callconv(.c) i32 {
    const engine = engine_ orelse return 0;
    return @intCast(engine.user_dictionary.added.items.len + engine.user_dictionary.excluded.items.len);
}

/// Replaces the user dictionary with `text` (unparseable lines skipped).
/// Written to the dictionary path when the engine has one.
export fn misstype_engine_set_user_dictionary_text(engine_: ?*Engine, data: ?[*]const u8, len: usize) callconv(.c) i32 {
    const engine = engine_ orelse return 0;
    const dictionary = core.user_dictionary.UserDictionary.parse(gpa, bytesOf(data, len), null) catch return 0;
    engine.setUserDictionary(dictionary, true) catch return 0;
    return 1;
}

/// Switches 中/英 explicitly (a host button rather than the Shift tap).
/// Pending composition is committed first and returned, else NULL.
export fn misstype_session_set_english(session_: ?*Session, enabled: i32) callconv(.c) ?[*:0]u8 {
    const session = session_ orelse return null;
    const target = enabled != 0;
    if (session.engine.english == target) return null;
    const text = session.commit() catch null;
    session.engine.english = target;
    return if (text) |t| dupZ(t) else null;
}

/// misstype_session_handle writing the result through `out`; returns
/// `out->consumed`. For FFIs that cannot receive a struct by value.
export fn misstype_session_handle_into(session: ?*Session, event: ?*const CKeyEvent, out: ?*CKeyResult) callconv(.c) i32 {
    const result = misstype_session_handle(session, event);
    if (out) |o| o.* = result else misstype_string_free(result.commit);
    return result.consumed;
}

/// DOM `KeyboardEvent.code` -> key kind, with the US-ANSI label for
/// characters (static string). `text` (the typed character, may be NULL) is
/// the fallback for codes that are not US positions.
export fn misstype_key_from_dom_code(code_: ?[*:0]const u8, text_: ?[*:0]const u8, label: ?*?[*:0]const u8) callconv(.c) c_int {
    if (label) |out| out.* = null;
    const code = span(code_) orelse "";
    const named = [_]struct { []const u8, KeyKind }{
        .{ "Space", .space },          .{ "Enter", .enter },           .{ "NumpadEnter", .enter },
        .{ "Tab", .tab },              .{ "Backspace", .backspace },   .{ "Delete", .forward_delete },
        .{ "Escape", .escape },        .{ "ArrowLeft", .left },        .{ "ArrowRight", .right },
        .{ "ArrowUp", .up },           .{ "ArrowDown", .down },        .{ "PageUp", .page_up },
        .{ "PageDown", .page_down },   .{ "ShiftLeft", .shift_left },  .{ "ShiftRight", .shift_right },
        .{ "ControlLeft", .modifier }, .{ "ControlRight", .modifier }, .{ "AltLeft", .modifier },
        .{ "AltRight", .modifier },    .{ "MetaLeft", .modifier },     .{ "MetaRight", .modifier },
    };
    for (named) |n| if (std.mem.eql(u8, n[0], code)) return kindToC(n[1]);
    const punctuation = [_]struct { []const u8, u8 }{
        .{ "Minus", '-' },      .{ "Equal", '=' },     .{ "BracketLeft", '[' }, .{ "BracketRight", ']' },
        .{ "Backslash", '\\' }, .{ "Semicolon", ';' }, .{ "Quote", '\'' },      .{ "Backquote", '`' },
        .{ "Comma", ',' },      .{ "Period", '.' },    .{ "Slash", '/' },
    };
    var c: ?u8 = null;
    if (std.mem.startsWith(u8, code, "Key") and code.len == 4 and std.ascii.isAlphabetic(code[3])) {
        c = std.ascii.toLower(code[3]);
    } else if (std.mem.startsWith(u8, code, "Digit") and code.len == 6 and std.ascii.isDigit(code[5])) {
        c = code[5];
    } else for (punctuation) |p| {
        if (std.mem.eql(u8, p[0], code)) c = p[1];
    }
    if (c == null) if (span(text_)) |text| if (text.len == 1 and text[0] < 128 and std.ascii.isPrint(text[0]) and text[0] != ' ') {
        c = std.ascii.toLower(text[0]);
    };
    const ch = c orelse return kindToC(.other);
    if (label) |out| out.* = staticLabel(ch);
    return kindToC(.character);
}

/// The view as JSON (UTF-16 offsets, as browsers count):
/// {"preedit","caret","selected","showsCandidates","keysActive","pageSize",
///  "page","pageCount","pageSelected","candidates","pageCandidates",
///  "selectionKeys","segments":[[s,e]],"focus":[s,e]|null,
///  "mark":{"range","reading","action"}|null,"english","latinActive"}
export fn misstype_session_view_json(session_: ?*Session) callconv(.c) ?[*:0]u8 {
    const session = session_ orelse return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    writeViewJson(&out, session) catch return null;
    return dupZ(out.items);
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

fn writeViewJson(out: *std.ArrayList(u8), s: *Session) !void {
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
    try out.print(gpa, ",\"english\":{},\"latinActive\":{}}}", .{ s.engine.english, s.latinActive() });
}

// The JavaScript binding (packages/misstype-wasm) writes and reads these
// structs at fixed wasm32 offsets; fail the build rather than drift.
comptime {
    if (@import("builtin").cpu.arch == .wasm32) {
        std.debug.assert(@sizeOf(CKeyEvent) == 32 and @offsetOf(CKeyEvent, "label") == 4 and
            @offsetOf(CKeyEvent, "text") == 8 and @offsetOf(CKeyEvent, "modifiers") == 12 and
            @offsetOf(CKeyEvent, "is_release") == 16 and @offsetOf(CKeyEvent, "native_code") == 20 and
            @offsetOf(CKeyEvent, "timestamp") == 24);
        std.debug.assert(@sizeOf(CKeyResult) == 20 and @offsetOf(CKeyResult, "commit") == 4 and
            @offsetOf(CKeyResult, "beep") == 8 and @offsetOf(CKeyResult, "mode_changed") == 12 and
            @offsetOf(CKeyResult, "latin_toggled") == 16);
    }
}
