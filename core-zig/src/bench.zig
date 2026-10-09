//! misstype-bench <resource dir> <inputs.tsv> [repeats]
//!
//! Loads the shipping lexicon the way LexiconLoader does, decodes every
//! input in bench/inputs.tsv, and prints the top candidates in the format
//! of tests/MisstypeCoreTests/ZigReferenceTests.swift (stdout) plus latency
//! (stderr). bench/compare.sh diffs the two.

const std = @import("std");
const misstype = @import("misstype");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: misstype-bench <resource dir> <inputs.tsv> [repeats]\n", .{});
        std.process.exit(2);
    }
    const repeats = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 20;
    const dir = try Io.Dir.cwd().openDir(io, args[1], .{});

    const load_start = Io.Timestamp.now(io, .awake);
    const lexicon_tsv = try dir.readFileAlloc(io, "lexicon.tsv", gpa, .unlimited);
    defer gpa.free(lexicon_tsv);
    const supplement = dir.readFileAlloc(io, "local_phrases.tsv", gpa, .unlimited) catch try gpa.dupe(u8, "");
    defer gpa.free(supplement);
    const toneless = dir.readFileAlloc(io, "toneless.tsv", gpa, .unlimited) catch try gpa.dupe(u8, "");
    defer gpa.free(toneless);
    const lexicon = try misstype.Lexicon.create(gpa, &.{ lexicon_tsv, supplement }, toneless);
    defer lexicon.destroy();
    lexicon.word_penalty = 0.5; // LexiconLoader.defaultWordPenalty
    const load_ns = load_start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;

    const inputs = try Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .unlimited);
    defer gpa.free(inputs);

    var out_buf: [64 * 1024]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var means: std.ArrayList(f64) = .empty;
    defer means.deinit(gpa);
    var syllables: std.ArrayList(misstype.Syllable) = .empty;
    defer syllables.deinit(gpa);

    var lines = std.mem.tokenizeScalar(u8, inputs, '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next().?;
        const kind = fields.next().?;
        syllables.clearRetainingCapacity();
        var words = std.mem.tokenizeScalar(u8, fields.next().?, ' ');
        while (words.next()) |word| {
            const last = word[word.len - 1];
            const toned = std.mem.indexOfScalar(u8, "3467_", last) != null;
            try syllables.append(gpa, .{
                .keys = if (toned) word[0 .. word.len - 1] else word,
                .tone = if (!toned) null else if (last == '_') ' ' else last,
            });
        }

        const start = Io.Timestamp.now(io, .awake);
        for (0..repeats) |_| {
            _ = arena.reset(.retain_capacity);
            _ = try lexicon.decode(arena.allocator(), syllables.items, .{ .fuzzy = false });
        }
        const elapsed = start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
        try means.append(gpa, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(repeats)) / 1000.0);

        _ = arena.reset(.retain_capacity);
        const candidates = try lexicon.decode(arena.allocator(), syllables.items, .{ .fuzzy = false });
        for (candidates, 0..) |candidate, rank| {
            try out.print("{s}\t{s}\t{d}\t{s}\t{x:0>16}\t{d}\t{d}\t", .{
                name, kind, rank, candidate.text, @as(u64, @bitCast(candidate.score)), candidate.repairs, candidate.unresolved,
            });
            for (candidate.alignment, 0..) |span, i| {
                try out.print("{s}{d}-{d}:{d}-{d}", .{ if (i == 0) "" else ",", span.syllables.start, span.syllables.end, span.chars.start, span.chars.end });
            }
            try out.writeByte('\n');
        }
    }
    try out.flush();

    std.mem.sort(f64, means.items, {}, std.sort.asc(f64));
    var total: f64 = 0;
    for (means.items) |m| total += m;
    const n = means.items.len;
    std.debug.print("zig: entries={d} load={d:.1}ms inputs={d} repeats={d} decode mean={d:.1}us p50={d:.1}us p95={d:.1}us max={d:.1}us\n", .{
        lexicon.entry_count,                @as(f64, @floatFromInt(load_ns)) / 1e6, n,                                        repeats,
        total / @as(f64, @floatFromInt(n)), means.items[n / 2],                     means.items[@min(n - 1, (n * 95) / 100)], means.items[n - 1],
    });
}
