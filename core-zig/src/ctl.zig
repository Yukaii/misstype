//! Linux dictionary/config CLI. Files and output follow Sources/MisstypeCtl.
const std = @import("std");
const core = @import("misstype");
const Dict = core.user_dictionary.UserDictionary;
const Entry = core.user_dictionary.Entry;
const A = std.mem.Allocator;
const Io = std.Io;
const usage = @embedFile("ctl_usage.txt");
const Setting = struct { key: []const u8, fallback: []const u8, summary: []const u8, kind: Kind };
const Kind = union(enum) { boolean, string, integer: struct { lo: i64, hi: i64 }, choice: []const []const u8 };
pub const settings = [_]Setting{
    .{ .key = "RepairStrength", .fallback = "Standard", .summary = "Repair typing mistakes", .kind = .{ .choice = &.{ "Off", "Light", "Standard", "Strong" } } },
    .{ .key = "ToneTolerance", .fallback = "True", .summary = "Tolerate wrong tones", .kind = .boolean },
    .{ .key = "UserLearning", .fallback = "True", .summary = "Learn phrases you type", .kind = .boolean },
    .{ .key = "ChannelLearning", .fallback = "False", .summary = "Learn your typing slips (experimental, needs phrase learning)", .kind = .boolean },
    .{ .key = "MixedEnglish", .fallback = "False", .summary = "Recognize English words while typing", .kind = .boolean },
    .{ .key = "AutoShowCandidates", .fallback = "False", .summary = "Show candidates automatically", .kind = .boolean },
    .{ .key = "ReturnConfirmsSelection", .fallback = "True", .summary = "Return confirms the selected candidate", .kind = .boolean },
    .{ .key = "CandidateKeys", .fallback = core.session.default_keys, .summary = "Selection keys", .kind = .string },
    .{ .key = "CandidatesPerPage", .fallback = "8", .summary = "Candidates per page", .kind = .{ .integer = .{ .lo = 4, .hi = 10 } } },
    .{ .key = "CursorCandidates", .fallback = "Covering", .summary = "Words listed at the syllable cursor", .kind = .{ .choice = &.{ "Covering", "EndingAt", "BeginningAt" } } },
    .{ .key = "AutoCommitSyllables", .fallback = "24", .summary = "Commit long input in chunks after N syllables (0 = never)", .kind = .{ .integer = .{ .lo = 0, .hi = 64 } } },
    .{ .key = "ShiftTogglesEnglish", .fallback = "False", .summary = "Lone Shift switches 中/英 in Misstype (disable fcitx5's Temporarily Toggle Input Method key)", .kind = .boolean },
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn getenv(name: [:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
}
const Args = struct {
    words: std.ArrayList([]const u8) = .empty,
    file: ?[]const u8 = null,
    weight: ?[]const u8 = null,
    tsv: bool = false,
    no_reload: bool = false,
    problem: ?[]const u8 = null,
    fn parse(a: A, args: []const []const u8, dict: bool) !Args {
        var out: Args = .{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.startsWith(u8, arg, "--") and arg.len > 2) {
                const name = arg[2..];
                if (eq(name, "file") or (dict and eq(name, "weight"))) {
                    if (i + 1 == args.len) {
                        out.problem = try std.fmt.allocPrint(a, "--{s} needs a value", .{name});
                        return out;
                    }
                    i += 1;
                    if (eq(name, "file")) out.file = args[i] else out.weight = args[i];
                } else if (dict and eq(name, "tsv")) out.tsv = true else if (!dict and eq(name, "no-reload")) out.no_reload = true else {
                    out.problem = try std.fmt.allocPrint(a, "unknown option --{s}", .{name});
                    return out;
                }
            } else try out.words.append(a, arg);
        }
        return out;
    }
};
const Runner = struct {
    a: A,
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,
    fn print(self: Runner, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(fmt ++ "\n", args);
    }
    fn errorLine(self: Runner, comptime fmt: []const u8, args: anytype) !void {
        try self.err.print(fmt ++ "\n", args);
    }
    fn read(self: Runner, path: []const u8) []const u8 {
        return core.storage.read(self.io, self.a, path) orelse "";
    }
    fn exists(self: Runner, path: []const u8) bool {
        _ = Io.Dir.cwd().statFile(self.io, path, .{}) catch return false;
        return true;
    }
    fn absolute(self: Runner, path: []const u8) ![]const u8 {
        const cwd = try Io.Dir.cwd().realPathFileAlloc(self.io, ".", self.a);
        return std.fs.path.resolve(self.a, &.{ cwd, path });
    }
    fn configPath(self: Runner) ![]const u8 {
        const home = getenv("HOME") orelse "";
        const xdg = getenv("XDG_CONFIG_HOME") orelse "";
        const base = if (xdg.len > 0 and xdg[0] == '/') xdg else try std.fmt.allocPrint(self.a, "{s}/.config", .{home});
        return std.fmt.allocPrint(self.a, "{s}/fcitx5/conf/misstype.conf", .{base});
    }
    fn external(self: Runner, program: []const u8, args: []const []const u8, quiet: bool) ?u8 {
        const argv = self.a.alloc([]const u8, args.len + 2) catch return null;
        argv[0] = "/usr/bin/env";
        argv[1] = program;
        @memcpy(argv[2..], args);
        var child = std.process.spawn(self.io, .{ .argv = argv, .stdout = if (quiet) .ignore else .inherit, .stderr = if (quiet) .ignore else .inherit }) catch return null;
        const term = child.wait(self.io) catch return null;
        return switch (term) {
            .exited => |code| if (code == 127) null else code,
            else => 1,
        };
    }
    fn run(self: Runner, args: []const []const u8) !u8 {
        if (args.len == 0) {
            try self.err.writeAll(usage);
            return 2;
        }
        if (eq(args[0], "help") or eq(args[0], "--help") or eq(args[0], "-h")) {
            try self.out.writeAll(usage);
            return 0;
        }
        if (!eq(args[0], "dict") and !eq(args[0], "config")) {
            try self.errorLine("misstypectl: unknown command “{s}”\n\n{s}", .{ args[0], std.mem.trimEnd(u8, usage, "\n") });
            return 2;
        }
        const dict = eq(args[0], "dict");
        if (args.len < 2) {
            try self.errorLine("misstypectl {s}: missing subcommand\n\n{s}", .{ args[0], std.mem.trimEnd(u8, usage, "\n") });
            return 2;
        }
        const parsed = try Args.parse(self.a, args[2..], dict);
        if (parsed.problem) |p| {
            try self.errorLine("misstypectl {s}: {s}", .{ args[0], p });
            return 2;
        }
        const path = if (parsed.file) |p| try self.absolute(p) else if (dict) try core.storage.defaultPath(self.a, "user_dictionary.tsv") else try self.configPath();
        return if (dict) try self.dictionary(args[1], parsed, path) else try self.config(args[1], parsed, path);
    }
    fn dictionary(self: Runner, sub: []const u8, args: Args, path: []const u8) !u8 {
        if (eq(sub, "path")) {
            try self.print("{s}", .{path});
            return 0;
        }
        if (eq(sub, "list")) {
            var d = try Dict.parse(self.a, self.read(path), null);
            defer d.deinit();
            for (d.added.items) |e| {
                if (args.tsv) try self.print("{s}", .{try self.dictLine(e, false)}) else if (e.weight == 0) try self.print("{s}  {s}", .{ e.reading, e.text }) else try self.print("{s}  {s}  (weight {s})", .{ e.reading, e.text, try self.double(e.weight) });
            }
            for (d.excluded.items) |e| {
                if (args.tsv) try self.print("{s}", .{try self.dictLine(e, true)}) else try self.print("{s}  {s}  (hidden built-in)", .{ e.reading, e.text });
            }
            return 0;
        }
        if (eq(sub, "check")) return self.check(path);
        if (eq(sub, "gui")) {
            return self.external("misstype-dictionary-editor", if (args.file != null) &.{ "--file", args.file.? } else &.{}, false) orelse blk: {
                try self.errorLine("misstypectl: misstype-dictionary-editor is not installed (try `misstypectl dict edit`)", .{});
                break :blk 1;
            };
        }
        if (eq(sub, "edit")) {
            if (!self.exists(path)) {
                const d = Dict.init(self.a);
                _ = core.storage.writeAtomic(self.io, self.a, path, try d.serialized(self.a));
            }
            const editor = blk: {
                for ([_]?[]const u8{ getenv("VISUAL"), getenv("EDITOR") }) |p| if (p) |value| if (value.len > 0) break :blk value;
                break :blk "vi";
            };
            const status = self.external(editor, &.{path}, false) orelse {
                try self.errorLine("misstypectl: cannot start editor “{s}” (set $EDITOR)", .{editor});
                return 1;
            };
            return if (status == 0) self.check(path) else status;
        }
        if (!eq(sub, "add") and !eq(sub, "remove") and !eq(sub, "exclude") and !eq(sub, "unexclude")) {
            try self.errorLine("misstypectl dict: unknown subcommand “{s}”", .{sub});
            return 2;
        }
        if (args.words.items.len != 2) {
            try self.errorLine("misstypectl dict {s}: expected <reading> <text>", .{sub});
            return 2;
        }
        const reading = args.words.items[0];
        const text = args.words.items[1];
        var weight: f64 = 0;
        if (args.weight) |value| {
            if (!eq(sub, "add")) {
                try self.errorLine("misstypectl dict {s}: --weight only applies to add", .{sub});
                return 2;
            }
            weight = std.fmt.parseFloat(f64, value) catch std.math.nan(f64);
            if (!std.math.isFinite(weight) or weight > 0) {
                try self.errorLine("misstypectl dict add: weight must be a number ≤ 0", .{});
                return 2;
            }
        }
        if (eq(sub, "add") or eq(sub, "exclude")) if (try self.validation(reading, text)) |problem| {
            try self.errorLine("misstypectl dict {s}: {s}", .{ sub, problem });
            return 1;
        };
        var lines = try self.splitLines(self.read(path));
        var found: bool = false;
        var same: bool = false;
        var i: usize = 0;
        while (i < lines.items.len) {
            // Preserve the Swift CLI's legacy TSV matching semantics.
            const entry = try self.legacy(lines.items[i]);
            const matching = if (entry) |e| eq(e.value.reading, reading) and core.unicode.equal(e.value.text, text) else false;
            if (matching) {
                const e = entry.?;
                if (eq(sub, "add") and !e.excluded and e.value.weight == weight) same = true;
                if (eq(sub, "exclude") and e.excluded) same = true;
                if (eq(sub, "remove") and !e.excluded or eq(sub, "unexclude") and e.excluded) found = true;
                const remove = eq(sub, "add") or eq(sub, "exclude") or (eq(sub, "remove") and !e.excluded) or (eq(sub, "unexclude") and e.excluded);
                if (remove) {
                    _ = lines.orderedRemove(i);
                    continue;
                }
            }
            i += 1;
        }
        if (same) {
            try self.print("{s}: {s}  {s}", .{ if (eq(sub, "add")) "already there" else "already hidden", reading, text });
            return 0;
        }
        if (eq(sub, "remove") or eq(sub, "unexclude")) {
            if (!found) {
                try self.errorLine("{s}: {s}  {s}", .{ if (eq(sub, "remove")) "not in your dictionary" else "not hidden", reading, text });
                return 1;
            }
        } else try lines.append(self.a, try self.dictLine(.{ .reading = reading, .text = text, .weight = weight }, eq(sub, "exclude")));
        const d = Dict.init(self.a);
        const output = if (lines.items.len == 0) try d.serialized(self.a) else try self.joinLines(lines.items);
        if (!core.storage.writeAtomic(self.io, self.a, path, output)) {
            try self.errorLine("misstypectl: cannot write {s}", .{path});
            return 1;
        }
        try self.print("{s}: {s}  {s}", .{ sub, reading, text });
        return 0;
    }
    fn validation(self: Runner, reading: []const u8, text: []const u8) !?[]const u8 {
        const generic = core.user_dictionary.validate(reading, text) orelse return null;
        if (eq(generic, "character count differs from syllable count")) {
            const n = core.unicode.characterCount(text);
            const syllables = std.mem.count(u8, reading, "-") + 1;
            return try std.fmt.allocPrint(self.a, "{d} character{s} for {d} syllable{s}", .{ n, if (n == 1) "" else "s", syllables, if (syllables == 1) "" else "s" });
        }
        if (eq(generic, "not a Zhuyin syllable")) {
            var it = std.mem.splitScalar(u8, reading, '-');
            while (it.next()) |s| {
                if (core.user_dictionary.validate(s, "你") != null) return try std.fmt.allocPrint(self.a, "“{s}” is not a Zhuyin syllable", .{s});
            }
        }
        return generic;
    }
    fn check(self: Runner, path: []const u8) !u8 {
        if (!self.exists(path)) {
            try self.print("{s}: no file yet (nothing to check)", .{path});
            return 0;
        }
        var problems: std.ArrayList(core.user_dictionary.Problem) = .empty;
        var d = try Dict.parse(self.a, self.read(path), &problems);
        defer d.deinit();
        const rows = try self.splitLines(self.read(path));
        for (problems.items) |p| {
            var message = p.message;
            var fields = std.mem.tokenizeAny(u8, std.mem.trimStart(u8, rows.items[p.line - 1], "!"), " \t\r");
            if (fields.next()) |first| if (fields.next()) |second| {
                const legacy_order = core.user_dictionary.isReadingLike(first) and !core.user_dictionary.isReadingLike(second);
                message = (try self.validation(if (legacy_order) first else second, if (legacy_order) second else first)) orelse message;
            };
            try self.errorLine("{s}:{d}: {s}", .{ path, p.line, message });
        }
        if (problems.items.len == 0) try self.print("{s}: ok", .{path});
        return if (problems.items.len == 0) 0 else 1;
    }
    fn double(self: Runner, value: f64) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try core.user_dictionary.appendSwiftDouble(&buf, self.a, value);
        return buf.items;
    }
    fn dictLine(self: Runner, e: Entry, excluded: bool) ![]const u8 {
        if (excluded) return std.fmt.allocPrint(self.a, "!{s}\t{s}", .{ e.reading, e.text });
        if (e.weight == 0) return std.fmt.allocPrint(self.a, "{s}\t{s}", .{ e.reading, e.text });
        return std.fmt.allocPrint(self.a, "{s}\t{s}\t{s}", .{ e.reading, e.text, try self.double(e.weight) });
    }
    const Legacy = struct { excluded: bool, value: Entry };
    fn legacy(self: Runner, raw: []const u8) !?Legacy {
        _ = self;
        const line = std.mem.trim(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "#") or std.mem.trim(u8, line, " \t").len == 0) return null;
        const excluded = line[0] == '!';
        var fields: [4][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, if (excluded) line[1..] else line, '\t');
        while (it.next()) |f| {
            if (count < 4) fields[count] = std.mem.trim(u8, f, " \t");
            count += 1;
        }
        if (count < 2 or count > 3 or core.user_dictionary.validate(fields[0], fields[1]) != null) return null;
        return .{ .excluded = excluded, .value = .{ .reading = fields[0], .text = fields[1], .weight = if (count == 3) std.fmt.parseFloat(f64, fields[2]) catch 0 else 0 } };
    }
    fn splitLines(self: Runner, text: []const u8) !std.ArrayList([]const u8) {
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| try out.append(self.a, line);
        if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
        return out;
    }
    fn joinLines(self: Runner, lines_: []const []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (lines_) |line| {
            try out.appendSlice(self.a, line);
            try out.append(self.a, '\n');
        }
        return out.items;
    }
    fn replace(self: Runner, source: []const u8, old: []const u8, new: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var it = std.mem.splitSequence(u8, source, old);
        var first = true;
        while (it.next()) |part| {
            if (!first) try out.appendSlice(self.a, new);
            first = false;
            try out.appendSlice(self.a, part);
        }
        return out.items;
    }
    const ConfigLine = struct { key: []const u8, value: []const u8 };
    fn configLine(self: Runner, line: []const u8) !?ConfigLine {
        if (std.mem.startsWith(u8, line, "#") or std.mem.startsWith(u8, line, "[")) return null;
        const at = std.mem.indexOfScalar(u8, line, '=') orelse return null;
        var value = line[at + 1 ..];
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = try self.replace(value[1 .. value.len - 1], "\\\"", "\"");
            value = try self.replace(value, "\\\\", "\\");
        }
        return .{ .key = line[0..at], .value = value };
    }
    fn find(name: []const u8) ?Setting {
        for (settings) |s| if (std.ascii.eqlIgnoreCase(s.key, name)) return s;
        return null;
    }
    fn unknown(self: Runner, name: ?[]const u8) !u8 {
        var names: std.ArrayList(u8) = .empty;
        for (settings, 0..) |s, i| {
            if (i > 0) try names.appendSlice(self.a, ", ");
            try names.appendSlice(self.a, s.key);
        }
        try self.errorLine("misstypectl config: unknown key{s} (known: {s})", .{ if (name) |n| try std.fmt.allocPrint(self.a, " “{s}”", .{n}) else "", names.items });
        return 2;
    }
    fn normalize(self: Runner, input: []const u8, s: Setting) !?[]const u8 {
        switch (s.kind) {
            .boolean => {
                for ([_][]const u8{ "true", "on", "yes", "1" }) |v| if (std.ascii.eqlIgnoreCase(v, input)) return "True";
                for ([_][]const u8{ "false", "off", "no", "0" }) |v| if (std.ascii.eqlIgnoreCase(v, input)) return "False";
                try self.errorLine("misstypectl config: {s} takes on/off", .{s.key});
            },
            .integer => |range| {
                const value = std.fmt.parseInt(i64, input, 10) catch range.lo - 1;
                if (value >= range.lo and value <= range.hi) return try std.fmt.allocPrint(self.a, "{d}", .{value});
                try self.errorLine("misstypectl config: {s} takes a number from {d} to {d}", .{ s.key, range.lo, range.hi });
            },
            .choice => |choices| {
                for (choices) |v| if (std.ascii.eqlIgnoreCase(v, input)) return v;
                var list: std.ArrayList(u8) = .empty;
                for (choices, 0..) |v, i| {
                    if (i > 0) try list.appendSlice(self.a, ", ");
                    try list.appendSlice(self.a, v);
                }
                try self.errorLine("misstypectl config: {s} takes one of {s}", .{ s.key, list.items });
            },
            .string => {
                const joined = try core.session.sanitizeKeys(self.a, input, 10);
                if (eq(joined, input)) return joined;
                try self.errorLine("misstypectl config: selection keys must be distinct keys of the Zhuyin layout (lowercase, no space, at most 10); the engine would use “{s}” instead", .{joined});
            },
        }
        return null;
    }
    fn config(self: Runner, sub: []const u8, args: Args, path: []const u8) !u8 {
        if (eq(sub, "path")) {
            try self.print("{s}", .{path});
            return 0;
        }
        const raw = self.read(path);
        var stored: std.StringHashMap([]const u8) = .init(self.a);
        var it = std.mem.tokenizeScalar(u8, raw, '\n');
        while (it.next()) |line| if (try self.configLine(line)) |pair| try stored.put(pair.key, pair.value);
        if (eq(sub, "list")) {
            for (settings) |s| try self.print("{s}={s}{s}", .{ s.key, stored.get(s.key) orelse s.fallback, if (stored.contains(s.key)) "" else "  (default)" });
            return 0;
        }
        const words = args.words.items;
        if (eq(sub, "get")) {
            if (words.len != 1) return self.unknown(if (words.len > 0) words[0] else null);
            const s = find(words[0]) orelse return self.unknown(words[0]);
            try self.print("{s}", .{stored.get(s.key) orelse s.fallback});
            return 0;
        }
        if (!eq(sub, "set") and !eq(sub, "reset")) {
            try self.errorLine("misstypectl config: unknown subcommand “{s}”", .{sub});
            return 2;
        }
        if (eq(sub, "set") and words.len != 2) {
            try self.errorLine("misstypectl config set: expected <Key> <value>", .{});
            return 2;
        }
        if (eq(sub, "reset") and words.len != 1) return self.unknown(if (words.len > 0) words[0] else null);
        const s = find(words[0]) orelse return self.unknown(words[0]);
        const value: ?[]const u8 = if (eq(sub, "set")) try self.normalize(words[1], s) orelse return 1 else null;
        var lines_ = try self.splitLines(raw);
        var found = false;
        for (lines_.items, 0..) |line, index| if (try self.configLine(line)) |pair| {
            if (!eq(pair.key, s.key)) continue;
            found = true;
            if (value) |v| lines_.items[index] = try self.encodedSetting(s.key, v) else _ = lines_.orderedRemove(index);
            break;
        };
        if (!found) if (value) |v| try lines_.append(self.a, try self.encodedSetting(s.key, v));
        if (!core.storage.writeAtomic(self.io, self.a, path, try self.joinLines(lines_.items))) {
            try self.errorLine("misstypectl: cannot write {s}", .{path});
            return 1;
        }
        if (value) |v| try self.print("{s}={s}", .{ s.key, v }) else try self.print("{s} reset to default", .{s.key});
        if (!args.no_reload and self.external("dbus-send", &.{ "--session", "--print-reply", "--dest=org.fcitx.Fcitx5", "/controller", "org.fcitx.Fcitx.Controller1.ReloadAddonConfig", "string:misstype" }, true) != @as(?u8, 0)) try self.errorLine("note: could not ask fcitx5 to reload; the change applies when fcitx5 next starts", .{});
        return 0;
    }
    fn encodedSetting(self: Runner, key: []const u8, value: []const u8) ![]const u8 {
        if (std.mem.indexOfAny(u8, value, "\"\\# \t") == null) return std.fmt.allocPrint(self.a, "{s}={s}", .{ key, value });
        return std.fmt.allocPrint(self.a, "{s}=\"{s}\"", .{ key, try self.replace(try self.replace(value, "\\", "\\\\"), "\"", "\\\"") });
    }
};
pub fn main(init: std.process.Init) !void {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out: Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    var err: Io.File.Writer = .init(.stderr(), init.io, &err_buf);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const runner: Runner = .{ .a = init.arena.allocator(), .io = init.io, .out = &out.interface, .err = &err.interface };
    const status = runner.run(args[1..]) catch |failure| blk: {
        try runner.errorLine("misstypectl: {s}", .{@errorName(failure)});
        break :blk @as(u8, 1);
    };
    try out.interface.flush();
    try err.interface.flush();
    std.process.exit(status);
}
