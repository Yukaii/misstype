//! Every editing rule of the IME, platform-free (port of InputSession.swift,
//! InputEngine.swift, LivePreview.swift, CursorSelection.swift and the
//! default KeyBindings). Adapters feed KeyEvents, apply KeyResults and draw
//! `view`; they hold no composition state of their own.
//!
//! Memory: decode results live in one of two arenas that alternate per
//! refresh, so the previous candidates stay readable while the next ones
//! are built. Results handed to the host live until the next call.
//!
//! Not ported: the diagnostic log and user key bindings (the C ABI only
//! exposes the defaults).

const std = @import("std");
const keyboard = @import("keyboard.zig");
const unicode = @import("unicode.zig");
const punctuation = @import("punctuation.zig");
const candidate_mod = @import("candidate.zig");
const composition_mod = @import("composition.zig");
const lexicon_mod = @import("lexicon.zig");
const user_lexicon = @import("user_lexicon.zig");
const user_dictionary = @import("user_dictionary.zig");
const channel_mod = @import("channel.zig");
const english_mod = @import("english.zig");
const layout_mod = @import("layout.zig");
const storage = @import("storage.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Candidate = candidate_mod.Candidate;
const CursorOption = candidate_mod.CursorOption;
const Range = candidate_mod.Range;
const Span = candidate_mod.Span;
const Composition = composition_mod.Composition;
const Key = composition_mod.Key;
const Syllable = keyboard.Syllable;
const Lexicon = lexicon_mod.Lexicon;
const UserLexicon = user_lexicon.UserLexicon;
const UserDictionary = user_dictionary.UserDictionary;
const Layout = layout_mod.Layout;

// MARK: - Key events

pub const KeyKind = enum(u8) {
    character,
    space,
    enter,
    tab,
    backspace,
    forward_delete,
    escape,
    left,
    right,
    up,
    down,
    page_up,
    page_down,
    shift_left,
    shift_right,
    modifier,
    other,
};

pub const mod_shift: u32 = 1 << 0;
pub const mod_control: u32 = 1 << 1;
pub const mod_option: u32 = 1 << 2;
pub const mod_command: u32 = 1 << 3;
pub const mod_caps_lock: u32 = 1 << 4;

pub const KeyEvent = struct {
    kind: KeyKind,
    /// US-ANSI unshifted label (`.character` only).
    label: []const u8 = "",
    /// Text the key types in the user's layout, null if none.
    text: ?[]const u8 = null,
    /// Modifier state AFTER this event.
    mods: u32 = 0,
    /// Key-up or modifier-only transition.
    release: bool = false,
    /// Seconds on a monotonic clock; null = now.
    timestamp: ?f64 = null,

    fn isChar(self: KeyEvent, label: []const u8) bool {
        return self.kind == .character and std.mem.eql(u8, self.label, label);
    }

    fn shiftSide(self: KeyEvent) ?u1 {
        return switch (self.kind) {
            .shift_left => 0,
            .shift_right => 1,
            else => null,
        };
    }

    /// Zhuyin keyboard label (symbol, tone, space = first tone), else null.
    fn zhuyinLabel(self: KeyEvent) ?u8 {
        if (self.kind == .space) return ' ';
        if (self.kind != .character) return null;
        const k = keyboard.single(self.label) orelse return null;
        return if (keyboard.isSymbol(k) or keyboard.isTone(k)) k else null;
    }

    fn characterLabel(self: KeyEvent) ?[]const u8 {
        return if (self.kind == .character) self.label else null;
    }

    /// Label of a letter key; labels are ASCII.
    fn letterLabel(self: KeyEvent) ?u8 {
        const k = keyboard.single(self.characterLabel() orelse return null) orelse return null;
        return if (std.ascii.isAlphabetic(k)) k else null;
    }

    fn digitLabel(self: KeyEvent) ?u8 {
        const k = keyboard.single(self.characterLabel() orelse return null) orelse return null;
        return if (std.ascii.isDigit(k)) k else null;
    }
};

pub const KeyResult = struct {
    consumed: bool,
    commit: ?[]const u8 = null,
    beep: bool = false,
    mode_changed: bool = false,
    latin_toggled: bool = false,

    const handled: KeyResult = .{ .consumed = true };
    const beeped: KeyResult = .{ .consumed = true, .beep = true };
};

/// Default bindings: Tab / Shift+Tab are next / previous page (their
/// canonical events are PageDown / PageUp); every other default chord is
/// its own canonical event.
fn resolveBinding(event: KeyEvent) KeyEvent {
    if (event.release or event.kind != .tab) return event;
    const chord = event.mods & (mod_control | mod_option | mod_shift | mod_command);
    if (chord != 0 and chord != mod_shift) return event;
    return .{
        .kind = if (chord == mod_shift) .page_up else .page_down,
        .mods = event.mods & mod_caps_lock,
        .timestamp = event.timestamp,
    };
}

/// Lone-Shift-tap detection for the 中/英 toggle.
pub const ShiftTapTracker = struct {
    tap_time_limit: f64 = 0.2,
    retrigger_guard: f64 = 0.05,
    down: bool = false,
    down_time: ?f64 = null,
    down_side: ?u1 = null,
    last_trigger: ?f64 = null,

    pub fn feed(self: *ShiftTapTracker, shift: ?u1, shift_held: bool, real_key_down: bool, other_mods: bool, now: f64) bool {
        const is_shift = shift != null;
        if (real_key_down and !is_shift) {
            self.clear();
            return false;
        }
        if (other_mods) {
            self.clear();
            return false;
        }
        if (!self.down and shift_held and is_shift) {
            if (self.last_trigger) |last| if (now - last < self.retrigger_guard) return false;
            self.down = true;
            self.down_time = now;
            self.down_side = shift;
            return false;
        }
        if (self.down and !shift_held and is_shift) {
            defer self.clear();
            if (self.down_side != shift) return false;
            if (now - (self.down_time orelse now) > self.tap_time_limit) return false;
            if (self.last_trigger) |last| if (now - last < self.retrigger_guard) return false;
            self.last_trigger = now;
            return true;
        }
        return false;
    }

    fn clear(self: *ShiftTapTracker) void {
        self.down = false;
        self.down_time = null;
        self.down_side = null;
    }

    pub fn reset(self: *ShiftTapTracker) void {
        self.clear();
    }
};

// MARK: - Settings

pub const CursorCandidates = enum(u8) {
    covering,
    ending_at,
    beginning_at,

    pub fn lists(self: CursorCandidates, span: Range, cursor: usize) bool {
        return switch (self) {
            .covering => span.contains(cursor),
            .ending_at => span.end == cursor + 1,
            .beginning_at => span.start == cursor,
        };
    }
};

pub const default_keys = "asdfghjkl;";

pub fn sanitizeKeys(a: Allocator, input: []const u8, page_size: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input) |byte| {
        const key = std.ascii.toLower(byte);
        if ((!keyboard.isSymbol(key) and !keyboard.isTone(key)) or key == ' ' or std.mem.indexOfScalar(u8, out.items, key) != null) continue;
        if (out.items.len == page_size) break;
        try out.append(a, key);
    }
    return if (out.items.len == 0) try a.dupe(u8, default_keys[0..@min(default_keys.len, page_size)]) else out.items;
}
pub const default_page_size = 8;

pub fn clampPageSize(size: i64) usize {
    return @intCast(@min(@max(size, 4), 10));
}

pub const Settings = struct {
    repair_strength: channel_mod.RepairStrength = .standard,
    tone_tolerance: bool = true,
    candidate_keys: []const u8 = default_keys,
    user_learning: bool = true,
    shift_toggle: bool = true,
    auto_commit_syllables: usize = 24,
    auto_show_candidates: bool = true,
    return_confirms_selection: bool = false,
    mixed_english: bool = true,
    page_size: usize = default_page_size,
    cursor_candidates: CursorCandidates = .covering,
    channel_learning: bool = false,

    pub fn fuzzyRepair(self: Settings) bool {
        return self.repair_strength != .off;
    }
};

/// Selection key labels: the first `page_size` characters of `keys`.
fn selectionLabels(arena: Allocator, keys: []const u8, page_size: usize) ![][]const u8 {
    const chars = try unicode.characters(arena, keys);
    return chars[0..@min(chars.len, page_size)];
}

fn selectionSlot(arena: Allocator, label: []const u8, keys: []const u8, page_size: usize) !?usize {
    for (try selectionLabels(arena, keys, page_size), 0..) |l, i| {
        if (std.mem.eql(u8, l, label)) return i;
    }
    return null;
}

fn pageDirection(label: []const u8) ?bool {
    if (std.mem.eql(u8, label, "=")) return true;
    if (std.mem.eql(u8, label, "-")) return false;
    return null;
}

// MARK: - Engine

/// Process-wide state shared by every session. Not thread-safe.
pub const Engine = struct {
    gpa: Allocator,
    io: Io,
    decoder: *Lexicon,
    settings: Settings = .{},
    user_lexicon: UserLexicon,
    user_lexicon_path: ?[]u8 = null,
    channel_learner: channel_mod.ChannelLearner,
    channel_path: ?[]u8 = null,
    english_lexicon: ?*english_mod.EnglishLexicon = null,
    user_dictionary: UserDictionary,
    user_dictionary_path: ?[]u8 = null,
    user_dictionary_stamp: ?i96 = null,
    /// 中/英 mode: global, one keyboard for all clients.
    english: bool = false,
    shift_tap: ShiftTapTracker = .{},
    /// Live sessions plus the host's handle.
    refs: usize = 1,
    /// Owned copy of the selection keys setting.
    keys_storage: ?[]u8 = null,

    pub fn create(gpa: Allocator, io: Io, decoder: *Lexicon) !*Engine {
        const self = try gpa.create(Engine);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .decoder = decoder,
            .user_lexicon = .init(gpa),
            .channel_learner = .init(gpa),
            .user_dictionary = .init(gpa),
        };
        return self;
    }

    pub fn release(self: *Engine) void {
        self.refs -= 1;
        if (self.refs > 0) return;
        const gpa = self.gpa;
        self.decoder.destroy();
        if (self.english_lexicon) |e| e.destroy();
        self.user_lexicon.deinit();
        self.channel_learner.deinit();
        self.user_dictionary.deinit();
        for ([_]?[]u8{ self.user_lexicon_path, self.channel_path, self.user_dictionary_path, self.keys_storage }) |p| if (p) |s| gpa.free(s);
        gpa.destroy(self);
    }

    pub fn setPath(self: *Engine, slot: *?[]u8, path: ?[]const u8) !void {
        if (slot.*) |old| self.gpa.free(old);
        slot.* = if (path) |p| try self.gpa.dupe(u8, p) else null;
    }

    pub fn setCandidateKeys(self: *Engine, keys: []const u8) !void {
        const copy = try self.gpa.dupe(u8, keys);
        if (self.keys_storage) |old| self.gpa.free(old);
        self.keys_storage = copy;
        self.settings.candidate_keys = copy;
    }

    pub fn loadUserLexicon(self: *Engine) void {
        self.user_lexicon.deinit();
        self.user_lexicon = .init(self.gpa);
        const path = self.user_lexicon_path orelse return;
        const data = storage.read(self.io, self.gpa, path) orelse return;
        defer self.gpa.free(data);
        self.user_lexicon = UserLexicon.decode(self.gpa, data) catch UserLexicon.init(self.gpa);
    }

    pub fn loadChannel(self: *Engine) void {
        self.channel_learner.deinit();
        self.channel_learner = .init(self.gpa);
        const path = self.channel_path orelse return;
        const data = storage.read(self.io, self.gpa, path) orelse return;
        defer self.gpa.free(data);
        self.channel_learner = channel_mod.ChannelLearner.decode(self.gpa, data) catch channel_mod.ChannelLearner.init(self.gpa);
    }

    /// Installs `dictionary` (taking ownership) into the decoder; when
    /// `persist`, writes it to `user_dictionary_path`.
    pub fn setUserDictionary(self: *Engine, dictionary: UserDictionary, persist: bool) !void {
        self.user_dictionary.deinit();
        self.user_dictionary = dictionary;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const words = try dictionary.words(arena.allocator());
        try self.decoder.applyUserDictionary(words.added, words.excluded);
        if (persist) if (self.user_dictionary_path) |path| {
            const text = try dictionary.serialized(arena.allocator());
            _ = storage.writeAtomic(self.io, arena.allocator(), path, text);
        };
        self.user_dictionary_stamp = if (self.user_dictionary_path) |p| storage.mtime(self.io, p) else null;
    }

    pub fn loadUserDictionary(self: *Engine) !UserDictionary {
        const path = self.user_dictionary_path orelse return UserDictionary.init(self.gpa);
        const data = storage.read(self.io, self.gpa, path) orelse return UserDictionary.init(self.gpa);
        defer self.gpa.free(data);
        return UserDictionary.parse(self.gpa, data, null);
    }

    /// Picks up edits made outside this process: one stat per composition.
    pub fn reloadUserDictionaryIfChanged(self: *Engine) !void {
        const path = self.user_dictionary_path orelse return;
        if (storage.mtime(self.io, path) == self.user_dictionary_stamp) return;
        try self.setUserDictionary(try self.loadUserDictionary(), false);
    }

    fn activeUserLexicon(self: *const Engine, settings: Settings) ?*const UserLexicon {
        return if (settings.user_learning) &self.user_lexicon else null;
    }

    fn activeChannel(self: *const Engine, settings: Settings) ?*const channel_mod.ChannelModel {
        return if (settings.user_learning and settings.channel_learning) self.channel_learner.model() else null;
    }

    pub fn clearChannel(self: *Engine) void {
        self.channel_learner.deinit();
        self.channel_learner = .init(self.gpa);
        self.saveChannel();
    }

    fn saveChannel(self: *Engine) void {
        const path = self.channel_path orelse return;
        const data = self.channel_learner.encode(self.gpa) catch return;
        defer self.gpa.free(data);
        _ = storage.writeAtomic(self.io, self.gpa, path, data);
    }

    fn observeChannel(self: *Engine, evidence: *const channel_mod.Evidence) !void {
        if (evidence.isEmpty()) return;
        try self.channel_learner.observe(evidence);
        self.saveChannel();
    }

    fn learn(self: *Engine, words: []const user_lexicon.LearnedWord) !void {
        if (words.len == 0) return;
        const now = storage.nowUnix(self.io);
        for (words) |w| try self.user_lexicon.record(w.key, w.text, now);
        const path = self.user_lexicon_path orelse return;
        const data = try self.user_lexicon.encode(self.gpa);
        defer self.gpa.free(data);
        _ = storage.writeAtomic(self.io, self.gpa, path, data);
    }
};

// MARK: - View

pub const MarkAction = enum(u8) { none, add, remove, too_short, too_long, unavailable };

pub const Mark = struct {
    range: Range,
    text: []const u8,
    reading: []const u8,
    action: MarkAction,
};

pub const View = struct {
    preedit: []const u8,
    /// UTF-16 offset.
    caret: u32,
    candidates: []const []const u8,
    selected: usize,
    selection_keys: []const []const u8,
    keys_active: bool,
    shows_candidates: bool,
    mark: ?Mark = null,
    page_size: usize,
};

// MARK: - Session

const SymbolMenu = struct {
    storage: [16][]const u8 = undefined,
    count: usize = 0,
    selected: usize = 0,
    selecting: bool = false,

    fn choices(self: *const SymbolMenu) []const []const u8 {
        return self.storage[0..self.count];
    }
};

const settle_distance = 3;

const MarkState = struct { anchor: i64, head: i64 };

pub const Session = struct {
    engine: *Engine,
    gpa: Allocator,
    arenas: [2]std.heap.ArenaAllocator,
    cur: u1 = 0,
    view_arena: std.heap.ArenaAllocator,
    result_arena: std.heap.ArenaAllocator,
    /// unpicked_top's copy; reset with the composition.
    pick_arena: std.heap.ArenaAllocator,

    settings: Settings = .{},
    composition: Composition = .{},
    candidates: []Candidate = &.{},
    selected: usize = 0,
    latin_mode: bool = false,
    pinned_pick: ?[]u8 = null,
    explicit_pick: bool = false,
    cursor: ?usize = null,
    segment_texts: ?[]const []const u8 = null,
    segment_options: []const CursorOption = &.{},
    segment_selected: usize = 0,
    segment_caret: ?u32 = null,
    session_pins: UserLexicon,
    learn_pins: UserLexicon,
    settled_pins: UserLexicon,
    raw_tail: []const u8 = &.{},
    complete_texts: []const []const u8 = &.{},
    selecting: bool = false,
    symbol_menu: ?SymbolMenu = null,
    mark: ?MarkState = null,
    retype_before: ?[]Key = null,
    retypes: std.ArrayList(channel_mod.Pair) = .empty,
    unpicked_top: ?Candidate = null,

    pub fn create(engine: *Engine) !*Session {
        const gpa = engine.gpa;
        const self = try gpa.create(Session);
        self.* = .{
            .engine = engine,
            .gpa = gpa,
            .arenas = .{ .init(gpa), .init(gpa) },
            .view_arena = .init(gpa),
            .result_arena = .init(gpa),
            .pick_arena = .init(gpa),
            .session_pins = .init(gpa),
            .learn_pins = .init(gpa),
            .settled_pins = .init(gpa),
        };
        engine.refs += 1;
        return self;
    }

    pub fn destroy(self: *Session) void {
        const gpa = self.gpa;
        for (&self.arenas) |*a| a.deinit();
        self.view_arena.deinit();
        self.result_arena.deinit();
        self.pick_arena.deinit();
        self.composition.deinit(gpa);
        self.session_pins.deinit();
        self.learn_pins.deinit();
        self.settled_pins.deinit();
        if (self.pinned_pick) |p| gpa.free(p);
        if (self.retype_before) |r| gpa.free(r);
        self.retypes.deinit(gpa);
        const engine = self.engine;
        gpa.destroy(self);
        engine.release();
    }

    fn arena(self: *Session) Allocator {
        return self.arenas[self.cur].allocator();
    }

    fn decoder(self: *Session) *Lexicon {
        return self.engine.decoder;
    }

    // MARK: Host API

    pub fn rawPhonetic(self: *Session) ![]const u8 {
        _ = self.result_arena.reset(.retain_capacity);
        return self.composition.rawPhonetic(self.result_arena.allocator());
    }

    pub fn latinActive(self: *const Session) bool {
        return self.latin_mode;
    }

    pub fn view(self: *Session) !View {
        _ = self.view_arena.reset(.retain_capacity);
        const va = self.view_arena.allocator();
        const preedit = try self.previewText(va);
        const page_size = self.settings.page_size;
        if (self.symbol_menu) |*menu| {
            return .{
                .preedit = preedit,
                .caret = try self.caretOffset(preedit),
                .candidates = try va.dupe([]const u8, menu.choices()),
                .selected = menu.selected,
                .selection_keys = try selectionLabels(va, self.settings.candidate_keys, page_size),
                .keys_active = menu.selecting,
                .shows_candidates = menu.selecting or self.settings.auto_show_candidates,
                .page_size = page_size,
            };
        }
        if (try self.markView(va)) |marked| {
            return .{
                .preedit = preedit,
                .caret = marked.caret,
                .candidates = &.{},
                .selected = 0,
                .selection_keys = &.{},
                .keys_active = false,
                .shows_candidates = true,
                .mark = marked.mark,
                .page_size = page_size,
            };
        }
        const texts: []const []const u8 = if (self.segment_texts) |t| t else blk: {
            const out = try va.alloc([]const u8, self.candidates.len);
            for (self.candidates, out) |c, *o| o.* = c.text;
            break :blk out;
        };
        return .{
            .preedit = preedit,
            .caret = try self.caretOffset(preedit),
            .candidates = texts,
            .selected = if (self.segment_texts != null) self.segment_selected else self.selected,
            .selection_keys = try selectionLabels(va, self.settings.candidate_keys, page_size),
            .keys_active = self.selecting,
            .shows_candidates = if (self.segment_texts != null) texts.len > 0 else texts.len > 1 and (self.selecting or self.settings.auto_show_candidates),
            .page_size = page_size,
        };
    }

    fn hasSelected(self: *const Session) bool {
        return self.selected < self.candidates.len;
    }

    fn isComplete(self: *const Session, text: []const u8) bool {
        for (self.complete_texts) |t| if (unicode.equal(t, text)) return true;
        return false;
    }

    fn showingComplete(self: *const Session) bool {
        return self.hasSelected() and self.isComplete(self.candidates[self.selected].text);
    }

    pub fn handle(self: *Session, event_: KeyEvent) !KeyResult {
        _ = self.result_arena.reset(.retain_capacity);
        self.settings = self.engine.settings;
        const mods = event_.mods;
        const other_mods = mods & (mod_command | mod_control | mod_option | mod_caps_lock) != 0;
        const now = event_.timestamp orelse storage.nowMonotonic(self.engine.io);
        const shift = event_.shiftSide();
        if (event_.release) {
            const tap = self.engine.shift_tap.feed(shift, mods & mod_shift != 0, false, other_mods, now);
            if (!(tap and self.settings.shift_toggle)) return .handled;
            // Mid-composition a lone Shift tap opens/closes a Latin run
            // instead of committing.
            if (!self.engine.english and (!self.composition.isEmpty() or self.latin_mode)) {
                if (!self.latin_mode and self.composition.caret == null and self.looksLikeMistypedEnglish() and
                    self.composition.convertTailToLatin())
                {
                    self.resetPicks();
                    try self.refresh(false);
                    self.latin_mode = true;
                } else {
                    self.latin_mode = !self.latin_mode;
                }
                return .{ .consumed = true, .latin_toggled = true };
            }
            return self.toggleEnglish();
        }
        if (shift != null) {
            _ = self.engine.shift_tap.feed(shift, mods & mod_shift != 0, false, other_mods, now);
            return .handled;
        }
        _ = self.engine.shift_tap.feed(null, mods & mod_shift != 0, true, other_mods, now);
        const event = resolveBinding(event_);
        if (self.composition.isEmpty()) try self.engine.reloadUserDictionaryIfChanged();
        if (event.kind == .modifier and (event.text == null or event.text.?.len == 0)) return .handled;
        var result = try self.typeKey(event);
        if (result.consumed and !result.beep and result.commit == null) {
            if (try self.commitSettledHead()) |chunk| result.commit = chunk;
        }
        return result;
    }

    /// Chunked auto-commit of the settled head (see Swift).
    fn commitSettledHead(self: *Session) !?[]const u8 {
        const limit = self.settings.auto_commit_syllables;
        if (limit == 0 or self.composition.isEmpty() or self.cursor != null or self.composition.caret != null or
            self.selecting or self.symbol_menu != null or !self.session_pins.isEmpty() or self.explicit_pick or
            !self.hasSelected() or self.showingComplete()) return null;
        const shown = self.candidates[self.selected];
        const total = shown.syllables.len;
        if (total <= limit or shown.unresolved != 0) return null;
        const bound = @as(i64, @intCast(total)) - @as(i64, @intCast(limit / 2));
        var cut: ?Span = null;
        var i = shown.alignment.len;
        while (i > 0) {
            i -= 1;
            if (@as(i64, shown.alignment[i].syllables.end) <= bound) {
                cut = shown.alignment[i];
                break;
            }
        }
        const c = cut orelse return null;
        if (c.syllables.end == 0) return null;
        var wanted: std.ArrayList(u8) = .empty;
        const a = self.arena();
        for (shown.syllables[0..c.syllables.end]) |s| try wanted.appendSlice(a, s.keys);
        var w: usize = 0;
        var cut_index: usize = 0;
        for (self.composition.keys(), 0..) |key, index| {
            if (!key.isSymbol()) continue;
            if (w >= wanted.items.len or key.key != wanted.items[w]) return null;
            w += 1;
            cut_index = index + 1;
            if (w == wanted.items.len) break;
        }
        if (w != wanted.items.len) return null;
        const keys = self.composition.keys();
        if (cut_index < keys.len and keys[cut_index].isTone()) cut_index += 1;
        if (c.chars.end > shown.utf16_len) return null;
        const chunk = try unicode.utf16Slice(self.result_arena.allocator(), shown.text, 0, c.chars.end);
        if (chunk.len == 0) return null;
        const owned = try self.result_arena.allocator().dupe(u8, chunk);
        self.composition.dropHead(cut_index);
        self.clearRetypeBefore();
        self.candidates = &.{};
        self.settled_pins.clear();
        self.setPinnedPick(null);
        self.selected = 0;
        try self.refresh(false);
        return owned;
    }

    /// Panel click (or any host-side pick) on row `index` of the view.
    pub fn pick(self: *Session, index: usize) !void {
        self.settings = self.engine.settings;
        if (self.symbol_menu) |menu| {
            if (index < menu.count) try self.applyMenuChoice(index);
            self.symbol_menu = null;
            return;
        }
        if (self.segment_texts) |texts| if (index < texts.len) {
            try self.pinAdvance(index);
            return;
        };
        if (index >= self.candidates.len) return;
        try self.noteUnpicked();
        self.selected = index;
        self.setPinnedPick(self.candidates[index].text);
        self.explicit_pick = true;
        self.selecting = false;
    }

    /// Commit what is shown (focus loss, client request).
    pub fn commit(self: *Session) !?[]const u8 {
        _ = self.result_arena.reset(.retain_capacity);
        self.settings = self.engine.settings;
        return self.commitText(false);
    }

    pub fn resetModifierState(self: *Session) void {
        self.engine.shift_tap.reset();
    }

    // MARK: Key handling

    fn pass(self: *Session, committing: bool) !KeyResult {
        return .{ .consumed = false, .commit = if (committing) try self.commitText(false) else null };
    }

    fn toggleEnglish(self: *Session) !KeyResult {
        const text = try self.commitText(false);
        self.engine.english = !self.engine.english;
        self.latin_mode = false;
        return .{ .consumed = true, .commit = text, .mode_changed = true };
    }

    fn setPinnedPick(self: *Session, text: ?[]const u8) void {
        if (self.pinned_pick) |p| self.gpa.free(p);
        self.pinned_pick = if (text) |t| self.gpa.dupe(u8, t) catch null else null;
    }

    fn clearRetypeBefore(self: *Session) void {
        if (self.retype_before) |r| self.gpa.free(r);
        self.retype_before = null;
    }

    fn noteUnpicked(self: *Session) !void {
        if (self.unpicked_top != null or self.candidates.len == 0) return;
        self.unpicked_top = try self.candidates[0].deepCopy(self.pick_arena.allocator());
    }

    fn typeKey(self: *Session, event: KeyEvent) !KeyResult {
        const kind = event.kind;
        const mods = event.mods;
        const shift = mods & mod_shift != 0;
        const chord = mods & (mod_command | mod_control | mod_option) != 0;
        // A mark survives only its own gestures.
        const mark_gesture = (shift and (kind == .left or kind == .right)) or kind == .escape or (kind == .enter and !shift);
        if (self.mark != null and (!mark_gesture or chord)) self.mark = null;
        const text = event.text orelse "";
        if ((kind == .character or kind == .other) and text.len == 0) return .handled;
        if (kind == .space and shift) return self.toggleEnglish();
        if (self.engine.english or mods & mod_caps_lock != 0) return self.pass(true);
        const latin_letter = self.latin_mode and !chord and
            (event.letterLabel() != null or (!shift and event.digitLabel() != null) or
                (!shift and if (event.characterLabel()) |l| (l.len == 1 and composition_mod.isLatinPunctuation(l[0])) else false));
        if (!latin_letter and !event.isChar("`") and kind != .space and kind != .backspace and kind != .escape) {
            self.latin_mode = false;
        }
        if (self.symbol_menu) |*menu_ptr| {
            var menu = menu_ptr.*;
            const count = menu.count;
            if (!chord) {
                switch (kind) {
                    .down, .up => {
                        const index = (menu.selected + (if (kind == .down) @as(usize, 1) else count - 1)) % count;
                        return self.stepMenu(&menu, index);
                    },
                    .page_up, .page_down => {
                        if (self.pageTarget(menu.selected, count, kind == .page_down)) |index| return self.stepMenu(&menu, index);
                        if (menu.selecting) return .beeped;
                        menu.selecting = true;
                        self.symbol_menu = menu;
                        return .handled;
                    },
                    .escape => {
                        self.symbol_menu = null;
                        return .handled;
                    },
                    .enter => if (menu.selecting and !shift and self.settings.return_confirms_selection) {
                        self.symbol_menu = null;
                        return .handled;
                    },
                    else => {},
                }
                if (menu.selecting and !shift) if (event.characterLabel()) |label| {
                    const slot = try selectionSlot(self.arena(), label, self.settings.candidate_keys, self.settings.page_size);
                    if (slot == null) if (pageDirection(label)) |forward| if (self.pageTarget(menu.selected, count, forward)) |index| {
                        return self.stepMenu(&menu, index);
                    };
                    if (slot) |s| {
                        const global = (menu.selected / self.settings.page_size) * self.settings.page_size + s;
                        if (global >= count) return .beeped;
                        try self.applyMenuChoice(global);
                        self.symbol_menu = null;
                        return .handled;
                    }
                };
            }
            self.symbol_menu = null;
        }
        // Destructive editing never commits first.
        if (kind == .backspace) return self.backspaceKey(mods);
        if (kind == .forward_delete) {
            if (self.composition.isEmpty()) return self.pass(false);
            const at = self.composition.caret orelse return self.pass(true);
            if (chord) return self.pass(true);
            var range = Range.of(at, at + 1);
            if (try self.layout()) |l| {
                for (l.syllable_keys) |r| if (r.start == at) {
                    range = r;
                    break;
                };
            }
            self.composition.removeKeys(range.start, range.end);
            self.settled_pins.clear();
            self.clearRetypeBefore();
            try self.refresh(false);
            return .handled;
        }
        if (kind == .down or kind == .up) {
            if (self.composition.isEmpty()) return self.pass(false);
            if (self.segment_texts) |texts| if (texts.len > 0) {
                self.segment_selected = (self.segment_selected + (if (kind == .down) @as(usize, 1) else texts.len - 1)) % texts.len;
                self.selecting = true;
                return .handled;
            };
            if (self.candidates.len > 1) {
                try self.selectCandidate((self.selected + (if (kind == .down) @as(usize, 1) else self.candidates.len - 1)) % self.candidates.len);
                self.selecting = true;
                return .handled;
            }
            return self.pass(true);
        }
        if (kind == .page_up or kind == .page_down) {
            if (self.composition.isEmpty()) return self.pass(false);
            if (chord) return self.pass(true);
            return self.page(kind == .page_down);
        }
        if ((kind == .left or kind == .right) and chord) {
            if (mods & (mod_command | mod_control) == 0 and !self.composition.isEmpty()) {
                if (try self.moveWord(kind == .right)) |moved| return if (moved) .handled else .beeped;
            }
            return self.pass(true);
        }
        if ((kind == .left or kind == .right) and shift) {
            if (self.composition.isEmpty()) return self.pass(false);
            return if (try self.extendMark(kind == .right)) .handled else .beeped;
        }
        if (kind == .left or kind == .right) {
            if (self.composition.isEmpty()) return self.pass(false);
            const moved = if (kind == .left) try self.moveCursorBack() else try self.moveCursorForward();
            return if (moved) .handled else .beeped;
        }
        if (kind == .escape) {
            if (self.composition.isEmpty()) return self.pass(false);
            if (self.mark != null) {
                const visible = (try self.markView(self.arena())) != null;
                self.mark = null;
                if (visible) return .handled;
            }
            if (self.selecting and self.segment_texts != null) {
                self.selecting = false;
                return .handled;
            }
            if (self.selecting or self.segment_texts != null or self.composition.caret != null) {
                self.selecting = false;
                self.cursor = null;
                self.clearSegment();
                try self.returnCaretToEnd();
                return .handled;
            }
            self.clear(true);
            return .handled;
        }
        if (chord) return self.pass(true);
        if (kind == .enter) {
            if (self.composition.isEmpty()) return self.pass(false);
            if (self.mark != null) return self.fileMark();
            if (shift) return .{ .consumed = true, .commit = try self.commitText(true) };
            if (self.settings.return_confirms_selection and (self.selecting or self.segment_texts != null)) {
                if (self.segment_texts) |texts| {
                    if (self.segment_selected < texts.len) {
                        try self.pinAdvance(self.segment_selected);
                    } else self.selecting = false;
                } else self.selecting = false;
                return .handled;
            }
            if (self.segment_texts) |texts| if (self.segment_selected < texts.len) {
                try self.pinAdvance(self.segment_selected);
                self.selected = 0;
            };
            return .{ .consumed = true, .commit = try self.commitText(false) };
        }
        if (event.isChar("`") and !shift and !self.engine.english) {
            self.latin_mode = !self.latin_mode;
            return .{ .consumed = true, .latin_toggled = true };
        }
        const page_size = self.settings.page_size;
        if (self.selecting and !self.composition.isEmpty() and !shift) if (event.characterLabel()) |label| {
            if ((try selectionSlot(self.arena(), label, self.settings.candidate_keys, page_size)) == null) {
                if (pageDirection(label)) |forward| return self.page(forward);
            }
        };
        if (self.selecting and !self.composition.isEmpty() and !shift) if (event.zhuyinLabel()) |label| {
            if (try selectionSlot(self.arena(), &.{label}, self.settings.candidate_keys, page_size)) |slot| {
                if (self.segment_texts) |texts| {
                    const global = (self.segment_selected / page_size) * page_size + slot;
                    if (global >= texts.len) return .beeped;
                    try self.pinAdvance(global);
                    return .handled;
                }
                const global = (self.selected / page_size) * page_size + slot;
                if (global >= self.candidates.len) return .beeped;
                try self.selectCandidate(global);
                self.selecting = false;
                return .handled;
            }
        };
        // CJK punctuation pins the current pick and continues.
        if (kind == .character) {
            const before = self.composition.beforeCaret();
            const lits = try self.arena().alloc(?[]const u8, before.len);
            for (before, lits) |k, *l| l.* = k.literalText();
            const ctrl = mods & mod_control != 0;
            if (punctuation.smartQuote(event.label, shift, ctrl, lits) orelse punctuation.output(event.label, shift, ctrl)) |punct| {
                if (self.hasSelected()) self.setPinnedPick(self.candidates[self.selected].text);
                const tail = try self.composition.splitAtCaret(self.gpa);
                const ok = try self.composition.appendLiteral(self.gpa, punct);
                try self.composition.joinTail(self.gpa, tail);
                if (!ok) return .beeped;
                try self.refresh(false);
                var menu: SymbolMenu = .{};
                menu.count = punctuation.choices(punct, &menu.storage).len;
                self.symbol_menu = if (menu.count > 1) menu else null;
                return .handled;
            }
        }
        // Latin letters append verbatim (Latin run, or Shift-hold).
        if ((latin_letter or (shift and event.letterLabel() != null)) and text.len == 1) {
            const ch = text[0];
            if (ch < 0x80 and (std.ascii.isAlphabetic(ch) or (latin_letter and (std.ascii.isDigit(ch) or composition_mod.isLatinPunctuation(ch))))) {
                const tail = try self.composition.splitAtCaret(self.gpa);
                const ok = try self.composition.appendLatin(self.gpa, text);
                try self.composition.joinTail(self.gpa, tail);
                if (!ok) return .beeped;
                try self.refresh(false);
                return .handled;
            }
        }
        if (shift and (event.zhuyinLabel() == null or self.composition.isEmpty())) return self.pass(true);
        if (event.zhuyinLabel()) |label| {
            if (label == ' ') {
                if (self.composition.isEmpty()) return .{ .consumed = true, .commit = " " };
                if (!pendingIn(self.composition.beforeCaret()) and self.hasSelected()) {
                    self.setPinnedPick(self.candidates[self.selected].text);
                }
                const tail = try self.composition.splitAtCaret(self.gpa);
                const ok = try self.composition.appendSpace(self.gpa);
                try self.composition.joinTail(self.gpa, tail);
                if (!ok) return .beeped;
                try self.refresh(false);
                return .handled;
            }
            {
                const tail = try self.composition.splitAtCaret(self.gpa);
                const ok = try self.composition.append(self.gpa, label);
                try self.composition.joinTail(self.gpa, tail);
                if (ok) {
                    try self.refresh(false);
                    return .handled;
                }
            }
            // A tone with no pending syllable is a late or corrected tone.
            if (keyboard.isTone(label)) {
                const tail = try self.composition.splitAtCaret(self.gpa);
                const ok = try self.composition.retoneLast(self.gpa, label);
                try self.composition.joinTail(self.gpa, tail);
                if (ok) {
                    try self.refresh(false);
                    return .handled;
                }
            }
            return .beeped;
        }
        return self.pass(true);
    }

    fn backspaceKey(self: *Session, mods: u32) !KeyResult {
        if (self.composition.isEmpty()) return self.pass(false);
        const mid_caret = self.composition.caret != null;
        if (mid_caret) {
            self.clearRetypeBefore();
        } else if (self.retype_before == null) {
            self.retype_before = try self.gpa.dupe(Key, self.composition.keys());
        }
        const last: ?Syllable = if (self.hasSelected() and self.candidates[self.selected].syllables.len > 0)
            self.candidates[self.selected].syllables[self.candidates[self.selected].syllables.len - 1]
        else
            null;
        const before = try self.syllableBeforeCaret();
        self.selected = 0;
        self.settled_pins.clear();
        if (!self.explicit_pick) self.setPinnedPick(null);
        if (mods & mod_command != 0 and !mid_caret) {
            self.clear(true);
        } else if (mods & mod_command != 0) {
            const tail = try self.composition.splitAtCaret(self.gpa);
            self.composition.clear();
            try self.composition.joinTail(self.gpa, tail);
            try self.refresh(false);
        } else if (mods & mod_option != 0) {
            const tail = try self.composition.splitAtCaret(self.gpa);
            self.composition.deleteLastWord();
            try self.composition.joinTail(self.gpa, tail);
            try self.refresh(false);
        } else if (mid_caret) {
            if (before) |r| {
                self.composition.removeKeys(r.start, r.end);
            } else {
                const tail = try self.composition.splitAtCaret(self.gpa);
                self.composition.erase();
                try self.composition.joinTail(self.gpa, tail);
            }
            try self.refresh(false);
        } else {
            var body_buf: [composition_mod.max_keys]u8 = undefined;
            const body = self.composition.trailingBody(&body_buf);
            const matches = if (last) |l| l.keys.len <= body.len and std.mem.eql(u8, body[body.len - l.keys.len ..], l.keys) else false;
            if (matches) {
                self.composition.eraseTailSyllable(last.?.keys.len);
                if (!self.composition.pendingNonEmpty()) self.composition.erase();
            } else {
                self.composition.erase();
            }
            try self.refresh(false);
        }
        if (composition_mod.Composition.hasTrailingLatin(self.composition.beforeCaret())) self.latin_mode = true;
        return .handled;
    }

    fn stepMenu(self: *Session, menu: *SymbolMenu, index: usize) !KeyResult {
        menu.selected = index;
        menu.selecting = true;
        self.symbol_menu = menu.*;
        try self.applyMenuChoice(index);
        return .handled;
    }

    fn applyMenuChoice(self: *Session, index: usize) !void {
        const menu = self.symbol_menu orelse return;
        if (index >= menu.count) return;
        const tail = try self.composition.splitAtCaret(self.gpa);
        _ = try self.composition.replaceLastLiteral(self.gpa, menu.storage[index]);
        try self.composition.joinTail(self.gpa, tail);
        try self.refresh(false);
    }

    /// The same row one page over (clamped), wrapping; null on one page.
    fn pageTarget(self: *const Session, current: usize, count: usize, forward: bool) ?usize {
        const size = self.settings.page_size;
        if (count <= size) return null;
        const pages = (count + size - 1) / size;
        const next = (current / size + (if (forward) @as(usize, 1) else pages - 1)) % pages;
        return @min(next * size + current % size, count - 1);
    }

    fn page(self: *Session, forward: bool) !KeyResult {
        if (self.segment_texts) |texts| {
            const index = self.pageTarget(self.segment_selected, texts.len, forward) orelse {
                if (self.selecting) return .beeped;
                self.selecting = true;
                return .handled;
            };
            self.segment_selected = index;
            self.selecting = true;
            return .handled;
        }
        const index = self.pageTarget(self.selected, self.candidates.len, forward) orelse {
            if (self.selecting or self.candidates.len <= 1) return .beeped;
            self.selecting = true;
            return .handled;
        };
        try self.selectCandidate(index);
        self.selecting = true;
        return .handled;
    }

    fn selectCandidate(self: *Session, index: usize) !void {
        try self.noteUnpicked();
        self.selected = index;
        self.setPinnedPick(self.candidates[index].text);
        self.explicit_pick = true;
    }

    // MARK: Decode and commit

    fn previewText(self: *Session, gpa: Allocator) ![]const u8 {
        const converted = if (self.hasSelected()) self.candidates[self.selected].text else "";
        if (self.isComplete(converted)) return converted;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(gpa, converted);
        for (self.raw_tail) |k| if (keyboard.symbol(k)) |s| try out.appendSlice(gpa, s);
        return out.items;
    }

    fn caretOffset(self: *Session, preedit: []const u8) !u32 {
        const len = unicode.utf16Len(preedit);
        if (self.segment_caret) |focused| return @min(focused, len);
        if (self.composition.caret) |at| if (try self.layout()) |l| return @min(l.offsets[at], len);
        return len;
    }

    fn refresh(self: *Session, keep_cursor: bool) !void {
        const previous = self.candidates;
        self.mark = null;
        const settings = self.settings;
        const dec = self.decoder();
        dec.channel = self.engine.activeChannel(settings);
        dec.repair_cost_offset = settings.repair_strength.costOffset();
        dec.repair_valid_readings = settings.repair_strength.repairsValidReadings();
        self.noteRetype();
        // A whole-sentence pick becomes positional pins before re-decoding.
        if (!keep_cursor and self.pinned_pick != null and self.selected != 0 and self.hasSelected() and
            !self.isComplete(self.candidates[self.selected].text) and !self.isComplete(self.candidates[0].text))
        {
            try self.session_pins.pinDifferences(self.candidates[self.selected], self.candidates[0]);
            try self.learn_pins.pinDifferences(self.candidates[self.selected], self.candidates[0]);
            self.settled_pins.clear();
        }
        // Switch arenas: `previous` stays readable in the old one.
        self.cur = ~self.cur;
        _ = self.arenas[self.cur].reset(.retain_capacity);
        const a = self.arena();
        const user_lex = self.engine.activeUserLexicon(settings);
        const live = try self.livePreview(a, user_lex);
        self.raw_tail = live.raw_tail;
        self.candidates = live.candidates;
        self.complete_texts = &.{};
        if (settings.mixed_english and self.composition.caret == null) if (self.engine.english_lexicon) |english| {
            if (try english_mod.applyEnglish(dec, a, live.candidates, self.composition.keys(), english, settings.fuzzyRepair(), settings.tone_tolerance, user_lex)) |mixed| {
                self.candidates = mixed.candidates;
                self.complete_texts = mixed.complete_texts;
            }
        };
        if (self.composition.caret != null) {
            self.settled_pins.clear();
        } else if (self.candidates.len > 0 and !self.isComplete(self.candidates[0].text)) {
            const settled = try UserLexicon.settled(self.gpa, self.candidates[0], settle_distance);
            self.settled_pins.deinit();
            self.settled_pins = settled;
        } else if (self.candidates.len > 0 and self.isComplete(self.candidates[0].text)) {
            self.settled_pins.clear();
        }
        if (self.pinned_pick != null and self.pinned_pick.?.len > 0) {
            const pin = self.pinned_pick.?;
            var exact: ?usize = null;
            var extended: ?usize = null;
            for (self.candidates, 0..) |c, i| {
                if (exact == null and unicode.equal(c.text, pin)) exact = i;
                if (extended == null and std.mem.startsWith(u8, c.text, pin)) extended = i;
            }
            if (exact) |e| {
                self.selected = e;
            } else if (extended) |e| {
                self.selected = e;
            } else {
                self.selected = 0;
                self.setPinnedPick(null);
                self.explicit_pick = false;
            }
        } else if (!sameTexts(self.candidates, previous) or !self.hasSelected()) {
            self.selected = 0;
        }
        if (!keep_cursor) {
            self.cursor = null;
            self.selecting = false;
        }
        if (self.cursor != null) {
            try self.focusSegment();
        } else self.clearSegment();
    }

    fn sameTexts(a: []const Candidate, b: []const Candidate) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!unicode.equal(x.text, y.text)) return false;
        return true;
    }

    const Live = struct { candidates: []Candidate, raw_tail: []const u8 };

    /// Candidates for everything converted so far plus the raw tail.
    fn livePreview(self: *Session, a: Allocator, user_lex: ?*const UserLexicon) !Live {
        const settings = self.settings;
        const dec = self.decoder();
        const pending = (try self.composition.parsed(a)).pending;
        const cut = try dec.livePendingCut(a, pending, settings.tone_tolerance);
        // Explicit pins win: settled pins are dropped from runs with one.
        var pins = UserLexicon.init(self.gpa);
        defer pins.deinit();
        var explicit_runs: std.StringHashMapUnmanaged(void) = .empty;
        for (self.session_pins.entries.keys()) |key| try explicit_runs.put(a, firstRunPart(key), {});
        {
            var it = self.settled_pins.entries.iterator();
            while (it.next()) |e| {
                if (explicit_runs.contains(firstRunPart(e.key_ptr.*))) continue;
                try copyTexts(&pins, e.key_ptr.*, e.value_ptr);
            }
        }
        {
            var it = self.session_pins.entries.iterator();
            while (it.next()) |e| {
                pins.remove(e.key_ptr.*);
                try copyTexts(&pins, e.key_ptr.*, e.value_ptr);
            }
        }
        var candidates = try dec.decodeSegments(a, try self.composition.segments(a), pending[0..cut], .{
            .fuzzy = settings.fuzzyRepair(),
            .tone_tolerance = settings.tone_tolerance,
            .user_lexicon = user_lex,
            .locked = if (pins.isEmpty()) null else &pins,
        });
        if (!pins.isEmpty() and candidates.len > 0) {
            const floor = candidates[0].score - user_lexicon.pin_bonus / 2;
            var kept: std.ArrayList(Candidate) = .empty;
            for (candidates) |c| if (c.score > floor) try kept.append(a, c);
            candidates = kept.items;
        }
        return .{ .candidates = candidates, .raw_tail = try a.dupe(u8, pending[cut..]) };
    }

    /// `key.split(separator: "#").first` (empty pieces skipped).
    fn firstRunPart(key: []const u8) []const u8 {
        var it = std.mem.tokenizeScalar(u8, key, '#');
        return it.next() orelse "";
    }

    fn copyTexts(into: *UserLexicon, key: []const u8, texts: *const user_lexicon.Texts) !void {
        var it = texts.iterator();
        while (it.next()) |t| try into.put(key, t.key_ptr.*, t.value_ptr.*);
    }

    /// A single changed symbol key, once the keys are back at their
    /// pre-Backspace length, is a re-type.
    fn noteRetype(self: *Session) void {
        const before = self.retype_before orelse return;
        if (self.composition.caret != null) return self.clearRetypeBefore();
        const now = self.composition.keys();
        if (now.len == 0) return self.clearRetypeBefore();
        if (now.len < before.len) return;
        defer self.clearRetypeBefore();
        var diff: ?usize = null;
        for (before, now[0..before.len], 0..) |x, y, i| {
            if (x.eql(y)) continue;
            if (diff != null) return;
            diff = i;
        }
        const i = diff orelse return;
        if (!before[i].isSymbol() or !now[i].isSymbol()) return;
        self.retypes.append(self.gpa, .{ .typed = before[i].key, .intended = now[i].key }) catch {};
    }

    fn commitText(self: *Session, raw: bool) !?[]const u8 {
        if (self.composition.isEmpty()) return null;
        const r = self.result_arena.allocator();
        const learnable = !raw and self.raw_tail.len == 0 and self.hasSelected() and !self.showingComplete();
        var text: []const u8 = if (raw) try self.composition.rawPhonetic(r) else try self.previewText(r);
        if (text.len == 0) {
            const a = self.arena();
            const parsed = try self.composition.parsed(a);
            const decoded = try self.decoder().decodeSegments(a, try self.composition.segments(a), parsed.pending, .{
                .fuzzy = self.settings.fuzzyRepair(),
                .tone_tolerance = self.settings.tone_tolerance,
                .user_lexicon = self.engine.activeUserLexicon(self.settings),
                .locked = if (self.session_pins.isEmpty()) null else &self.session_pins,
            });
            text = if (decoded.len > 0) try r.dupe(u8, decoded[0].text) else try self.composition.rawPhonetic(r);
        }
        text = unicode.trimTrailingWhitespace(text);
        if (text.len == 0) return null;
        const corrected = self.explicit_pick and (self.selected != 0 or !self.learn_pins.isEmpty());
        if (self.settings.user_learning and corrected and learnable) {
            const words = try user_lexicon.learnedWords(self.arena(), self.candidates[self.selected], &self.learn_pins, if (self.selected == 0) null else self.candidates[0]);
            try self.engine.learn(words);
        }
        if (self.settings.user_learning and self.settings.channel_learning and learnable) {
            var evidence = try self.channelEvidence(self.candidates[self.selected], if (corrected) self.unpicked_top else null, corrected);
            try self.engine.observeChannel(&evidence);
        }
        self.clear(false);
        return text;
    }

    /// Drop the composition and every pick; an open Latin run survives
    /// Esc and delete-all (`keep_latin`).
    fn clear(self: *Session, keep_latin: bool) void {
        self.composition.clear();
        self.candidates = &.{};
        self.raw_tail = &.{};
        self.complete_texts = &.{};
        self.resetPicks();
        self.selected = 0;
        if (!keep_latin) self.latin_mode = false;
        self.clearRetypeBefore();
        self.retypes.clearRetainingCapacity();
        self.unpicked_top = null;
        _ = self.pick_arena.reset(.retain_capacity);
    }

    fn resetPicks(self: *Session) void {
        self.settled_pins.clear();
        self.selecting = false;
        self.symbol_menu = null;
        self.setPinnedPick(null);
        self.explicit_pick = false;
        self.cursor = null;
        self.mark = null;
        self.clearSegment();
        self.session_pins.clear();
        self.learn_pins.clear();
        self.selected = 0;
    }

    fn looksLikeMistypedEnglish(self: *const Session) bool {
        return self.raw_tail.len > 3 or (self.hasSelected() and self.candidates[self.selected].unresolved > 0);
    }

    // MARK: Channel evidence

    /// Intended symbol keys per syllable of `candidate` (null where the
    /// text is no dictionary word).
    fn intendedKeys(self: *Session, a: Allocator, c: Candidate) ![]?[]const u8 {
        const out = try a.alloc(?[]const u8, c.syllables.len);
        @memset(out, null);
        for (c.alignment) |span| {
            if (span.chars.end > c.utf16_len or span.syllables.end > c.syllables.len) continue;
            const word = try unicode.utf16Slice(a, c.text, span.chars.start, span.chars.end);
            const path = (try self.decoder().readingsOf(a, word, c.syllables, span.syllables, true, true)) orelse continue;
            var parts = std.mem.splitScalar(u8, path, '-');
            var offset: usize = 0;
            while (parts.next()) |reading| : (offset += 1) {
                var keys: std.ArrayList(u8) = .empty;
                var it = unicode.scalars(reading);
                var i: usize = 0;
                while (it.nextCodepoint()) |_| {
                    const w = it.i - i;
                    if (keyboard.keyForSymbol(reading[i .. i + w])) |k| try keys.append(a, k);
                    i = it.i;
                }
                out[span.syllables.start + offset] = keys.items;
            }
        }
        return out;
    }

    fn channelEvidence(self: *Session, committed: Candidate, unpicked: ?Candidate, explicit: bool) !channel_mod.Evidence {
        const a = self.arena();
        var evidence: channel_mod.Evidence = .{ .explicit = explicit, .retypes = self.retypes.items };
        const intended = try self.intendedKeys(a, committed);
        for (intended, 0..) |maybe, index| {
            const keys = maybe orelse continue;
            try evidence.intended.appendSlice(a, keys);
            if (channel_mod.substitution(committed.syllables[index].keys, keys)) |pair| try evidence.repaired.append(a, pair);
        }
        if (unpicked) |u| if (!unicode.equal(u.text, committed.text) and sameKeys(u.syllables, committed.syllables)) {
            for (try self.intendedKeys(a, u), 0..) |maybe, index| {
                const keys = maybe orelse continue;
                const own = intended[index] orelse continue;
                if (!std.mem.eql(u8, own, committed.syllables[index].keys)) continue;
                if (channel_mod.substitution(committed.syllables[index].keys, keys)) |pair| try evidence.reverts.append(a, pair);
            }
        };
        return evidence;
    }

    fn sameKeys(a: []const Syllable, b: []const Syllable) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.mem.eql(u8, x.keys, y.keys)) return false;
        return true;
    }

    // MARK: Syllable cursor

    fn focusFrame(self: *const Session) ?Candidate {
        if (!self.hasSelected()) return null;
        const top = self.candidates[self.selected];
        if (top.unresolved != 0 or self.isComplete(top.text) or top.alignment.len == 0) return null;
        const end = top.alignment[top.alignment.len - 1].syllables.end;
        if (end == 0 or top.syllables.len != end) return null;
        return top;
    }

    /// Text `top` shows over a syllable span.
    fn spanTextOf(self: *Session, span: Range, top: Candidate) !?[]const u8 {
        const start = top.charOffset(span.start) orelse return null;
        const end = if (span.end >= top.syllables.len) top.utf16_len else (top.charOffset(span.end) orelse return null);
        if (start > end) return null;
        return try top.slice(self.arena(), Range.of(start, end));
    }

    fn clearSegment(self: *Session) void {
        self.segment_texts = null;
        self.segment_options = &.{};
        self.segment_selected = 0;
        self.segment_caret = null;
    }

    fn focusSegment(self: *Session) !void {
        self.clearSegment();
        const a = self.arena();
        const c = self.cursor orelse return self.dropCursor();
        const top = self.focusFrame() orelse return self.dropCursor();
        const word = top.wordAt(c) orelse return self.dropCursor();
        const caret = self.cursorCaret(c, top) orelse return self.dropCursor();
        const run = top.run(c);
        var options: std.ArrayList(CursorOption) = .empty;
        for (try cursorOptions(self.decoder(), a, top.syllables, c, run, self.settings.fuzzyRepair(), self.settings.tone_tolerance)) |o| {
            if (self.settings.cursor_candidates.lists(o.span, c)) try options.append(a, o);
        }
        const lists = self.settings.cursor_candidates.lists(word.syllables, c);
        const shown_word: ?[]const u8 = if (lists) try top.slice(a, word.chars) else null;
        const shown_char: ?[]const u8 = if (top.charOffset(c)) |off| try top.slice(a, Range.of(off, off + 1)) else null;
        if (shown_word) |sw| {
            const listed = for (options.items) |o| {
                if (o.span.eql(word.syllables) and unicode.equal(o.text, sw)) break true;
            } else false;
            if (!listed) {
                var at = options.items.len;
                for (options.items, 0..) |o, i| if (o.span.len() < word.syllables.len()) {
                    at = i;
                    break;
                };
                try options.insert(a, at, .{ .text = sw, .span = word.syllables, .score = -std.math.inf(f64) });
            }
        }
        var current: ?usize = null;
        if (shown_word) |sw| for (options.items, 0..) |o, i| if (o.span.eql(word.syllables) and unicode.equal(o.text, sw)) {
            current = i;
            break;
        };
        if (current == null) if (shown_char) |sc| for (options.items, 0..) |o, i| if (o.span.eql(Range.of(c, c + 1)) and unicode.equal(o.text, sc)) {
            current = i;
            break;
        };
        const cur = current orelse return self.dropCursor();
        const texts = try a.alloc([]const u8, options.items.len);
        for (options.items, texts) |o, *t| t.* = o.text;
        self.segment_options = options.items;
        self.segment_texts = texts;
        self.segment_selected = cur;
        self.segment_caret = caret;
        // Typing goes where the caret shows.
        const l = try self.layout();
        self.composition.moveCaret(if (l) |lay| lay.keyIndex(self.cursorBoundary(c)) else null);
    }

    fn dropCursor(self: *Session) void {
        self.cursor = null;
        self.composition.moveCaret(null);
    }

    fn cursorCaret(self: *const Session, c: usize, top: Candidate) ?u32 {
        if (self.settings.cursor_candidates != .ending_at) return top.charOffset(c);
        const word = top.wordAt(c) orelse return null;
        if (word.chars.len() != word.syllables.len()) return word.chars.end;
        return word.chars.start + @as(u32, @intCast(c + 1 - word.syllables.start));
    }

    fn cursorBoundary(self: *const Session, c: usize) usize {
        return if (self.settings.cursor_candidates == .ending_at) c + 1 else c;
    }

    fn moveCursorBack(self: *Session) !bool {
        const top = self.focusFrame() orelse return false;
        const end = top.alignment[top.alignment.len - 1].syllables.end;
        if (end == 0) return false;
        const from: usize = self.cursor orelse (try self.caretBoundary()) orelse end;
        self.cursor = if (from == 0) 0 else from - 1;
        self.selecting = false;
        try self.focusSegment();
        return true;
    }

    fn moveCursorForward(self: *Session) !bool {
        const top = self.focusFrame() orelse return false;
        const end: i64 = top.alignment[top.alignment.len - 1].syllables.end;
        var current: i64 = undefined;
        if (self.cursor) |c| {
            current = @intCast(c);
        } else if (try self.caretBoundary()) |b| {
            current = if (self.settings.cursor_candidates == .ending_at) @as(i64, @intCast(b)) - 1 else @intCast(b);
        } else return false;
        self.selecting = false;
        if (current + 1 >= end) {
            self.cursor = null;
            self.clearSegment();
            try self.returnCaretToEnd();
            return true;
        }
        self.cursor = @intCast(current + 1);
        try self.focusSegment();
        return true;
    }

    // MARK: Insertion caret

    fn layout(self: *Session) !?Layout {
        if (!self.hasSelected() or self.showingComplete()) return null;
        return Layout.init(self.arena(), self.composition.keys(), self.composition.caret, self.candidates[self.selected], self.raw_tail.len);
    }

    fn caretBoundary(self: *Session) !?usize {
        const at = self.composition.caret orelse return null;
        const l = (try self.layout()) orelse return null;
        return l.boundary(at);
    }

    fn syllableBeforeCaret(self: *Session) !?Range {
        const at = self.composition.caret orelse return null;
        const l = (try self.layout()) orelse return null;
        const b = l.boundary(at);
        if (b == 0 or l.syllable_keys[b - 1].end != at) return null;
        return l.syllable_keys[b - 1];
    }

    fn moveWord(self: *Session, forward: bool) !?bool {
        const l = (try self.layout()) orelse return null;
        const count = self.composition.keys().len;
        const at = self.composition.caret orelse count;
        var target: ?usize = null;
        if (forward) {
            for (l.word_ends) |e| if (e > at) {
                target = e;
                break;
            };
        } else {
            var i = l.word_starts.len;
            while (i > 0) {
                i -= 1;
                if (l.word_starts[i] < at) {
                    target = l.word_starts[i];
                    break;
                }
            }
        }
        const t = target orelse return false;
        self.cursor = null;
        self.selecting = false;
        self.clearSegment();
        if (t >= count) {
            try self.returnCaretToEnd();
        } else self.composition.moveCaret(t);
        const before = self.composition.beforeCaret();
        var i = before.len;
        self.latin_mode = false;
        while (i > 0) {
            i -= 1;
            if (before[i].isSpace()) continue;
            self.latin_mode = before[i] == .latin;
            break;
        }
        return true;
    }

    fn returnCaretToEnd(self: *Session) !void {
        if (self.composition.caret == null) return;
        self.composition.moveCaret(null);
        try self.refresh(false);
    }

    fn pinAdvance(self: *Session, index: usize) !void {
        if (index >= self.segment_options.len) return;
        const top = self.focusFrame() orelse return;
        const option = self.segment_options[index];
        try self.noteUnpicked();
        const shown = try self.spanTextOf(option.span, top);
        if (shown == null or !unicode.equal(shown.?, option.text)) try self.learn_pins.pin(option, top);
        try self.session_pins.pin(option, top);
        self.settled_pins.clear();
        self.setPinnedPick(null);
        self.explicit_pick = true;
        self.cursor = option.span.end;
        try self.refresh(true);
    }

    // MARK: Phrase marking

    fn extendMark(self: *Session, forward: bool) !bool {
        const top = self.focusFrame() orelse return false;
        const end: i64 = top.alignment[top.alignment.len - 1].syllables.end;
        if (end <= 0) return false;
        var next = self.mark orelse blk: {
            const start: i64 = if (self.cursor) |c| @intCast(self.cursorBoundary(c)) else if (try self.caretBoundary()) |b| @intCast(b) else end;
            break :blk MarkState{ .anchor = start, .head = start };
        };
        const head = next.head + (if (forward) @as(i64, 1) else -1);
        if (head < 0 or head > end) return false;
        next.head = head;
        self.mark = next;
        self.selecting = false;
        self.cursor = null;
        self.clearSegment();
        return true;
    }

    const MarkedView = struct { mark: Mark, caret: u32 };

    fn markView(self: *Session, a: Allocator) !?MarkedView {
        const marked = self.mark orelse return null;
        if (marked.anchor == marked.head) return null;
        const top = self.focusFrame() orelse return null;
        const lo: usize = @intCast(@min(marked.anchor, marked.head));
        const hi: usize = @intCast(@max(marked.anchor, marked.head));
        const start = markOffset(top, lo) orelse return null;
        const end = markOffset(top, hi) orelse return null;
        const caret = markOffset(top, @intCast(marked.head)) orelse return null;
        if (start > end) return null;
        const span = Range.of(lo, hi);
        const phrase = try self.markedPhrase(a, span, top);
        const action: MarkAction = if (span.len() > user_dictionary.max_syllables)
            .too_long
        else if (span.len() < user_dictionary.min_syllables)
            .too_short
        else if (phrase) |p|
            (if (self.engine.user_dictionary.contains(p.reading, p.text)) .remove else .add)
        else
            .unavailable;
        return .{
            .mark = .{
                .range = Range.of(start, end),
                .text = if (phrase) |p| p.text else "",
                .reading = if (phrase) |p| p.reading else "",
                .action = action,
            },
            .caret = caret,
        };
    }

    fn markOffset(top: Candidate, boundary: usize) ?u32 {
        if (boundary >= top.syllables.len) {
            return if (top.alignment.len > 0) top.alignment[top.alignment.len - 1].chars.end else null;
        }
        return top.charOffset(boundary);
    }

    const Phrase = struct { text: []const u8, reading: []const u8 };

    fn markedPhrase(self: *Session, a: Allocator, span: Range, top: Candidate) !?Phrase {
        if (span.isEmpty()) return null;
        const run = top.run(span.start) orelse return null;
        if (span.end > run.end) return null;
        var chars: std.ArrayList(u8) = .empty;
        var readings: std.ArrayList(u8) = .empty;
        var count: usize = 0;
        for (top.alignment) |word| {
            if (!word.syllables.overlaps(span)) continue;
            const text = (try top.slice(a, word.chars)) orelse return null;
            const letters = try unicode.characters(a, text);
            if (letters.len != word.syllables.len()) return null;
            const path = (try self.decoder().readingsOf(a, text, top.syllables, word.syllables, self.settings.fuzzyRepair(), self.settings.tone_tolerance)) orelse return null;
            var parts: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeScalar(u8, path, '-');
            while (it.next()) |p| try parts.append(a, p);
            var index = word.syllables.start;
            while (index < word.syllables.end) : (index += 1) {
                if (!span.contains(index)) continue;
                try chars.appendSlice(a, letters[index - word.syllables.start]);
                if (count > 0) try readings.append(a, '-');
                try readings.appendSlice(a, parts.items[index - word.syllables.start]);
                count += 1;
            }
        }
        if (count != span.len()) return null;
        return .{ .text = chars.items, .reading = readings.items };
    }

    fn fileMark(self: *Session) !KeyResult {
        const a = self.arena();
        const marked = (try self.markView(a)) orelse {
            self.mark = null;
            return .beeped;
        };
        var dictionary = try self.engine.user_dictionary.clone();
        switch (marked.mark.action) {
            .add => _ = try dictionary.add(marked.mark.reading, marked.mark.text, user_dictionary.default_weight),
            .remove => _ = dictionary.remove(marked.mark.reading, marked.mark.text),
            else => {
                dictionary.deinit();
                return .beeped;
            },
        }
        try self.engine.setUserDictionary(dictionary, true);
        self.settled_pins.clear();
        self.setPinnedPick(null);
        try self.refresh(false);
        return .handled;
    }
};

/// Whether `keys` (a caret-free head) end in pending symbol keys.
fn pendingIn(keys: []const Key) bool {
    var i = keys.len;
    while (i > 0) {
        i -= 1;
        return keys[i].isSymbol();
    }
    return false;
}

/// Every word covering syllable `cursor`: longest spans first, then
/// earlier starts, each span best-first (multi-syllable spans keep 4).
pub fn cursorOptions(dec: *const Lexicon, a: Allocator, syllables: []const Syllable, cursor: usize, within: ?Range, fuzzy: bool, tone_tolerance: bool) ![]CursorOption {
    var bounds = within orelse Range.of(0, syllables.len);
    bounds.start = @min(bounds.start, @as(u32, @intCast(syllables.len)));
    bounds.end = @min(bounds.end, @as(u32, @intCast(syllables.len)));
    var out: std.ArrayList(CursorOption) = .empty;
    if (!bounds.contains(cursor)) return out.items;
    var length: usize = @min(8, bounds.len());
    while (length >= 1) : (length -= 1) {
        const first = @max(@as(i64, bounds.start), @as(i64, @intCast(cursor)) - @as(i64, @intCast(length)) + 1);
        const last = @min(@as(i64, @intCast(cursor)), @as(i64, bounds.end) - @as(i64, @intCast(length)));
        if (first <= last) {
            var start = first;
            while (start <= last) : (start += 1) {
                const span = Range.of(@intCast(start), @as(usize, @intCast(start)) + length);
                const words = try dec.segmentOptions(a, syllables, span, fuzzy, tone_tolerance);
                const keep = if (length == 1) words.len else @min(words.len, 4);
                for (words[0..keep]) |w| try out.append(a, .{ .text = w.text, .span = span, .score = w.score });
            }
        }
        if (length == 1) break;
    }
    return out.items;
}

test "session retains engine and frees refresh and selection allocations" {
    const a = std.testing.allocator;
    var threaded: Io.Threaded = .init_single_threaded;
    const dec = try Lexicon.create(a, &.{"ㄋㄧˇ\t你\t-5\nㄋㄧˇ\t妳\t-6\nㄏㄠˇ\t好\t-4\nㄋㄧˇ-ㄏㄠˇ\t你好\t-6\n"}, "");
    const engine = try Engine.create(a, threaded.io(), dec);
    const session = try Session.create(engine);
    defer session.destroy();
    engine.release(); // The session owns the remaining reference.
    for ("su3cl3") |key| {
        const label = [_]u8{key};
        _ = try session.handle(.{ .kind = .character, .label = &label, .text = &label, .timestamp = 1000 });
        _ = try session.view();
    }
    try std.testing.expectEqualStrings("你好", (try session.view()).preedit);
    _ = try session.handle(.{ .kind = .left, .timestamp = 1001 });
    _ = try session.view();
    try session.pick(0);
    _ = try session.handle(.{ .kind = .backspace, .timestamp = 1002 });
    _ = try session.commit();
    try std.testing.expectEqualStrings("", (try session.view()).preedit);
}

test "1000 sessions with cursor edits and commits release all memory" {
    const a = std.testing.allocator;
    var threaded: Io.Threaded = .init_single_threaded;
    const dec = try Lexicon.create(a, &.{"ㄋㄧˇ\t你\t-5\nㄋㄧˇ\t妳\t-6\nㄏㄠˇ\t好\t-4\nㄋㄧˇ-ㄏㄠˇ\t你好\t-6\n"}, "");
    const engine = try Engine.create(a, threaded.io(), dec);
    defer engine.release();
    engine.settings.auto_commit_syllables = 6;
    for (0..1000) |iteration| {
        const session = try Session.create(engine);
        defer session.destroy();
        const repeats: usize = if (iteration % 100 == 0) 64 else 2;
        for (0..repeats) |_| for ("su3cl3") |key| {
            const label = [_]u8{key};
            _ = try session.handle(.{ .kind = .character, .label = &label, .text = &label, .timestamp = @floatFromInt(iteration + 1000) });
            _ = try session.view();
        };
        _ = try session.handle(.{ .kind = .left, .timestamp = 2001 });
        try session.pick(0);
        _ = try session.handle(.{ .kind = .backspace, .timestamp = 2002 });
        _ = try session.commit();
        try std.testing.expectEqualStrings("", (try session.view()).preedit);
    }
}
