//! Learned picks and session pins (port of UserLexicon.swift plus its
//! extensions in LivePreview.swift and CursorSelection.swift).
//!
//! Keying: toneless-concatenated readings ("ㄋㄧㄏㄠ"); context entries
//! "previous|readings"; positional session pins "run#offset@readings" and
//! settled characters "run#@offset". Every string is owned by `gpa`.

const std = @import("std");
const keyboard = @import("keyboard.zig");
const unicode = @import("unicode.zig");
const candidate_mod = @import("candidate.zig");
const Candidate = candidate_mod.Candidate;
const CursorOption = candidate_mod.CursorOption;
const Range = candidate_mod.Range;
const Allocator = std.mem.Allocator;

pub const Record = struct {
    count: i64,
    /// Unix epoch seconds.
    updated_at: f64,
};

pub const Texts = std.ArrayHashMapUnmanaged([]const u8, Record, unicode.StringContext, true);

pub const file_version = 2;
pub const entry_cap = 500;
pub const base_bonus = 6.0;
pub const repeat_bonus = 1.0;
pub const max_bonus = 10.0;
/// Session-pin bonus: dwarfs any word-score gap.
pub const pin_bonus = 1000.0;

pub const ContextRule = struct {
    previous: []const u8,
    text: []const u8,
    bonus: f64,
};

pub const UserLexicon = struct {
    gpa: Allocator,
    entries: std.StringArrayHashMapUnmanaged(Texts) = .empty,

    pub fn init(gpa: Allocator) UserLexicon {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *UserLexicon) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            freeTexts(self.gpa, entry.value_ptr);
        }
        self.entries.deinit(self.gpa);
        self.entries = .empty;
    }

    fn freeTexts(gpa: Allocator, texts: *Texts) void {
        for (texts.keys()) |text| gpa.free(text);
        texts.deinit(gpa);
    }

    pub fn clear(self: *UserLexicon) void {
        self.deinit();
    }

    pub fn clone(self: *const UserLexicon) !UserLexicon {
        var out = UserLexicon.init(self.gpa);
        errdefer out.deinit();
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            var texts = entry.value_ptr.iterator();
            while (texts.next()) |t| try out.put(entry.key_ptr.*, t.key_ptr.*, t.value_ptr.*);
        }
        return out;
    }

    pub fn isEmpty(self: *const UserLexicon) bool {
        return self.entries.count() == 0;
    }

    pub fn count(self: *const UserLexicon) usize {
        var n: usize = 0;
        for (self.entries.values()) |texts| n += texts.count();
        return n;
    }

    pub fn get(self: *const UserLexicon, key: []const u8) ?*Texts {
        return self.entries.getPtr(key);
    }

    pub fn contains(self: *const UserLexicon, key: []const u8, text: []const u8) bool {
        const texts = self.entries.getPtr(key) orelse return false;
        return texts.contains(text);
    }

    /// Adds or overwrites one (key, text) record.
    pub fn put(self: *UserLexicon, key: []const u8, text: []const u8, value: Record) !void {
        const slot = try self.entries.getOrPut(self.gpa, key);
        if (!slot.found_existing) {
            slot.key_ptr.* = try self.gpa.dupe(u8, key);
            slot.value_ptr.* = .empty;
        }
        const t = try slot.value_ptr.getOrPut(self.gpa, text);
        if (!t.found_existing) t.key_ptr.* = try self.gpa.dupe(u8, text);
        t.value_ptr.* = value;
    }

    /// `entries[key] = [text: record]` (replaces every text of the key).
    pub fn setSingle(self: *UserLexicon, key: []const u8, text: []const u8, value: Record) !void {
        self.remove(key);
        try self.put(key, text, value);
    }

    pub fn remove(self: *UserLexicon, key: []const u8) void {
        const kv = self.entries.fetchOrderedRemove(key) orelse return;
        self.gpa.free(kv.key);
        var texts = kv.value;
        freeTexts(self.gpa, &texts);
    }

    fn removeText(self: *UserLexicon, key: []const u8, text: []const u8) void {
        const texts = self.entries.getPtr(key) orelse return;
        const kv = texts.fetchOrderedRemove(text) orelse return;
        self.gpa.free(kv.key);
        if (texts.count() == 0) self.remove(key);
    }

    pub fn record(self: *UserLexicon, key: []const u8, text: []const u8, at: f64) !void {
        if (key.len == 0 or text.len == 0 or unicode.characterCount(text) > 32) return;
        if (self.entries.getPtr(key)) |texts| if (texts.getPtr(text)) |existing| {
            existing.count += 1;
            existing.updated_at = at;
            return self.evictIfNeeded();
        };
        try self.put(key, text, .{ .count = 1, .updated_at = at });
        try self.evictIfNeeded();
    }

    pub fn bonus(self: *const UserLexicon, key: []const u8, text: []const u8) f64 {
        const texts = self.entries.getPtr(key) orelse return 0;
        const r = texts.get(text) orelse return 0;
        return bonusFor(r);
    }

    fn bonusFor(r: Record) f64 {
        return @min(base_bonus + @as(f64, @floatFromInt(r.count - 1)) * repeat_bonus, max_bonus);
    }

    /// Evict lowest (count, oldest) first. Ties go to the earliest inserted
    /// (Swift's order there is unspecified).
    fn evictIfNeeded(self: *UserLexicon) !void {
        var total = self.count();
        while (total > entry_cap) {
            var victim: ?struct { key: []const u8, text: []const u8 } = null;
            var best_count: i64 = std.math.maxInt(i64);
            var best_at: f64 = std.math.floatMax(f64);
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                var texts = entry.value_ptr.iterator();
                while (texts.next()) |t| {
                    const r = t.value_ptr.*;
                    if (r.count < best_count or (r.count == best_count and r.updated_at < best_at)) {
                        best_count = r.count;
                        best_at = r.updated_at;
                        victim = .{ .key = entry.key_ptr.*, .text = t.key_ptr.* };
                    }
                }
            }
            const v = victim orelse break;
            self.removeText(v.key, v.text);
            total -= 1;
        }
    }

    /// Context entries ("previous|readings") indexed by readings; null when
    /// there are none. Lives in `arena`.
    pub fn contextRules(self: *const UserLexicon, arena: Allocator) !?std.StringHashMapUnmanaged(std.ArrayList(ContextRule)) {
        var rules: std.StringHashMapUnmanaged(std.ArrayList(ContextRule)) = .empty;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const bar = std.mem.indexOfScalar(u8, key, '|') orelse continue;
            const slot = try rules.getOrPut(arena, key[bar + 1 ..]);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            var texts = entry.value_ptr.iterator();
            while (texts.next()) |t| {
                try slot.value_ptr.append(arena, .{ .previous = key[0..bar], .text = t.key_ptr.*, .bonus = bonusFor(t.value_ptr.*) });
            }
        }
        return if (rules.count() == 0) null else rules;
    }

    // MARK: - Pins

    /// Pins visible to run `run`: its positional pins with the run prefix
    /// stripped, plus legacy reading-only pins. Null when empty.
    pub fn pinsForRun(self: *const UserLexicon, run: usize) !?UserLexicon {
        var prefix_buf: [24]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{d}#", .{run}) catch unreachable;
        var out = UserLexicon.init(self.gpa);
        errdefer out.deinit();
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const stripped = if (std.mem.startsWith(u8, key, prefix))
                key[prefix.len..]
            else if (std.mem.indexOfScalar(u8, key, '#') == null)
                key
            else
                continue;
            var texts = entry.value_ptr.iterator();
            while (texts.next()) |t| try out.put(stripped, t.key_ptr.*, t.value_ptr.*);
        }
        if (out.isEmpty()) {
            out.deinit();
            return null;
        }
        return out;
    }

    /// Whether any pin names `text` for `readings` (legacy or positional).
    pub fn hasPin(self: *const UserLexicon, readings: []const u8, text: []const u8) bool {
        if (self.contains(readings, text)) return true;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.len > readings.len and key[key.len - readings.len - 1] == '@' and
                std.mem.endsWith(u8, key, readings) and entry.value_ptr.contains(text)) return true;
        }
        return false;
    }

    /// Run-local settled characters ("@offset" keys) -> UTF-16 unit.
    pub fn settledUnits(self: *const UserLexicon, arena: Allocator) !?std.AutoHashMapUnmanaged(i64, u16) {
        var out: std.AutoHashMapUnmanaged(i64, u16) = .empty;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.len == 0 or key[0] != '@') continue;
            const offset = std.fmt.parseInt(i64, key[1..], 10) catch continue;
            if (entry.value_ptr.count() == 0) continue;
            const unit = unicode.utf16Unit(entry.value_ptr.keys()[0], 0) orelse continue;
            try out.put(arena, offset, unit);
        }
        return if (out.count() == 0) null else out;
    }

    /// Automatic pins for accepted text: every word of an earlier run and
    /// every word of the last run ending `keep` syllables before its end,
    /// one per UTF-16 unit ("run#@offset" -> unit).
    pub fn settled(gpa: Allocator, top: Candidate, keep: usize) !UserLexicon {
        var out = UserLexicon.init(gpa);
        errdefer out.deinit();
        if (top.runs.len == 0) return out;
        const last_run = top.runs[top.runs.len - 1];
        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(gpa);
        for (top.alignment) |word| {
            if (word.chars.end > top.utf16_len) continue;
            const in_last = last_run.contains(word.syllables.start);
            if (in_last and @as(i64, word.syllables.end) > @as(i64, last_run.end) - @as(i64, @intCast(keep))) continue;
            const run = top.runIndex(word.syllables.start) orelse continue;
            const run_start = top.charOffset(top.runs[run].start) orelse continue;
            var unit = word.chars.start;
            while (unit < word.chars.end) : (unit += 1) {
                key_buf.clearRetainingCapacity();
                try key_buf.print(gpa, "{d}#@{d}", .{ run, @as(i64, unit) - @as(i64, run_start) });
                const char = try unicode.utf16Slice(gpa, top.text, unit, unit + 1);
                defer if (!isSubslice(char, top.text)) gpa.free(char);
                try out.setSingle(key_buf.items, char, .{ .count = 1, .updated_at = 0 });
            }
        }
        return out;
    }

    /// Session-pin `option` over the displayed `top`, changing nothing but
    /// the option's own span; overlapping older pins are split.
    pub fn pin(self: *UserLexicon, option: CursorOption, top: Candidate) !void {
        const gpa = self.gpa;
        if (option.span.end > top.syllables.len) return;
        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(gpa);
        const option_key = try gpa.dupe(u8, (try top.pinKey(option.span, &key_buf, gpa)) orelse return);
        defer gpa.free(option_key);
        for (top.alignment) |word| {
            if (!word.syllables.overlaps(option.span) or word.syllables.end > top.syllables.len or
                word.chars.end > top.utf16_len) continue;
            const text = try unicode.utf16Slice(gpa, top.text, word.chars.start, word.chars.end);
            defer if (!isSubslice(text, top.text)) gpa.free(text);
            const key = (try top.pinKey(word.syllables, &key_buf, gpa)) orelse continue;
            if (!self.contains(key, text)) continue;
            self.remove(key);
            if (word.chars.len() != word.syllables.len()) continue;
            var index = word.syllables.start;
            while (index < word.syllables.end) : (index += 1) {
                if (option.span.contains(index)) continue;
                const unit = word.chars.start + (index - word.syllables.start);
                const single_key = (try top.pinKey(Range.of(index, index + 1), &key_buf, gpa)) orelse continue;
                const char = try unicode.utf16Slice(gpa, top.text, unit, unit + 1);
                defer if (!isSubslice(char, top.text)) gpa.free(char);
                try self.setSingle(single_key, char, .{ .count = 1, .updated_at = 0 });
            }
        }
        try self.setSingle(option_key, option.text, .{ .count = 1, .updated_at = 0 });
    }

    /// Pin the words of `picked` that differ from `baseline` (every word
    /// when the two do not line up char for char).
    pub fn pinDifferences(self: *UserLexicon, picked: Candidate, baseline: Candidate) !void {
        const gpa = self.gpa;
        for (picked.alignment) |word| {
            if (word.chars.end > picked.utf16_len) continue;
            const text = try unicode.utf16Slice(gpa, picked.text, word.chars.start, word.chars.end);
            defer if (!isSubslice(text, picked.text)) gpa.free(text);
            if (baseline.utf16_len == picked.utf16_len) {
                const base = try unicode.utf16Slice(gpa, baseline.text, word.chars.start, word.chars.end);
                defer if (!isSubslice(base, baseline.text)) gpa.free(base);
                if (unicode.equal(base, text)) continue;
            }
            try self.pin(.{ .text = text, .span = word.syllables, .score = 0 }, picked);
        }
    }

    // MARK: - Persistence

    pub fn encode(self: *const UserLexicon, gpa: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"version\":{d},\"entries\":{{", .{file_version});
        const keys = try gpa.dupe([]const u8, self.entries.keys());
        defer gpa.free(keys);
        std.mem.sort([]const u8, keys, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return unicode.lessThan(a, b);
            }
        }.lt);
        for (keys, 0..) |key, i| {
            if (i > 0) try w.writeByte(',');
            try std.json.Stringify.value(key, .{}, w);
            try w.writeAll(":{");
            const texts = self.entries.getPtr(key).?;
            const names = try gpa.dupe([]const u8, texts.keys());
            defer gpa.free(names);
            std.mem.sort([]const u8, names, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return unicode.lessThan(a, b);
                }
            }.lt);
            for (names, 0..) |name, j| {
                if (j > 0) try w.writeByte(',');
                const r = texts.get(name).?;
                try std.json.Stringify.value(name, .{}, w);
                try w.print(":{{\"count\":{d},\"updatedAt\":{d}}}", .{ r.count, r.updated_at });
            }
            try w.writeByte('}');
        }
        try w.writeAll("}}");
        return out.toOwnedSlice();
    }

    /// Empty for another file version (v1 files reset, as in Swift).
    pub fn decode(gpa: Allocator, data: []const u8) !UserLexicon {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{});
        defer parsed.deinit();
        var out = UserLexicon.init(gpa);
        errdefer out.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidFormat,
        };
        const version = root.get("version") orelse return error.InvalidFormat;
        if (version != .integer) return error.InvalidFormat;
        if (version.integer != file_version) return out;
        const entries = switch (root.get("entries") orelse return error.InvalidFormat) {
            .object => |o| o,
            else => return error.InvalidFormat,
        };
        var it = entries.iterator();
        while (it.next()) |entry| {
            const texts = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => return error.InvalidFormat,
            };
            var tt = texts.iterator();
            while (tt.next()) |t| {
                const r = switch (t.value_ptr.*) {
                    .object => |o| o,
                    else => return error.InvalidFormat,
                };
                const c = r.get("count") orelse return error.InvalidFormat;
                const at = r.get("updatedAt") orelse return error.InvalidFormat;
                try out.put(entry.key_ptr.*, t.key_ptr.*, .{
                    .count = switch (c) {
                        .integer => |n| n,
                        else => return error.InvalidFormat,
                    },
                    .updated_at = number(at) orelse return error.InvalidFormat,
                });
            }
        }
        return out;
    }
};

pub fn number(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// True when `part` points into `whole` (an unallocated slice).
pub fn isSubslice(part: []const u8, whole: []const u8) bool {
    if (part.len == 0) return true;
    const p = @intFromPtr(part.ptr);
    const w = @intFromPtr(whole.ptr);
    return p >= w and p + part.len <= w + whole.len;
}

/// Toneless key of reading strings (UserLexicon.key(forReadings:)).
pub fn keyForReadings(gpa: Allocator, readings: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try candidate_mod.appendReadingsKey(&buf, gpa, readings);
    return buf.toOwnedSlice(gpa);
}

pub const LearnedWord = struct { key: []const u8, text: []const u8 };

/// Word-level learning for one learning-grade commit (see Swift
/// `UserLexicon.learnedWords`). Strings live in `arena`.
pub fn learnedWords(arena: Allocator, committed: Candidate, pins: *const UserLexicon, baseline: ?Candidate) ![]LearnedWord {
    var out: std.ArrayList(LearnedWord) = .empty;
    if (committed.unresolved != 0 or committed.alignment.len == 0) return out.toOwnedSlice(arena);
    if (committed.alignment[committed.alignment.len - 1].syllables.end != committed.syllables.len) return out.toOwnedSlice(arena);
    const whole = committed.alignment.len == 1;
    var key_buf: std.ArrayList(u8) = .empty;
    for (committed.alignment) |word| {
        if (word.chars.end > committed.utf16_len) continue;
        const text = try unicode.utf16Slice(arena, committed.text, word.chars.start, word.chars.end);
        const pin_key = try committed.pinKey(word.syllables, &key_buf, arena);
        const pinned = if (pin_key) |k| pins.contains(k, text) else false;
        var changed = false;
        if (baseline) |base| if (base.utf16_len == committed.utf16_len) {
            changed = !std.mem.eql(u8, try unicode.utf16Slice(arena, base.text, word.chars.start, word.chars.end), text);
        };
        var readings: std.ArrayList(u8) = .empty;
        try candidate_mod.appendKey(&readings, arena, committed.syllables[word.syllables.start..word.syllables.end]);
        if (whole or (word.syllables.len() >= 2 and (pinned or changed))) {
            try out.append(arena, .{ .key = readings.items, .text = text });
        } else if (pinned or changed) {
            var previous: ?candidate_mod.Span = null;
            var i = committed.alignment.len;
            while (i > 0) {
                i -= 1;
                const p = committed.alignment[i];
                if (p.syllables.end == word.syllables.start and p.chars.end == word.chars.start) {
                    previous = p;
                    break;
                }
            }
            const prev = previous orelse continue;
            if (committed.runIndex(prev.syllables.start) != committed.runIndex(word.syllables.start)) continue;
            if (prev.chars.end > committed.utf16_len) continue;
            const before = try unicode.utf16Slice(arena, committed.text, prev.chars.start, prev.chars.end);
            try out.append(arena, .{ .key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ before, readings.items }), .text = text });
        }
    }
    return out.toOwnedSlice(arena);
}

const testing = std.testing;

test "record, bonus, json" {
    var lex = UserLexicon.init(testing.allocator);
    defer lex.deinit();
    try lex.record("ㄉㄚㄉㄨㄟ", "打對", 10);
    try lex.record("ㄉㄚㄉㄨㄟ", "打對", 11);
    try testing.expectEqual(@as(f64, 7), lex.bonus("ㄉㄚㄉㄨㄟ", "打對"));
    const data = try lex.encode(testing.allocator);
    defer testing.allocator.free(data);
    var back = try UserLexicon.decode(testing.allocator, data);
    defer back.deinit();
    try testing.expectEqual(@as(f64, 7), back.bonus("ㄉㄚㄉㄨㄟ", "打對"));
}

test "learned text uses canonical String equality and preserves stored spelling" {
    var lex = UserLexicon.init(std.testing.allocator);
    defer lex.deinit();
    try lex.record("ㄋㄧ", "e\u{301}", 10);
    try lex.record("ㄋㄧ", "é", 11);
    const texts = lex.get("ㄋㄧ").?;
    try std.testing.expectEqual(@as(usize, 1), texts.count());
    try std.testing.expectEqual(@as(i64, 2), texts.get("é").?.count);
    try std.testing.expectEqualStrings("e\u{301}", texts.keys()[0]);
}
