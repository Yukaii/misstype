//! Where a composition's raw keys show in its preview (port of
//! Sources/MisstypeCore/CompositionLayout.swift): raw key index <-> UTF-16
//! preview offset <-> decoded syllable.

const std = @import("std");
const keyboard = @import("keyboard.zig");
const unicode = @import("unicode.zig");
const candidate_mod = @import("candidate.zig");
const composition_mod = @import("composition.zig");
const Candidate = candidate_mod.Candidate;
const Range = candidate_mod.Range;
const Key = composition_mod.Key;
const Allocator = std.mem.Allocator;

pub const Layout = struct {
    /// UTF-16 offset in the preview before raw key `i`; the last entry is
    /// the end of the preview.
    offsets: []u32,
    /// Raw keys of each decoded syllable (symbol keys plus closing tone).
    syllable_keys: []Range,
    /// Option+Left / Option+Right stops, ascending raw indexes.
    word_starts: []usize,
    word_ends: []usize,

    /// Null when the candidate's syllables do not account for the keys.
    pub fn init(arena: Allocator, keys: []const Key, caret: ?usize, top: Candidate, raw_tail: usize) !?Layout {
        var b: Builder = .{
            .arena = arena,
            .keys = keys,
            .top = top,
            .raw_tail = raw_tail,
            .offsets = try arena.alloc(u32, keys.len + 1),
        };
        @memset(b.offsets, 0);
        for (keys, 0..) |key, index| {
            if (caret == index and b.body.items.len > 0) {
                if (!try b.closeBody(null, false)) return null;
            }
            const is_space = key.isSpace();
            if (key == .latin or key == .literal or (is_space and b.body.items.len == 0)) {
                if (!try b.closeBody(null, false)) return null;
                b.offsets[index] = b.pos;
                b.pos += switch (key) {
                    .latin => 1,
                    .literal => |l| unicode.utf16Len(@import("punctuation.zig").literals[l]),
                    .key => 1,
                };
                if (is_space) continue;
                // A Latin word is a run of letters/digits; anything else is a
                // word of its own.
                const word = key.isLatinWord();
                if (!word or index == 0 or !keys[index - 1].isLatinWord()) try b.starts.put(arena, index, {});
                if (!word or index + 1 == keys.len or !keys[index + 1].isLatinWord()) try b.ends.put(arena, index + 1, {});
            } else if (key.isTone()) {
                if (b.body.items.len == 0) {
                    b.offsets[index] = b.pos;
                } else if (!try b.closeBody(index, false)) return null;
            } else {
                try b.body.append(arena, index);
            }
        }
        if (!try b.closeBody(null, true)) return null;
        if (b.syllable_keys.items.len != top.syllables.len or b.pos != top.utf16_len + raw_tail) return null;
        b.offsets[keys.len] = b.pos;
        for (top.alignment) |word| {
            if (word.syllables.end > b.syllable_keys.items.len or word.syllables.isEmpty()) continue;
            try b.starts.put(arena, b.syllable_keys.items[word.syllables.start].start, {});
            try b.ends.put(arena, b.syllable_keys.items[word.syllables.end - 1].end, {});
        }
        const starts = try arena.dupe(usize, b.starts.keys());
        const ends = try arena.dupe(usize, b.ends.keys());
        std.mem.sort(usize, starts, {}, std.sort.asc(usize));
        std.mem.sort(usize, ends, {}, std.sort.asc(usize));
        return .{ .offsets = b.offsets, .syllable_keys = b.syllable_keys.items, .word_starts = starts, .word_ends = ends };
    }

    const Builder = struct {
        arena: Allocator,
        keys: []const Key,
        top: Candidate,
        raw_tail: usize,
        offsets: []u32,
        syllable_keys: std.ArrayList(Range) = .empty,
        starts: std.AutoArrayHashMapUnmanaged(usize, void) = .empty,
        ends: std.AutoArrayHashMapUnmanaged(usize, void) = .empty,
        pos: u32 = 0,
        body: std.ArrayList(usize) = .empty,

        fn charEnd(b: *const Builder, syllable: usize) ?u32 {
            const word = b.top.wordAt(syllable) orelse return null;
            if (word.chars.len() != word.syllables.len()) return word.chars.end;
            return word.chars.start + @as(u32, @intCast(syllable - word.syllables.start)) + 1;
        }

        /// Hand the open body to the next decoded syllables; leftover keys
        /// are the live raw tail, legal only at the very end.
        fn closeBody(b: *Builder, tone: ?usize, final: bool) !bool {
            defer b.body.clearRetainingCapacity();
            const body = b.body.items;
            const syllables = b.top.syllables;
            var used: usize = 0;
            while (used < body.len and b.syllable_keys.items.len < syllables.len) {
                const index = b.syllable_keys.items.len;
                const count = syllables[index].keys.len;
                if (count == 0 or used + count > body.len) return false;
                const start = b.top.charOffset(index) orelse return false;
                const end = b.charEnd(index) orelse return false;
                b.offsets[body[used]] = start;
                for (body[used + 1 .. used + count]) |k| b.offsets[k] = end;
                var upper = body[used + count - 1] + 1;
                if (used + count == body.len) if (tone) |t| {
                    b.offsets[t] = end;
                    upper = t + 1;
                };
                try b.syllable_keys.append(b.arena, Range.of(body[used], upper));
                b.pos = end;
                used += count;
            }
            const left = body.len - used;
            if (!(left == 0 or (final and tone == null and left == b.raw_tail))) return false;
            if (left > 0) {
                try b.starts.put(b.arena, body[used], {});
                try b.ends.put(b.arena, b.keys.len, {});
            }
            for (body[used..]) |k| {
                b.offsets[k] = b.pos;
                b.pos += 1;
            }
            return true;
        }
    };

    /// Raw index of syllable boundary `boundary` (0...n).
    pub fn keyIndex(self: Layout, at: usize) ?usize {
        if (at > self.syllable_keys.len or self.syllable_keys.len == 0) return null;
        return if (at < self.syllable_keys.len) self.syllable_keys[at].start else self.syllable_keys[at - 1].end;
    }

    /// Syllable boundary at raw index `key`: the syllables wholly before it.
    pub fn boundary(self: Layout, key: usize) usize {
        var n: usize = 0;
        for (self.syllable_keys) |r| {
            if (r.end <= key) n += 1;
        }
        return n;
    }
};
