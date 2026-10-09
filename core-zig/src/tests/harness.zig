//! Shared fixture for the behavior suites ported from the Swift
//! `MisstypeCoreTests` (docs/zig-port.md, "Retiring the Swift core").
//! A `Harness` owns one engine and one session over an inline lexicon, so a
//! test reads like the Swift original: build, type keys, assert on the view.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const session_mod = @import("../session.zig");
const lexicon_mod = @import("../lexicon.zig");
const candidate_mod = @import("../candidate.zig");

pub const Engine = session_mod.Engine;
pub const Session = session_mod.Session;
pub const KeyEvent = session_mod.KeyEvent;
pub const KeyKind = session_mod.KeyKind;
pub const View = session_mod.View;
pub const Range = candidate_mod.Range;
pub const shift = session_mod.mod_shift;
pub const control = session_mod.mod_control;
pub const command = session_mod.mod_command;
pub const caps_lock = session_mod.mod_caps_lock;

/// A key result with its commit text copied out of the session's arena, so it
/// survives the next call.
pub const Res = struct {
    consumed: bool,
    commit: ?[]const u8 = null,
    beep: bool = false,
    mode_changed: bool = false,
    latin_toggled: bool = false,
};

/// Zig multiline strings cannot hold a tab, so lexicon literals write `|`
/// where the TSV has one.
pub fn tsv(comptime text: []const u8) []const u8 {
    comptime {
        var out: [text.len]u8 = undefined;
        for (text, 0..) |c, i| out[i] = if (c == '|') '\t' else c;
        const final = out;
        return &final;
    }
}

/// The lexicon most session tests share.
pub const nihao = tsv(
    \\ㄋㄧˇ|你|-5
    \\ㄋㄧˇ|妳|-6
    \\ㄋㄧˇ|尼|-7
    \\ㄋㄧˇ|泥|-8
    \\ㄏㄠˇ|好|-5
    \\ㄋㄧˇ-ㄏㄠˇ|你好|-3
    \\ㄇㄚ˙|嗎|-4
    \\
);

pub const Harness = struct {
    gpa: Allocator,
    threaded: Io.Threaded,
    engine: *Engine,
    session: *Session,
    /// Copies handed to the test (commits, result slices); freed in deinit.
    scratch: std.heap.ArenaAllocator,

    pub fn init(rows: []const u8) !*Harness {
        const gpa = std.testing.allocator;
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .threaded = .init_single_threaded,
            .engine = undefined,
            .session = undefined,
            .scratch = .init(gpa),
        };
        const decoder = try lexicon_mod.Lexicon.create(gpa, &.{rows}, "");
        self.engine = try Engine.create(gpa, self.threaded.io(), decoder);
        errdefer self.engine.release();
        self.session = try Session.create(self.engine);
        self.engine.release(); // The session owns the remaining reference.
        return self;
    }

    pub fn deinit(self: *Harness) void {
        self.session.destroy();
        self.scratch.deinit();
        self.gpa.destroy(self);
    }

    /// The engine settings the next key event is handled with.
    pub fn settings(self: *Harness) *session_mod.Settings {
        return &self.engine.settings;
    }

    pub fn send(self: *Harness, event: KeyEvent) !Res {
        const r = try self.session.handle(event);
        return .{
            .consumed = r.consumed,
            .commit = if (r.commit) |c| try self.scratch.allocator().dupe(u8, c) else null,
            .beep = r.beep,
            .mode_changed = r.mode_changed,
            .latin_toggled = r.latin_toggled,
        };
    }

    /// A named key (arrows, Return, ...).
    pub fn key(self: *Harness, kind: KeyKind, mods: u32, text: ?[]const u8) !Res {
        return self.send(.{ .kind = kind, .mods = mods, .text = text });
    }

    /// A character key: `label` is the US-ANSI unshifted label.
    pub fn chr(self: *Harness, label: []const u8, mods: u32, text: ?[]const u8) !Res {
        return self.send(.{ .kind = .character, .label = label, .mods = mods, .text = text });
    }

    pub fn enter(self: *Harness) !Res {
        return self.key(.enter, 0, "\r");
    }
    pub fn backspace(self: *Harness) !Res {
        return self.key(.backspace, 0, "\x7f");
    }
    pub fn escape(self: *Harness) !Res {
        return self.key(.escape, 0, "\x1b");
    }
    pub fn tab(self: *Harness) !Res {
        return self.key(.tab, 0, "\t");
    }
    pub fn down(self: *Harness) !Res {
        return self.key(.down, 0, null);
    }
    pub fn up(self: *Harness) !Res {
        return self.key(.up, 0, null);
    }
    pub fn left(self: *Harness) !Res {
        return self.key(.left, 0, null);
    }
    pub fn right(self: *Harness) !Res {
        return self.key(.right, 0, null);
    }
    pub fn space(self: *Harness) !Res {
        return self.key(.space, 0, " ");
    }

    /// Plain typing on the physical keys: letters, digits, punctuation, space.
    pub fn typeKeys(self: *Harness, keys: []const u8) ![]const Res {
        var out: std.ArrayList(Res) = .empty;
        for (keys, 0..) |_, i| {
            const label = keys[i .. i + 1];
            out.append(self.scratch.allocator(), if (label[0] == ' ')
                try self.space()
            else
                try self.chr(label, 0, label)) catch return error.OutOfMemory;
        }
        return out.items;
    }

    /// Types and discards the results.
    pub fn typed(self: *Harness, keys: []const u8) !void {
        _ = try self.typeKeys(keys);
    }

    pub fn view(self: *Harness) !View {
        return self.session.view();
    }

    pub fn preedit(self: *Harness) ![]const u8 {
        return (try self.view()).preedit;
    }

    pub fn raw(self: *Harness) ![]const u8 {
        return self.session.rawPhonetic();
    }

    /// Lone-Shift tap at `time` (press then release 0.1 s later).
    pub fn tapShift(self: *Harness, time: f64) !Res {
        _ = try self.send(.{ .kind = .shift_left, .mods = shift, .timestamp = time });
        return self.send(.{ .kind = .shift_left, .release = true, .timestamp = time + 0.1 });
    }

    pub fn expectPreedit(self: *Harness, want: []const u8) !void {
        try std.testing.expectEqualStrings(want, try self.preedit());
    }

    pub fn expectRaw(self: *Harness, want: []const u8) !void {
        try std.testing.expectEqualStrings(want, try self.raw());
    }

    pub fn expectCandidates(self: *Harness, want: []const []const u8) !void {
        const got = (try self.view()).candidates;
        try std.testing.expectEqual(want.len, got.len);
        for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    }
};

pub fn expectRes(want: Res, got: Res) !void {
    try std.testing.expectEqual(want.consumed, got.consumed);
    if (want.commit) |w| {
        try std.testing.expect(got.commit != null);
        try std.testing.expectEqualStrings(w, got.commit.?);
    } else try std.testing.expect(got.commit == null);
    try std.testing.expectEqual(want.beep, got.beep);
    try std.testing.expectEqual(want.mode_changed, got.mode_changed);
    try std.testing.expectEqual(want.latin_toggled, got.latin_toggled);
}

/// Rows `ㄋㄧˇ<TAB><char><TAB>-(5+i)` for each character of `chars`.
pub fn homophones(a: Allocator, reading: []const u8, chars: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (chars, 0..) |c, i| {
        try out.print(a, "{s}\t{s}\t-{d}\n", .{ reading, c, 5 + i });
    }
    return out.toOwnedSlice(a);
}

pub const ten_ni = [_][]const u8{ "你", "妳", "尼", "泥", "擬", "逆", "匿", "膩", "溺", "暱" };
