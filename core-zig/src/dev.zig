//! misstype-dev: offline decode and session-trace CLI for the measurement
//! tools under tools/ (they used to drive the macOS app's `--decode`).
//!
//!   misstype-dev --decode KEYS [--align] [--segment A:B] [--lock=KEY=TEXT ...]
//!                [--user-lexicon PATH] [--replay EXPECTED [--learn-out PATH]]
//!   misstype-dev --session-trace KEYS [--auto-commit N] [--show] [--mixed-english]
//!                [--user-lexicon PATH] [--user-dictionary PATH] [--channel PATH]
//!   misstype-dev --session-batch FILE|- [--carry] [same trace flags]
//!   misstype-dev --build-mode     (Debug, ReleaseFast, ...: latency is only
//!                                  meaningful from an optimized build)
//!
//! Trace keys are physical key labels; `⇧` is a lone Shift tap and
//! `，。？！：` are Shift+punctuation (see `traceEvents`).
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
        // Optional homophone word-bigram table (binary).
        const homophone_path = try std.fs.path.join(self.gpa, &.{ dir, "homophone.bin" });
        defer self.gpa.free(homophone_path);
        if (core.storage.readBytes(self.io, self.gpa, homophone_path)) |bytes| {
            defer self.gpa.free(bytes);
            if (std.c.getenv("MISSTYPE_NO_HOMOPHONE") == null) lexicon.setHomophoneTable(bytes) catch {
                std.debug.print("misstype-dev: ignoring malformed homophone.bin\n", .{});
            };
            if (std.c.getenv("MISSTYPE_HOMOPHONE_WEIGHT")) |w|
                lexicon.homophone_weight = std.fmt.parseFloat(f64, std.mem.span(w)) catch lexicon.homophone_weight;
            if (std.c.getenv("MISSTYPE_TONELESS_SEGMENT_WEIGHT")) |w|
                lexicon.toneless_segment_weight = std.fmt.parseFloat(f64, std.mem.span(w)) catch lexicon.toneless_segment_weight;
            if (std.c.getenv("MISSTYPE_TONELESS_HOMOPHONE_WEIGHT")) |w|
                lexicon.toneless_homophone_weight = std.fmt.parseFloat(f64, std.mem.span(w)) catch lexicon.toneless_homophone_weight;
        }
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

/// Shift-held glyphs a trace may name directly: the key typed with Shift.
var lower_buf: [1]u8 = undefined;

const shifted_glyphs = [_]struct { []const u8, []const u8 }{
    .{ "，", "," },
    .{ "。", "." },
    .{ "？", "/" },
    .{ "！", "1" },
    .{ "：", ";" },
};

/// The key events one trace label stands for. `⇧` is a lone Shift tap
/// (press, release); `，。？！：` are Shift+punctuation keys; everything
/// else is one event (an uppercase letter is Shift + its key).
/// Every event carries the trace's simulated clock (`now`), so Shift-tap
/// timing never mixes it with the host clock.
fn traceEvents(label: []const u8, now: f64, buf: *[2]session_mod.KeyEvent) []const session_mod.KeyEvent {
    if (std.mem.eql(u8, label, "⇧")) {
        buf[0] = .{ .kind = .shift_left, .mods = session_mod.mod_shift, .timestamp = now };
        buf[1] = .{ .kind = .shift_left, .release = true, .timestamp = now + 0.05 };
        return buf[0..2];
    }
    buf[0] = .{ .kind = .character, .label = label, .text = label };
    if (std.mem.eql(u8, label, " ")) {
        buf[0] = .{ .kind = .space, .text = " " };
    } else for (named_keys) |n| {
        if (std.mem.eql(u8, n[0], label)) buf[0] = .{ .kind = n[1], .mods = n[2] };
    }
    for (shifted_glyphs) |g| {
        if (std.mem.eql(u8, g[0], label)) buf[0] = .{ .kind = .character, .label = g[1], .text = g[1], .mods = session_mod.mod_shift };
    }
    // An uppercase letter is Shift + the letter key, as the adapters send it
    // (label from the key code, text from the characters).
    if (label.len == 1 and std.ascii.isUpper(label[0])) {
        const lower = std.ascii.lowerString(&lower_buf, label);
        buf[0] = .{ .kind = .character, .label = lower, .text = label, .mods = session_mod.mod_shift };
    }
    buf[0].timestamp = now;
    return buf[0..1];
}

const Typed = struct {
    committed: std.ArrayList(u8) = .empty,
    /// Wall time of each label's events, ms.
    ms: std.ArrayList(f64) = .empty,
    /// Preedit (with `|` at the caret) after each label.
    views: std.ArrayList([]const u8) = .empty,
    chunks: usize = 0,
    /// Committed + preedit before any correction.
    before_fix: []const u8 = "",
    picks: usize = 0,
    fix_keys: usize = 0,
    unreachable_fix: bool = false,
    committed_during_fix: bool = false,
    arena: Allocator = undefined,
};

/// Type `keys` into `session`, then (with `expected`) let `correct` fix
/// the composition with the panel, then Return. `trace_out` prints the
/// `--session-trace` lines as it goes.
fn typeKeys(cli: Cli, a: Allocator, session: *session_mod.Session, keys: []const u8, keep_views: bool, trace_out: bool, expected: ?[]const u8) !Typed {
    var typed: Typed = .{ .arena = a };
    var count: usize = 0;
    var clock: f64 = 1000;
    var it = (try std.unicode.Utf8View.init(keys)).iterator();
    while (it.nextCodepointSlice()) |label| {
        count += 1;
        clock += 0.2;
        var buf: [2]session_mod.KeyEvent = undefined;
        const started = Io.Timestamp.now(cli.io, .awake);
        var commit: ?[]const u8 = null;
        for (traceEvents(label, clock, &buf)) |event| {
            const result = try session.handle(event);
            if (result.commit) |text| commit = try a.dupe(u8, text);
        }
        const ms = @as(f64, @floatFromInt(started.durationTo(Io.Timestamp.now(cli.io, .awake)).nanoseconds)) / 1e6;
        try typed.ms.append(a, ms);
        if (trace_out) try cli.print("time\t{d}\t{d:.1}\n", .{ count, ms });
        const view = try session.view();
        const shown = try withCursor(a, view.preedit, view.caret);
        if (keep_views) try typed.views.append(a, try a.dupe(u8, shown));
        if (trace_out and cli.flag("--show")) try cli.print("view\t{d}\t{s}\n", .{ count, shown });
        if (commit) |text| {
            typed.chunks += 1;
            try typed.committed.appendSlice(a, text);
            if (trace_out) try cli.print("chunk\t{d}\t{s}\tpreedit={s}\n", .{ count, text, view.preedit });
        }
    }
    typed.before_fix = try a.dupe(u8, try std.mem.concat(a, u8, &.{ typed.committed.items, (try session.view()).preedit }));
    if (expected) |want| try correct(a, session, want, &typed, &clock);
    // With a word cursor open, Return confirms the word and moves on; it
    // commits once the cursor is past the end. Returns beyond the first
    // are correction cost.
    var returns: usize = 0;
    while (returns < 64) : (returns += 1) {
        clock += 0.3;
        const result = try session.handle(.{ .kind = .enter, .text = "\r", .timestamp = clock });
        if (returns > 0) typed.fix_keys += 1;
        if (result.commit) |rest| try typed.committed.appendSlice(a, rest);
        if ((try session.view()).preedit.len == 0) break;
    }
    return typed;
}

/// What a typist who reads the screen does to reach `want` before Return:
/// at the first wrong character, pick the whole-sentence candidate if it is
/// on the first page (Down, selection key); otherwise Left to the word,
/// Down, and the selection key (or Down… Return past the first page) of the
/// longest listed word that is right there. Stops when the composition
/// matches, a pick makes no progress, or nothing listed fits (`unreachable`:
/// only retyping helps). Every key is a real event, counted in `fix_keys`.
fn correct(a: Allocator, session: *session_mod.Session, want_utf8: []const u8, typed: *Typed, clock: *f64) !void {
    const committed = typed.committed.items;
    if (!std.mem.startsWith(u8, want_utf8, committed)) {
        typed.unreachable_fix = true; // a wrong chunk was already committed
        return;
    }
    // Spaces are layout, not something a pick can fix: compare without
    // them (`diff` indexes the space-free text, `at` the preedit).
    const want = try withoutSpaces(a, try std.unicode.utf8ToUtf16LeAlloc(a, want_utf8[committed.len..]), null);
    var stalls: usize = 0;
    var last_diff: ?usize = null;
    while (typed.picks < 16 and !typed.committed_during_fix) {
        const view = try session.view();
        var positions: std.ArrayList(usize) = .empty;
        const shown = try withoutSpaces(a, try std.unicode.utf8ToUtf16LeAlloc(a, view.preedit), &positions);
        const diff = firstDiff(shown, want) orelse return;
        const at = if (diff < positions.items.len) positions.items[diff] else unicode_len: {
            break :unicode_len (try std.unicode.utf8ToUtf16LeAlloc(a, view.preedit)).len;
        };
        if (last_diff) |d| {
            if (diff <= d) stalls += 1;
            if (stalls >= 2) {
                typed.unreachable_fix = true;
                return;
            }
        }
        last_diff = diff;
        // Whole-sentence rows (no word cursor yet).
        if (view.focus == null or session.cursor == null) {
            if (try pageIndexOf(a, view.candidates, view.page_size, want, 0)) |index| {
                try press(session, typed, clock, .{ .kind = .down });
                try pickSlot(session, typed, clock, index);
                typed.picks += 1;
                continue;
            }
        }
        // Walk the word cursor toward the first error, one way only: Left
        // from the end (or from past the error), Right when a pick left it
        // before the error. Read the listed words at each stop until one
        // fits the target over the error, or the cursor has passed it.
        var found: ?usize = null;
        const start_focus = (try session.view()).focus;
        const left = session.cursor == null or start_focus == null or start_focus.?.end > at;
        var steps: usize = 0;
        while (steps < 64) : (steps += 1) {
            const v = try session.view();
            if (session.cursor != null) if (v.focus) |f| {
                if (f.start <= at) found = try wordOptionFor(a, v.candidates, want, diff);
                if (found != null) break;
                if (left and f.end <= at) break;
                if (!left and f.start > at) break;
            };
            const before = session.cursor;
            try press(session, typed, clock, .{ .kind = if (left) .left else .right });
            if (before != null and session.cursor == before) break;
            if (session.cursor == null) break; // walked off the end
        }
        const index = found orelse {
            typed.unreachable_fix = true;
            return;
        };
        try press(session, typed, clock, .{ .kind = .down });
        try pickSlot(session, typed, clock, index);
        typed.picks += 1;
    }
    typed.unreachable_fix = true;
}

fn press(session: *session_mod.Session, typed: *Typed, clock: *f64, event: session_mod.KeyEvent) !void {
    clock.* += 0.3;
    var e = event;
    e.timestamp = clock.*;
    const result = try session.handle(e);
    typed.fix_keys += 1;
    if (std.c.getenv("MISSTYPE_FIX_DEBUG") != null) {
        const v = try session.view();
        std.debug.print("  key {t} {s} -> {s} sel={d}\n", .{ e.kind, e.label, v.preedit, v.selected });
    }
    if (result.commit) |text| {
        try typed.committed.appendSlice(typed.arena, text);
        typed.committed_during_fix = true;
    }
}

/// After Down the panel shows the page holding the selected row (in a word
/// cursor that is the shown word, not row 0). A row on that page is one
/// selection key; any other is Down/Up to it (the shorter way round), then
/// Return.
fn pickSlot(session: *session_mod.Session, typed: *Typed, clock: *f64, index: usize) !void {
    const v = try session.view();
    const page = @max(v.page_size, 1);
    const first = (v.selected / page) * page;
    if (index >= first and index - first < @min(page, v.selection_keys.len)) {
        const label = v.selection_keys[index - first];
        return press(session, typed, clock, .{ .kind = .character, .label = label, .text = label });
    }
    const count = v.candidates.len;
    const forward = (index + count - v.selected) % count;
    const steps = @min(forward, count - forward);
    for (0..steps) |_| try press(session, typed, clock, .{ .kind = if (forward <= count - forward) .down else .up });
    try press(session, typed, clock, .{ .kind = .enter, .text = "\r" });
}

/// `text` without ASCII spaces; `positions` gets each kept unit's index.
fn withoutSpaces(a: Allocator, text: []const u16, positions: ?*std.ArrayList(usize)) ![]const u16 {
    var out: std.ArrayList(u16) = .empty;
    for (text, 0..) |unit, i| {
        if (unit == ' ') continue;
        try out.append(a, unit);
        if (positions) |p| try p.append(a, i);
    }
    return out.items;
}

fn firstDiff(shown: []const u16, want: []const u16) ?usize {
    const n = @min(shown.len, want.len);
    for (0..n) |i| if (shown[i] != want[i]) return i;
    return if (shown.len == want.len) null else n;
}

/// Row equal to the whole target (spaces aside), on the first page only.
fn pageIndexOf(a: Allocator, rows: []const []const u8, page: usize, want: []const u16, _: usize) !?usize {
    for (rows[0..@min(rows.len, page)], 0..) |row, i| {
        if (std.mem.eql(u16, try withoutSpaces(a, try std.unicode.utf8ToUtf16LeAlloc(a, row), null), want)) return i;
    }
    return null;
}

/// The longest listed word the target has at a place covering `diff`.
fn wordOptionFor(a: Allocator, rows: []const []const u8, want: []const u16, diff: usize) !?usize {
    var best: ?usize = null;
    var best_len: usize = 0;
    for (rows, 0..) |row, i| {
        const word = try std.unicode.utf8ToUtf16LeAlloc(a, row);
        if (word.len == 0 or word.len <= best_len) continue;
        const lo = if (diff + 1 >= word.len) diff + 1 - word.len else 0;
        var start = lo;
        while (start <= diff and start + word.len <= want.len) : (start += 1) {
            if (std.mem.eql(u16, want[start .. start + word.len], word)) {
                best = i;
                best_len = word.len;
                break;
            }
        }
    }
    return best;
}

/// One engine as the trace configures it (settings, english list, learned
/// state from the given files).
fn traceEngine(cli: Cli) !*session_mod.Engine {
    const decoder = try cli.loadDecoder();
    const engine = try session_mod.Engine.create(cli.gpa, cli.io, decoder);
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
    try loadLearned(cli, engine);
    return engine;
}

fn loadLearned(cli: Cli, engine: *session_mod.Engine) !void {
    engine.user_lexicon.deinit();
    engine.user_lexicon = .init(cli.gpa);
    engine.channel_learner.deinit();
    engine.channel_learner = .init(cli.gpa);
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
}

fn trace(cli: Cli, keys: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(cli.gpa);
    defer arena.deinit();
    const engine = try traceEngine(cli);
    defer engine.release();
    const session = try session_mod.Session.create(engine);
    defer session.destroy();
    const typed = try typeKeys(cli, arena.allocator(), session, keys, false, true, null);
    try cli.print("final\t{s}\n", .{typed.committed.items});
}

fn readStdin(cli: Cli) ![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = Io.File.stdin().reader(cli.io, &buf);
    return reader.interface.allocRemaining(cli.gpa, .unlimited);
}

/// `--session-batch FILE` (`-` = stdin): one trace per line (`keys`, or
/// `keys<TAB>expected` to correct with the panel first), the lexicon
/// loaded once. Each line gets a fresh session and, unless `--carry`, the
/// learned state the flags name (so lines do not teach each other). Prints
/// one JSON object per line: final text, per-label ms, chunk count and,
/// with `--show`, the preedit after each label.
fn batch(cli: Cli, path: []const u8) !void {
    const input = if (std.mem.eql(u8, path, "-"))
        try readStdin(cli)
    else
        cli.read(path) orelse {
            std.debug.print("misstype-dev: cannot read {s}\n", .{path});
            std.process.exit(1);
        };
    defer cli.gpa.free(input);
    const engine = try traceEngine(cli);
    defer engine.release();
    const carry = cli.flag("--carry");
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        var arena: std.heap.ArenaAllocator = .init(cli.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (!carry) try loadLearned(cli, engine);
        engine.english = false;
        engine.shift_tap = .{};
        const session = try session_mod.Session.create(engine);
        defer session.destroy();
        // `keys` or `keys<TAB>expected`: with an expected text the typist
        // also corrects with the panel before Return.
        var fields = std.mem.splitScalar(u8, line, '\t');
        const keys = fields.next().?;
        const expected = fields.next();
        const typed = try typeKeys(cli, a, session, keys, cli.flag("--show"), false, expected);
        try cli.print("{f}\n", .{std.json.fmt(.{
            .final = typed.committed.items,
            .before_fix = typed.before_fix,
            .picks = typed.picks,
            .fix_keys = typed.fix_keys,
            .@"unreachable" = typed.unreachable_fix,
            .ms = typed.ms.items,
            .chunks = typed.chunks,
            .views = typed.views.items,
        }, .{})});
    }
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
    if (cli.flag("--build-mode")) {
        try cli.print("{t}\n", .{@import("builtin").mode});
    } else if (cli.value("--decode")) |keys| {
        try decode(cli, keys);
    } else if (cli.value("--session-trace")) |keys| {
        try trace(cli, keys);
    } else if (cli.value("--session-batch")) |path| {
        try batch(cli, path);
    } else {
        std.debug.print("usage: misstype-dev --decode KEYS | --session-trace KEYS | --session-batch FILE  (see the header of core-zig/src/dev.zig)\n", .{});
        std.process.exit(2);
    }
    try out_file.interface.flush();
}
