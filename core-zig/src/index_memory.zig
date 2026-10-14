//! Developer-only index construction accounting, not process RSS.
const std = @import("std");
const core = @import("misstype");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedResourceDirectoryAndMode;
    const dir = try Io.Dir.cwd().openDir(init.io, args[1], .{});
    defer dir.close(init.io);
    const mode = args[2];
    const english = std.mem.eql(u8, mode, "english");
    if (!english and !std.mem.eql(u8, mode, "Chinese") and !std.mem.eql(u8, mode, "Chinese-toneless")) return error.BadMode;
    const text = try dir.readFileAlloc(init.io, if (english) "english.tsv" else "lexicon.tsv", init.gpa, .unlimited);
    defer init.gpa.free(text);
    const supplement = if (english) try init.gpa.dupe(u8, "") else try dir.readFileAlloc(init.io, "local_phrases.tsv", init.gpa, .unlimited);
    defer init.gpa.free(supplement);
    const tones = if (std.mem.eql(u8, mode, "Chinese-toneless")) try dir.readFileAlloc(init.io, "toneless.tsv", init.gpa, .unlimited) else try init.gpa.dupe(u8, "");
    defer init.gpa.free(tones);
    var buf: [4096]u8 = undefined;
    var file: Io.File.Writer = .init(.stdout(), init.io, &buf);
    const out = &file.interface;
    const start = Io.Timestamp.now(init.io, .awake);
    if (english) {
        const lex = try core.english.EnglishLexicon.create(init.gpa, text);
        defer lex.destroy();
        const elapsed = start.durationTo(Io.Timestamp.now(init.io, .awake)).nanoseconds;
        const postings = lex.postings.len;
        const posting_capacity = lex.postings.len;
        var key_bytes: usize = 0;
        var it = lex.delete_index.keyIterator();
        while (it.next()) |key| key_bytes += key.len;
        try out.print("{{\"mode\":\"english\",\"arena_bytes\":{d},\"build_ms\":{d:.4},\"words\":{d},\"delete_keys\":{d},\"postings\":{d},\"posting_capacity\":{d},\"key_bytes\":{d}}}\n", .{
            lex.arena.queryCapacity(), @as(f64, @floatFromInt(elapsed)) / 1e6, lex.scores.count(), lex.delete_index.count(), postings, posting_capacity, key_bytes,
        });
    } else {
        const lex = try core.Lexicon.create(init.gpa, &.{ text, supplement }, tones);
        defer lex.destroy();
        const elapsed = start.durationTo(Io.Timestamp.now(init.io, .awake)).nanoseconds;
        var entries: usize = 0;
        var entry_capacity: usize = 0;
        var rescored: usize = 0;
        for (lex.nodes.items) |node| {
            entries += node.entries.items.len;
            entry_capacity += node.entries.capacity;
            if (node.toneless_entries) |list| rescored += list.items.len;
        }
        try out.print("{{\"mode\":\"{s}\",\"arena_bytes\":{d},\"build_ms\":{d:.4},\"nodes\":{d},\"readings\":{d},\"entries\":{d},\"entry_capacity\":{d},\"rescored_entries\":{d}}}\n", .{
            mode, lex.arena.queryCapacity(), @as(f64, @floatFromInt(elapsed)) / 1e6, lex.nodes.items.len, lex.reading_names.items.len, entries, entry_capacity, rescored,
        });
    }
    try out.flush();
}
