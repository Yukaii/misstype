//! misstype-dev: offline decode and session-trace CLI for the measurement
//! tools under tools/ (they used to drive the macOS app's `--decode`).
//!
//!   misstype-dev --decode KEYS [--align] [--segment A:B] [--lock=KEY=TEXT ...]
//!                [--user-lexicon PATH] [--replay EXPECTED [--learn-out PATH]]
//!   misstype-dev --session-trace KEYS [--auto-commit N] [--show] [--mixed-english]
//!                [--user-lexicon PATH] [--user-dictionary PATH] [--channel PATH]
//!
//! Resources (lexicon.tsv, local_phrases.tsv, toneless.tsv, english.tsv) come
//! from `--resources DIR`, else $MISSTYPE_RESOURCES, else the built app bundle
//! `dist/MisstypeIME.app/Contents/Resources`. Output formats are the ones the
//! Swift `--decode` / `--session-trace` printed. Learned state is read from
//! the given files and never written back.

const std = @import("std");
const core = @import("misstype");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const session_mod = core.session;
const Range = core.candidate.Range;

const default_bundle = "dist/MisstypeIME.app/Contents/Resources";

const Cli = struct {
    gpa: Allocator,
    io: Io,
    args: []const []const u8,
    out: *Io.Writer,

    fn flag(self: Cli, name: []const u8) bool {
        for (self.args) |a| if (std.mem.eql(u8, a, name)) return true;
        return false;
    }

    fn value(self: Cli, name: []const u8) ?[]const u8 {
        for (self.args, 0..) |a, i| {
            if (std.mem.eql(u8, a, name) and i + 1 < self.args.len) return self.args[i + 1];
        }
        return null;
    }

    fn read(self: Cli, path: []const u8) ?[]u8 {
        return core.storage.read(self.io, self.gpa, path);
    }

    fn resourceFile(self: Cli, dir: []const u8, name: []const u8) !?[]u8 {
        const path = try std.fs.path.join(self.gpa, &.{ dir, name });
        defer self.gpa.free(path);
        return self.read(path);
    }

    fn resourceDir(self: Cli) []const u8 {
        if (self.value("--resources")) |d| return d;
        if (std.c.getenv("MISSTYPE_RESOURCES")) |d| return std.mem.span(d);
        return default_bundle;
    }

    /// The shipping decoder, as LexiconLoader builds it.
    fn loadDecoder(self: Cli) !*core.Lexicon {
        const dir = self.resourceDir();
        const lexicon_tsv = (try self.resourceFile(dir, "lexicon.tsv")) orelse {
            std.debug.print("misstype-dev: no lexicon.tsv in {s} (set --resources or MISSTYPE_RESOURCES)\n", .{dir});
            std.process.exit(1);
        };
        defer self.gpa.free(lexicon_tsv);
        const supplement = (try self.resourceFile(dir, "local_phrases.tsv")) orelse try self.gpa.dupe(u8, "");
        defer self.gpa.free(supplement);
        const toneless = (try self.resourceFile(dir, "toneless.tsv")) orelse try self.gpa.dupe(u8, "");
        defer self.gpa.free(toneless);
        const lexicon = try core.Lexicon.create(self.gpa, &.{ lexicon_tsv, supplement }, toneless);
        lexicon.word_penalty = if (std.c.getenv("MISSTYPE_WORD_PENALTY")) |w|
            std.fmt.parseFloat(f64, std.mem.span(w)) catch 0.5
        else
            0.5;
        return lexicon;
    }

    fn print(self: Cli, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(fmt, args);
    }
};

/// The Swift dev tool's `compose`: a key string typed on the physical keys.
/// Backtick toggles a Latin run, an uppercase ASCII letter is inline Latin,
/// punctuation glyphs become literals, a tone with nothing pending retones.
fn compose(a: Allocator, keys: []const u8) !core.composition.Composition {
    var c: core.composition.Composition = .{};
    var latin = false;
    var it = (try std.unicode.Utf8View.init(keys)).iterator();
    while (it.nextCodepointSlice()) |label| {
        if (std.mem.eql(u8, label, "`")) {
            latin = !latin;
            continue;
        }
        if (std.mem.eql(u8, label, " ")) {
            if (!c.isEmpty()) _ = try c.appendSpace(a);
            continue;
        }
        const ascii = label.len == 1;
        if (latin and ascii and std.ascii.isAlphabetic(label[0])) {
            _ = try c.appendLatin(a, label);
            continue;
        }
        if (!latin and ascii and std.ascii.isUpper(label[0])) {
            _ = try c.appendLatin(a, label);
            continue;
        }
        latin = false;
        if (core.punctuation.isLiteral(label)) {
            _ = try c.appendLiteral(a, label);
        } else if (ascii) {
            if (!try c.append(a, label[0])) _ = try c.retoneLast(a, label[0]);
        }
    }
    return c;
}

fn decode(cli: Cli, keys: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(cli.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const started = Io.Timestamp.now(cli.io, .awake);
    const lexicon = try cli.loadDecoder();
    defer lexicon.destroy();
    const loaded = Io.Timestamp.now(cli.io, .awake);

    var user_lexicon: ?core.user_lexicon.UserLexicon = null;
    defer if (user_lexicon) |*u| u.deinit();
    if (cli.value("--user-lexicon")) |path| if (cli.read(path)) |data| {
        defer cli.gpa.free(data);
        user_lexicon = core.user_lexicon.UserLexicon.decode(cli.gpa, data) catch null;
    };
    var locked: core.user_lexicon.UserLexicon = .init(cli.gpa);
    defer locked.deinit();
    var any_lock = false;
    for (cli.args) |arg| {
        const prefix = "--lock=";
        if (!std.mem.startsWith(u8, arg, prefix)) continue;
        const pair = arg[prefix.len..];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (eq == 0 or eq + 1 >= pair.len) continue;
        try locked.setSingle(pair[0..eq], pair[eq + 1 ..], .{ .count = 1, .updated_at = 0 });
        any_lock = true;
    }

    const composition = try compose(a, keys);
    const parsed = try composition.parsed(a);
    const segments = try composition.segments(a);
    const results = try lexicon.decodeSegments(a, segments, parsed.pending, .{
        .user_lexicon = if (user_lexicon) |*u| u else null,
        .locked = if (any_lock) &locked else null,
    });
    const done = Io.Timestamp.now(cli.io, .awake);
    const ms = struct {
        fn of(from: Io.Timestamp, to: Io.Timestamp) f64 {
            return @as(f64, @floatFromInt(from.durationTo(to).nanoseconds)) / 1e6;
        }
    };
    try cli.print("entries={d} user={d} load_ms={d} decode_ms={d}\n", .{
        lexicon.entry_count, if (user_lexicon) |*u| u.count() else 0, ms.of(started, loaded), ms.of(loaded, done),
    });
    for (results) |candidate| {
        try cli.print("{s}\t", .{candidate.text});
        try writeDouble(cli, a, candidate.score);
        try cli.print("\trepairs={d} unresolved={d}", .{ candidate.repairs, candidate.unresolved });
        if (cli.flag("--align")) {
            try cli.print("\talign=", .{});
            for (candidate.alignment, 0..) |span, i| {
                try cli.print("{s}{d}-{d}:{d}-{d}", .{ if (i == 0) "" else ",", span.syllables.start, span.syllables.end, span.chars.start, span.chars.end });
            }
        }
        try cli.print("\n", .{});
    }
    if (cli.value("--segment")) |bounds| {
        var parts = std.mem.splitScalar(u8, bounds, ':');
        const lo = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch return;
        const hi = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch return;
        const syllables = parsed.complete; // Swift: syllables(finishing: true)
        var all: std.ArrayList(core.Syllable) = .empty;
        try all.appendSlice(a, syllables);
        if (parsed.pending.len > 0) try all.append(a, .{ .keys = parsed.pending, .tone = null });
        const query = Io.Timestamp.now(cli.io, .awake);
        const options = try lexicon.segmentOptions(a, all.items, Range.of(lo, hi), true, true);
        try cli.print("segment {d}:{d} query_ms={d}\n", .{ lo, hi, ms.of(query, Io.Timestamp.now(cli.io, .awake)) });
        for (options[0..@min(options.len, 8)]) |option| {
            try cli.print("  {s}\t", .{option.text});
            try writeDouble(cli, a, option.score);
            try cli.print("\n", .{});
        }
    }
    if (cli.value("--replay")) |expected| try replay(cli, a, lexicon, composition, expected, if (user_lexicon) |*u| u else null);
}

// MARK: - Cursor replay (tools/cursor_replay.py)

const Model = enum { aligned, start_at_cursor };

const Outcome = struct {
    picks: ?usize,
    ranks: []const usize,
    learned: []const []const u8,
};

/// Walks to the first wrong character, takes the longest option that matches
/// `expected` there, pins it, and re-decodes. Needs a 1:1 syllable/character
/// alignment (pure Zhuyin runs); anything else is unreachable.
fn replayRun(lexicon: *const core.Lexicon, a: Allocator, segments: []const core.composition.Segment, pending: []const u8, expected: []const u8, model: Model, user_lexicon: ?*const core.user_lexicon.UserLexicon) !Outcome {
    const max_picks = 6;
    const target = try core.unicode.characters(a, expected);
    var pins: core.user_lexicon.UserLexicon = .init(a);
    var ranks: std.ArrayList(usize) = .empty;
    for (0..max_picks + 1) |_| {
        const locked: ?*const core.user_lexicon.UserLexicon = if (pins.isEmpty()) null else &pins;
        const decoded = try lexicon.decodeSegments(a, segments, pending, .{ .user_lexicon = user_lexicon, .locked = locked });
        if (decoded.len == 0) break;
        const top = decoded[0];
        const text = try core.unicode.characters(a, top.text);
        if (text.len == target.len and for (text, target) |x, y| {
            if (!std.mem.eql(u8, x, y)) break false;
        } else true) {
            const learned: []const []const u8 = blk: {
                if (ranks.items.len == 0) break :blk &.{};
                var out: std.ArrayList([]const u8) = .empty;
                for (try core.user_lexicon.learnedWords(a, top, &pins, null)) |w| {
                    try out.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ w.key, w.text }));
                }
                break :blk out.items;
            };
            return .{ .picks = ranks.items.len, .ranks = ranks.items, .learned = learned };
        }
        if (ranks.items.len >= max_picks or top.unresolved != 0 or text.len != top.syllables.len or target.len != top.syllables.len) break;
        const c = for (text, target, 0..) |x, y, i| {
            if (!std.mem.eql(u8, x, y)) break i;
        } else break;
        const options: []const core.candidate.CursorOption = switch (model) {
            .start_at_cursor => try session_mod.cursorOptions(lexicon, a, top.syllables, c, top.run(c), true, true),
            .aligned => blk: {
                var aligned: std.ArrayList(core.candidate.CursorOption) = .empty;
                for (top.alignment) |word| if (word.syllables.contains(c)) {
                    for (try lexicon.segmentOptions(a, top.syllables, word.syllables, true, true)) |o| {
                        try aligned.append(a, .{ .text = o.text, .span = word.syllables, .score = o.score });
                    }
                    break;
                };
                const single = Range.of(c, c + 1);
                if (aligned.items.len == 0 or !aligned.items[0].span.eql(single)) {
                    for (try lexicon.segmentOptions(a, top.syllables, single, true, true)) |o| {
                        try aligned.append(a, .{ .text = o.text, .span = single, .score = o.score });
                    }
                }
                break :blk aligned.items;
            },
        };
        var best: ?usize = null;
        for (options, 0..) |option, index| {
            if (!option.span.contains(c)) continue;
            const wanted = try std.mem.concat(a, u8, target[option.span.start..option.span.end]);
            if (!std.mem.eql(u8, wanted, option.text)) continue;
            if (best == null or option.span.len() > options[best.?].span.len()) best = index;
        }
        const pick = best orelse break;
        try pins.pin(options[pick], top);
        try ranks.append(a, pick);
    }
    return .{ .picks = null, .ranks = ranks.items, .learned = &.{} };
}

fn replay(cli: Cli, a: Allocator, lexicon: *const core.Lexicon, composition: core.composition.Composition, expected: []const u8, user_lexicon: ?*const core.user_lexicon.UserLexicon) !void {
    const parsed = try composition.parsed(a);
    const cut = try lexicon.livePendingCut(a, parsed.pending, true);
    const segments = try composition.segments(a);
    for ([_]Model{ .aligned, .start_at_cursor }) |model| {
        const outcome = try replayRun(lexicon, a, segments, parsed.pending[0..cut], expected, model, user_lexicon);
        try cli.print("replay {s} picks=", .{if (model == .aligned) "aligned" else "startAtCursor"});
        if (outcome.picks) |n| try cli.print("{d}", .{n}) else try cli.print("-", .{});
        try cli.print(" ranks=", .{});
        for (outcome.ranks, 0..) |r, i| try cli.print("{s}{d}", .{ if (i == 0) "" else ",", r });
        try cli.print(" learned=", .{});
        for (outcome.learned, 0..) |l, i| try cli.print("{s}{s}", .{ if (i == 0) "" else ",", l });
        try cli.print("\n", .{});
        // --learn-out PATH: commit the covering-model outcome's words into a
        // (synthetic) lexicon file, as the IME would on Return.
        if (model == .start_at_cursor and outcome.learned.len > 0) {
            const path = cli.value("--learn-out") orelse continue;
            var learned: core.user_lexicon.UserLexicon = if (cli.read(path)) |data| blk: {
                defer cli.gpa.free(data);
                break :blk core.user_lexicon.UserLexicon.decode(a, data) catch .init(a);
            } else .init(a);
            for (outcome.learned) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                try learned.record(pair[0..eq], pair[eq + 1 ..], 0);
            }
            _ = core.storage.writeAtomic(cli.io, a, path, try learned.encode(a));
        }
    }
}

fn writeDouble(cli: Cli, a: Allocator, value: f64) !void {
    var buf: std.ArrayList(u8) = .empty;
    try core.user_dictionary.appendSwiftDouble(&buf, a, value);
    try cli.out.writeAll(buf.items);
}

// MARK: - Session trace

const Named = struct { []const u8, session_mod.KeyKind, u32 };
const named_keys = [_]Named{
    .{ "⌫", .backspace, 0 },
    .{ "⏎", .enter, 0 },
    .{ "←", .left, 0 },
    .{ "→", .right, 0 },
    .{ "↑", .up, 0 },
    .{ "↓", .down, 0 },
    .{ "⇥", .tab, 0 },
    .{ "⎋", .escape, 0 },
    .{ "⌦", .forward_delete, 0 },
    // Option word editing: ⇠ ⇢ Option+Left/Right, ⌧ Option+Backspace.
    .{ "⇠", .left, session_mod.mod_option },
    .{ "⇢", .right, session_mod.mod_option },
    .{ "⌧", .backspace, session_mod.mod_option },
};

fn trace(cli: Cli, keys: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(cli.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const decoder = try cli.loadDecoder();
    const engine = try session_mod.Engine.create(cli.gpa, cli.io, decoder);
    defer engine.release();
    const dir = cli.resourceDir();
    if (try cli.resourceFile(dir, "english.tsv")) |tsv| {
        defer cli.gpa.free(tsv);
        engine.english_lexicon = try core.english.EnglishLexicon.create(cli.gpa, tsv);
    }
    // The macOS preference defaults, which the Swift trace read.
    engine.settings = .{
        .auto_show_candidates = false,
        .return_confirms_selection = true,
        .mixed_english = cli.flag("--mixed-english"),
    };
    if (cli.value("--auto-commit")) |n| engine.settings.auto_commit_syllables = std.fmt.parseInt(usize, n, 10) catch 24;
    if (cli.value("--user-lexicon")) |path| if (cli.read(path)) |data| {
        defer cli.gpa.free(data);
        engine.user_lexicon.deinit();
        engine.user_lexicon = core.user_lexicon.UserLexicon.decode(cli.gpa, data) catch .init(cli.gpa);
    };
    if (cli.value("--user-dictionary")) |path| if (cli.read(path)) |data| {
        defer cli.gpa.free(data);
        try engine.setUserDictionary(try core.user_dictionary.UserDictionary.parse(cli.gpa, data, null), false);
    };
    if (cli.value("--channel")) |path| if (cli.read(path)) |data| {
        defer cli.gpa.free(data);
        engine.channel_learner.deinit();
        engine.channel_learner = core.channel.ChannelLearner.decode(cli.gpa, data) catch .init(cli.gpa);
    };
    const session = try session_mod.Session.create(engine);
    defer session.destroy();

    var committed: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var it = (try std.unicode.Utf8View.init(keys)).iterator();
    while (it.nextCodepointSlice()) |label| {
        count += 1;
        var event: session_mod.KeyEvent = .{ .kind = .character, .label = label, .text = label };
        if (std.mem.eql(u8, label, " ")) {
            event = .{ .kind = .space, .text = " " };
        } else for (named_keys) |n| if (std.mem.eql(u8, n[0], label)) {
            event = .{ .kind = n[1], .mods = n[2] };
        };
        const started = Io.Timestamp.now(cli.io, .awake);
        const result = try session.handle(event);
        const ms = @as(f64, @floatFromInt(started.durationTo(Io.Timestamp.now(cli.io, .awake)).nanoseconds)) / 1e6;
        try cli.print("time\t{d}\t{d:.1}\n", .{ count, ms });
        const view = try session.view();
        if (cli.flag("--show")) {
            try cli.print("view\t{d}\t{s}\n", .{ count, try withCursor(a, view.preedit, view.caret) });
        }
        if (result.commit) |text| {
            try committed.appendSlice(a, text);
            try cli.print("chunk\t{d}\t{s}\tpreedit={s}\n", .{ count, text, view.preedit });
        }
    }
    const rest = (try session.handle(.{ .kind = .enter, .text = "\r" })).commit orelse "";
    try committed.appendSlice(a, rest);
    try cli.print("final\t{s}\n", .{committed.items});
}

/// `text` with a `|` at a UTF-16 caret offset (clamped).
fn withCursor(a: Allocator, text: []const u8, caret: u32) ![]const u8 {
    var units: u32 = 0;
    var at: usize = text.len;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    var start: usize = 0;
    while (it.nextCodepointSlice()) |cp| {
        if (units >= caret) {
            at = start;
            break;
        }
        units += if (cp.len == 4) 2 else 1;
        start += cp.len;
    }
    return std.mem.concat(a, u8, &.{ text[0..at], "|", text[at..] });
}

pub fn main(init: std.process.Init) !void {
    var out_buf: [8192]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cli: Cli = .{ .gpa = init.gpa, .io = init.io, .args = args[1..], .out = &out_file.interface };
    if (cli.value("--decode")) |keys| {
        try decode(cli, keys);
    } else if (cli.value("--session-trace")) |keys| {
        try trace(cli, keys);
    } else {
        std.debug.print("usage: misstype-dev --decode KEYS | --session-trace KEYS  (see the header of core-zig/src/dev.zig)\n", .{});
        std.process.exit(2);
    }
    try out_file.interface.flush();
}
