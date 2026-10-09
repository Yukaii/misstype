//! User key bindings for IME actions (port of
//! Sources/MisstypeCore/KeyBindings.swift). A bound chord is rewritten to
//! its action's canonical event before the session sees it, so the editing
//! rules stay keyed on one set of keys.
//!
//! Text form, one action per line, `#` comments:
//!     nextCandidate = tab, ctrl+n
//!     latinRun =

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Event kinds a chord can name (a subset of session.KeyKind).
pub const Key = union(enum) {
    /// Printable key by its US-ANSI unshifted label (one byte).
    character: u8,
    space,
    enter,
    tab,
    escape,
    left,
    right,
    up,
    down,
    page_up,
    page_down,
    /// Any key a chord can never name (backspace, shift alone, ...).
    other,

    fn eql(a: Key, b: Key) bool {
        return switch (a) {
            .character => |x| switch (b) {
                .character => |y| x == y,
                else => false,
            },
            .space => b == .space,
            .enter => b == .enter,
            .tab => b == .tab,
            .escape => b == .escape,
            .left => b == .left,
            .right => b == .right,
            .up => b == .up,
            .down => b == .down,
            .page_up => b == .page_up,
            .page_down => b == .page_down,
            .other => b == .other,
        };
    }
};

pub const shift: u32 = 1 << 0;
pub const control: u32 = 1 << 1;
pub const option: u32 = 1 << 2;
pub const command: u32 = 1 << 3;
pub const caps_lock: u32 = 1 << 4;
const chord_mods = control | option | shift | command;

pub const Chord = struct {
    key: Key,
    mods: u32 = 0,

    pub fn init(key: Key, mods: u32) Chord {
        return .{ .key = key, .mods = mods & chord_mods };
    }

    pub fn eql(a: Chord, b: Chord) bool {
        return a.key.eql(b.key) and a.mods == b.mods;
    }

    /// Keys a binding may use: named navigation keys, or a printable key
    /// (unshifted US glyph) with Control, Option or Command.
    pub fn isBindable(self: Chord) bool {
        return switch (self.key) {
            .character => |c| isUnshiftedGlyph(c) and self.mods & (control | option | command) != 0,
            .space, .enter, .tab, .escape, .left, .right, .up, .down, .page_up, .page_down => true,
            .other => false,
        };
    }

    /// Parses the text form; null for anything unknown or not bindable.
    pub fn parse(text: []const u8) ?Chord {
        var buf: [64]u8 = undefined;
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len > buf.len) return null;
        const lower = std.ascii.lowerString(&buf, trimmed);
        var parts = std.mem.splitScalar(u8, lower, '+');
        var names: [8][]const u8 = undefined;
        var n: usize = 0;
        while (parts.next()) |p| {
            if (n == names.len) return null;
            names[n] = p;
            n += 1;
        }
        const last = names[n - 1];
        if (last.len == 0) return null;
        var mods: u32 = 0;
        for (names[0 .. n - 1]) |part| {
            mods |= modifierNamed(part) orelse return null;
        }
        const key: Key = if (keyNamed(last)) |k|
            k
        else if (std.mem.eql(u8, last, "comma"))
            .{ .character = ',' }
        else if (std.unicode.utf8CountCodepoints(last) catch 0 == 1)
            (if (last.len == 1) Key{ .character = last[0] } else return null)
        else
            return null;
        const chord = Chord.init(key, mods);
        return if (chord.isBindable()) chord else null;
    }
};

fn isUnshiftedGlyph(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or std.mem.indexOfScalar(u8, "-=[];'`\\,./", c) != null;
}

fn modifierNamed(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "ctrl")) return control;
    if (std.mem.eql(u8, name, "alt")) return option;
    if (std.mem.eql(u8, name, "shift")) return shift;
    if (std.mem.eql(u8, name, "cmd")) return command;
    return null;
}

fn keyNamed(name: []const u8) ?Key {
    const table = [_]struct { []const u8, Key }{
        .{ "space", .space },    .{ "enter", .enter },        .{ "tab", .tab }, .{ "escape", .escape },
        .{ "left", .left },      .{ "right", .right },        .{ "up", .up },   .{ "down", .down },
        .{ "pageup", .page_up }, .{ "pagedown", .page_down },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], name)) return entry[1];
    return null;
}

pub const Action = enum {
    toggleEnglish,
    nextCandidate,
    previousCandidate,
    nextPage,
    previousPage,
    cursorBack,
    cursorForward,
    markBack,
    markForward,
    commit,
    commitRaw,
    cancel,
    latinRun,

    /// The event the session acts on.
    pub fn canonical(self: Action) Chord {
        return switch (self) {
            .toggleEnglish => Chord.init(.space, shift),
            .nextCandidate => Chord.init(.down, 0),
            .previousCandidate => Chord.init(.up, 0),
            .nextPage => Chord.init(.page_down, 0),
            .previousPage => Chord.init(.page_up, 0),
            .cursorBack => Chord.init(.left, 0),
            .cursorForward => Chord.init(.right, 0),
            .markBack => Chord.init(.left, shift),
            .markForward => Chord.init(.right, shift),
            .commit => Chord.init(.enter, 0),
            .commitRaw => Chord.init(.enter, shift),
            .cancel => Chord.init(.escape, 0),
            .latinRun => Chord.init(.{ .character = '`' }, 0),
        };
    }

    /// Chords that trigger the action out of the box.
    pub fn defaultChords(self: Action) []const Chord {
        return switch (self) {
            .nextPage => &default_next_page,
            .previousPage => &default_previous_page,
            .toggleEnglish => &default_toggle,
            .nextCandidate => &default_next,
            .previousCandidate => &default_previous,
            .cursorBack => &default_cursor_back,
            .cursorForward => &default_cursor_forward,
            .markBack => &default_mark_back,
            .markForward => &default_mark_forward,
            .commit => &default_commit,
            .commitRaw => &default_commit_raw,
            .cancel => &default_cancel,
            .latinRun => &default_latin,
        };
    }

    /// Text the canonical event carries.
    pub fn canonicalText(self: Action) ?[]const u8 {
        return switch (self) {
            .toggleEnglish => " ",
            .commit, .commitRaw => "\r",
            .cancel => "\x1b",
            .latinRun => "`",
            else => null,
        };
    }

    fn named(name: []const u8) ?Action {
        return std.meta.stringToEnum(Action, name);
    }
};

const default_toggle = [_]Chord{Chord.init(.space, shift)};
const default_next = [_]Chord{Chord.init(.down, 0)};
const default_previous = [_]Chord{Chord.init(.up, 0)};
const default_next_page = [_]Chord{ Chord.init(.tab, 0), Chord.init(.page_down, 0) };
const default_previous_page = [_]Chord{ Chord.init(.tab, shift), Chord.init(.page_up, 0) };
const default_cursor_back = [_]Chord{Chord.init(.left, 0)};
const default_cursor_forward = [_]Chord{Chord.init(.right, 0)};
const default_mark_back = [_]Chord{Chord.init(.left, shift)};
const default_mark_forward = [_]Chord{Chord.init(.right, shift)};
const default_commit = [_]Chord{Chord.init(.enter, 0)};
const default_commit_raw = [_]Chord{Chord.init(.enter, shift)};
const default_cancel = [_]Chord{Chord.init(.escape, 0)};
const default_latin = [_]Chord{Chord.init(.{ .character = '`' }, 0)};

const action_count = @typeInfo(Action).@"enum".field_names.len;

pub const Resolution = union(enum) {
    /// Not a binding: the session handles the event as it is.
    unchanged,
    /// Bound: the session handles this canonical chord (and text) instead;
    /// `extra_mods` carries the event's Caps Lock.
    rewritten: struct { chord: Chord, text: ?[]const u8, extra_mods: u32 },
    /// Shift+Space with the 中/英 toggle unbound: the same event without
    /// Shift (a plain Space, text kept).
    strip_shift,
    /// A default chord the user removed: the key goes to the application.
    unbound,
};

/// The user's bindings: per action, the defaults or an explicit list
/// (empty = unbound). Chords live in fixed storage, so the struct copies.
pub const Bindings = struct {
    overridden: [action_count]bool = @splat(false),
    chords: [action_count][8]Chord = undefined,
    counts: [action_count]u8 = @splat(0),

    pub fn chordsFor(self: *const Bindings, action: Action) []const Chord {
        const i = @backingInt(action);
        return if (self.overridden[i]) self.chords[i][0..self.counts[i]] else action.defaultChords();
    }

    /// Chord -> action. Explicit bindings win over defaults; among equals
    /// the first action wins.
    pub fn lookup(self: *const Bindings, chord: Chord) ?Action {
        for (0..action_count) |i| {
            if (!self.overridden[i]) continue;
            for (self.chords[i][0..self.counts[i]]) |c| if (c.eql(chord)) return @fromBackingInt(@intCast(i));
        }
        for (0..action_count) |i| {
            if (self.overridden[i]) continue;
            for (@as(Action, @fromBackingInt(@intCast(i))).defaultChords()) |c| if (c.eql(chord)) return @fromBackingInt(@intCast(i));
        }
        return null;
    }

    pub fn resolve(self: *const Bindings, key: Key, mods: u32, release: bool) Resolution {
        if (release) return .unchanged;
        const chord = Chord.init(key, mods);
        if (self.lookup(chord)) |action| {
            if (chord.eql(action.canonical())) return .unchanged;
            return .{ .rewritten = .{ .chord = action.canonical(), .text = action.canonicalText(), .extra_mods = mods & caps_lock } };
        }
        // A default chord the user removed.
        const r = defaultOwner(chord) orelse return .unchanged;
        // Without its toggle binding Shift+Space is a plain Space.
        if (r == .toggleEnglish) return .strip_shift;
        return .unbound;
    }

    /// The first action whose defaults include `chord`.
    fn defaultOwner(chord: Chord) ?Action {
        for (0..action_count) |i| {
            const a: Action = @fromBackingInt(@intCast(i));
            for (a.defaultChords()) |c| if (c.eql(chord)) return a;
        }
        return null;
    }

    /// Unknown actions and chords are skipped, never fatal; a later line
    /// for the same action replaces an earlier one.
    pub fn parse(text: []const u8) Bindings {
        var out: Bindings = .{};
        var lines = std.mem.splitAny(u8, text, "\n\r\u{0B}\u{0C}");
        while (lines.next()) |line| {
            const body = if (std.mem.indexOfScalar(u8, line, '#')) |i| line[0..i] else line;
            const eq = std.mem.indexOfScalar(u8, body, '=') orelse continue;
            const action = Action.named(std.mem.trim(u8, body[0..eq], " \t")) orelse continue;
            const i = @backingInt(action);
            out.overridden[i] = true;
            out.counts[i] = 0;
            var items = std.mem.tokenizeScalar(u8, body[eq + 1 ..], ',');
            while (items.next()) |item| {
                const chord = Chord.parse(item) orelse continue;
                const existing = out.chords[i][0..out.counts[i]];
                const dup = for (existing) |c| {
                    if (c.eql(chord)) break true;
                } else false;
                if (dup or out.counts[i] == 8) continue;
                out.chords[i][out.counts[i]] = chord;
                out.counts[i] += 1;
            }
        }
        return out;
    }
};

const testing = std.testing;

test "defaults rewrite Tab to PageDown and keep canonical keys" {
    const b: Bindings = .{};
    const tab = b.resolve(.tab, 0, false);
    try testing.expect(tab == .rewritten);
    try testing.expect(tab.rewritten.chord.key == .page_down);
    try testing.expect(b.resolve(.down, 0, false) == .unchanged);
    try testing.expect(b.resolve(.{ .character = 'a' }, control, false) == .unchanged);
}

test "overrides, unbinding and Shift+Space" {
    const b = Bindings.parse("nextCandidate = tab, ctrl+n\nlatinRun =\ntoggleEnglish =  # gone\nbogus = ctrl+x");
    const n = b.resolve(.{ .character = 'n' }, control, false);
    try testing.expect(n == .rewritten and n.rewritten.chord.key == .down);
    // Tab is now nextCandidate (explicit wins over nextPage's default).
    try testing.expect(b.resolve(.tab, 0, false).rewritten.chord.key == .down);
    try testing.expect(b.resolve(.{ .character = '`' }, 0, false) == .unbound);
    try testing.expect(b.resolve(.space, shift, false) == .strip_shift);
    try testing.expect(Chord.parse("A") == null); // printable needs a modifier
    try testing.expect(Chord.parse("Ctrl+Comma").?.key.character == ',');
}
