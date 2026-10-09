//! Synthetic decoder/touch/Unicode differential driver (tools/zig_cases.py).
const std = @import("std");
const core = @import("misstype");
const Case = struct {
    id: []const u8,
    mode: []const u8,
    keys: []const u8 = "",
    text: []const u8 = "",
    fuzzy: bool = true,
    tone: bool = true,
    strength: u8 = 2,
    spatial: bool = true,
    algorithm: []const u8 = "lattice",
    taps: []const Tap = &.{},
    const Tap = struct { surface: core.touch.Surface, x: f64, y: f64 };
};
fn candidate(w: *std.Io.Writer, id: []const u8, rank: usize, c: core.candidate.Candidate, spatial: f64, keys: []const u8) !void {
    try w.print("C\t{s}\t{d}\t{s}\t{x:0>16}\t{d}\t{d}\t", .{ id, rank, c.text, @as(u64, @bitCast(c.score)), c.repairs, c.unresolved });
    for (c.alignment, 0..) |span, i| try w.print("{s}{d}-{d}:{d}-{d}", .{ if (i == 0) "" else ",", span.syllables.start, span.syllables.end, span.chars.start, span.chars.end });
    try w.writeByte('\t');
    for (c.syllables, 0..) |s, i| try w.print("{s}{s}:{c}", .{ if (i == 0) "" else ",", s.keys, s.tone orelse '~' });
    try w.writeByte('\t');
    for (c.runs, 0..) |r, i| try w.print("{s}{d}-{d}", .{ if (i == 0) "" else ",", r.start, r.end });
    try w.print("\t{x:0>16}\t{s}\n", .{ @as(u64, @bitCast(spatial)), keys });
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const a = init.arena.allocator();
    const io = init.io;
    const dir = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    const main_tsv = try dir.readFileAlloc(io, "lexicon.tsv", a, .unlimited);
    const local = try dir.readFileAlloc(io, "local_phrases.tsv", a, .unlimited);
    const toneless = try dir.readFileAlloc(io, "toneless.tsv", a, .unlimited);
    const dec = try core.Lexicon.create(init.gpa, &.{ main_tsv, local }, toneless);
    defer dec.destroy();
    dec.word_penalty = 0.5;
    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[2], a, .unlimited);
    var buf: [65536]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &output.interface;
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var totals: [2]i128 = .{ 0, 0 };
    var counts: [2]usize = .{ 0, 0 };
    var lines = std.mem.tokenizeScalar(u8, input, '\n');
    while (lines.next()) |line| {
        _ = arena.reset(.retain_capacity);
        const g = arena.allocator();
        const parsed = try std.json.parseFromSlice(Case, g, line, .{});
        const c = parsed.value;
        const started = std.Io.Timestamp.now(io, .awake);
        if (std.mem.eql(u8, c.mode, "keys")) {
            dec.repair_cost_offset = if (c.strength == 1) 1.5 else if (c.strength == 3) -1.5 else 0;
            dec.repair_valid_readings = c.strength == 3;
            var comp: core.composition.Composition = .{};
            for (c.keys) |key| _ = try comp.append(g, key);
            const p = try comp.parsed(g);
            const decoded = try dec.decodeSegments(g, try comp.segments(g), p.pending, .{ .fuzzy = c.fuzzy, .tone_tolerance = c.tone });
            totals[0] += started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
            counts[0] += 1;
            for (decoded, 0..) |d, rank| try candidate(w, c.id, rank, d, 0, "");
        } else if (std.mem.eql(u8, c.mode, "touch")) {
            dec.repair_cost_offset = 0;
            dec.repair_valid_readings = false;
            const taps = try g.alloc(core.touch.Hypothesis, c.taps.len);
            for (c.taps, taps, 0..) |tap, *out, index| {
                out.* = core.touch.hypothesis(tap.surface, tap.x, tap.y) orelse return error.BadTap;
                try w.print("H\t{s}\t{d}\t", .{ c.id, index });
                for (out.ranked, 0..) |r, i| try w.print("{s}{c}:{x:0>16}:{x:0>16}", .{ if (i == 0) "" else ",", r.key, @as(u64, @bitCast(r.distance)), @as(u64, @bitCast(r.weight)) });
                try w.writeByte('\n');
            }
            const opts: core.touch.Options = .{ .spatial = c.spatial, .fuzzy = c.fuzzy, .tone_tolerance = c.tone };
            const decoded = if (std.mem.eql(u8, c.algorithm, "beam")) try core.touch.decodeBeam(dec, g, taps, opts) else try core.touch.decode(dec, g, taps, opts);
            totals[1] += started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
            counts[1] += 1;
            for (decoded, 0..) |d, rank| try candidate(w, c.id, rank, d.sentence, d.spatial_cost, d.keys);
        } else if (std.mem.eql(u8, c.mode, "unicode")) {
            try w.print("U\t{s}\t{d}\t{d}\t", .{ c.id, core.unicode.characterCount(c.text), core.unicode.utf16Len(c.text) });
            for (try core.unicode.characters(g, c.text), 0..) |ch, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", ch.len });
            try w.writeByte('\n');
        } else if (std.mem.eql(u8, c.mode, "dictionary")) {
            const n = core.unicode.characterCount(c.text);
            var reading: std.ArrayList(u8) = .empty;
            for (0..n) |i| {
                if (i > 0) try reading.append(g, '-');
                try reading.appendSlice(g, "ㄋㄧˇ");
            }
            try w.print("D\t{s}\t{d}\n", .{ c.id, @intFromBool(core.user_dictionary.validate(reading.items, c.text) == null) });
        } else return error.BadMode;
    }
    try w.flush();
    var err_buf: [2048]u8 = undefined;
    var err: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
    for ([_][]const u8{ "keys", "touch" }, 0..) |mode, i| try err.interface.print("parity: {s} n={d} mean_us={d}\n", .{ mode, counts[i], @divTrunc(totals[i], @as(i128, @intCast(@max(1, counts[i]))) * 1000) });
    try err.interface.flush();
}
