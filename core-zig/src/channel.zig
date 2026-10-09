//! Repair strength and the personal channel model (port of
//! Sources/MisstypeCore/ChannelModel.swift). Keys are physical Zhuyin
//! symbol keys; a pair means "typed `typed`, meant `intended`".
//!
//! Math goes through libc (`exp`, `log`, `pow`), the same libm Swift's
//! Foundation calls, so learned costs match Swift bit for bit.

const std = @import("std");
const keyboard = @import("keyboard.zig");
const Allocator = std.mem.Allocator;

extern "c" fn exp(x: f64) f64;
extern "c" fn log(x: f64) f64;
extern "c" fn pow(x: f64, y: f64) f64;

pub const RepairStrength = enum(u8) {
    off,
    light,
    standard,
    strong,

    /// Added to generic repair costs.
    pub fn costOffset(self: RepairStrength) f64 {
        return if (self == .light) 2 else 0;
    }

    pub fn repairsValidReadings(self: RepairStrength) bool {
        return self == .strong;
    }
};

pub const Sub = struct {
    intended: u8,
    raw: f64,

    pub fn cost(self: Sub) f64 {
        return @max(ChannelModel.floor, self.raw);
    }
};

/// Typed key -> intended key -> repair cost, as the decoder uses it.
pub const ChannelModel = struct {
    pub const floor = 0.5;
    /// Rows indexed by typed key.
    rows: [128][]const Sub = @splat(&.{}),

    pub fn substitutes(self: *const ChannelModel, typed: u8) []const Sub {
        return if (typed < 128) self.rows[typed] else &.{};
    }

    pub fn has(subs: []const Sub, intended: u8) bool {
        for (subs) |s| if (s.intended == intended) return true;
        return false;
    }
};

pub const Pair = struct { typed: u8, intended: u8 };

/// One commit's evidence about how the user mistypes.
pub const Evidence = struct {
    intended: std.ArrayList(u8) = .empty,
    repaired: std.ArrayList(Pair) = .empty,
    explicit: bool = false,
    retypes: []const Pair = &.{},
    reverts: std.ArrayList(Pair) = .empty,

    pub fn isEmpty(self: *const Evidence) bool {
        return self.intended.items.len == 0 and self.retypes.len == 0 and self.reverts.items.len == 0;
    }
};

const PairMap = std.AutoArrayHashMapUnmanaged(u16, f64);

fn pairKey(typed: u8, intended: u8) u16 {
    return @as(u16, typed) << 8 | intended;
}

/// Learns ChannelModel costs from use (see Swift `ChannelLearner`).
pub const ChannelLearner = struct {
    pub const generic_cost = 5.0;
    pub const learned_floor = 1.2;
    pub const half_life = 3000.0;
    pub const prior_opportunities = 50.0;
    pub const retype_weight = 1.0;
    pub const picked_repair_weight = 1.0;
    pub const unchallenged_repair_weight = 0.25;
    pub const revert_weight = 3.0;
    pub const step_down = 0.2;
    pub const step_up = 1.0;

    gpa: Allocator,
    opportunities: std.AutoArrayHashMapUnmanaged(u8, f64) = .empty,
    slips: PairMap = .empty,
    reverts: PairMap = .empty,
    costs: PairMap = .empty,
    /// The published model (rebuilt after every change).
    model_storage: ChannelModel = .{},
    model_subs: std.ArrayList(Sub) = .empty,
    has_model: bool = false,

    pub fn init(gpa: Allocator) ChannelLearner {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ChannelLearner) void {
        self.opportunities.deinit(self.gpa);
        self.slips.deinit(self.gpa);
        self.reverts.deinit(self.gpa);
        self.costs.deinit(self.gpa);
        self.model_subs.deinit(self.gpa);
    }

    /// What the decoder uses; null until some pair is cheaper than generic.
    pub fn model(self: *const ChannelLearner) ?*const ChannelModel {
        return if (self.has_model) &self.model_storage else null;
    }

    fn rebuildModel(self: *ChannelLearner) !void {
        self.model_subs.clearRetainingCapacity();
        self.model_storage = .{};
        self.has_model = false;
        // Group by typed key so every row is one contiguous slice.
        for (0..128) |typed| {
            for (self.costs.keys(), self.costs.values()) |key, cost| {
                if (key >> 8 != typed or cost >= generic_cost) continue;
                try self.model_subs.append(self.gpa, .{ .intended = @intCast(key & 0xFF), .raw = cost });
            }
        }
        var start: usize = 0;
        for (0..128) |typed| {
            var end = start;
            for (self.costs.keys(), self.costs.values()) |key, cost| {
                if (key >> 8 == typed and cost < generic_cost) end += 1;
            }
            if (end > start) {
                self.model_storage.rows[typed] = self.model_subs.items[start..end];
                self.has_model = true;
            }
            start = end;
        }
    }

    pub fn pairCount(self: *const ChannelLearner) usize {
        var n: usize = 0;
        for (self.costs.values()) |cost| {
            if (cost < generic_cost) n += 1;
        }
        return n;
    }

    pub fn target(self: *const ChannelLearner, typed: u8, intended: u8) f64 {
        const key = pairKey(typed, intended);
        const slip = @max(0, (self.slips.get(key) orelse 0) - revert_weight * (self.reverts.get(key) orelse 0));
        const prior = prior_opportunities;
        const rate = (slip + prior * exp(-generic_cost)) / ((self.opportunities.get(intended) orelse 0) + prior);
        return @min(generic_cost, @max(learned_floor, -log(rate)));
    }

    fn valid(pair: Pair) bool {
        return pair.typed != pair.intended and keyboard.isSymbol(pair.typed) and keyboard.isSymbol(pair.intended);
    }

    pub fn observe(self: *ChannelLearner, evidence: *const Evidence) !void {
        if (evidence.isEmpty()) return;
        const gpa = self.gpa;
        const factor = pow(0.5, @as(f64, @floatFromInt(@max(1, evidence.intended.items.len))) / half_life);
        for (self.opportunities.values()) |*v| v.* = v.* * factor;
        for (self.slips.values()) |*v| v.* = v.* * factor;
        for (self.reverts.values()) |*v| v.* = v.* * factor;
        for (evidence.intended.items) |key| {
            if (!keyboard.isSymbol(key)) continue;
            const slot = try self.opportunities.getOrPut(gpa, key);
            if (!slot.found_existing) slot.value_ptr.* = 0;
            slot.value_ptr.* += 1;
        }
        const repair_weight: f64 = if (evidence.explicit) picked_repair_weight else unchallenged_repair_weight;
        for (evidence.repaired.items) |pair| if (valid(pair)) try addTo(&self.slips, gpa, pair, repair_weight);
        for (evidence.retypes) |pair| if (valid(pair)) try addTo(&self.slips, gpa, pair, retype_weight);
        for (evidence.reverts.items) |pair| if (valid(pair)) try addTo(&self.reverts, gpa, pair, 1);
        // Step every known pair toward its target.
        var pairs: std.AutoArrayHashMapUnmanaged(u16, void) = .empty;
        defer pairs.deinit(gpa);
        for (self.slips.keys()) |k| try pairs.put(gpa, k, {});
        for (self.costs.keys()) |k| try pairs.put(gpa, k, {});
        for (pairs.keys()) |key| {
            const typed: u8 = @intCast(key >> 8);
            const intended: u8 = @intCast(key & 0xFF);
            const current = self.costs.get(key) orelse generic_cost;
            const goal = self.target(typed, intended);
            const next = if (goal < current) @max(goal, current - step_down) else @min(goal, current + step_up);
            try self.costs.put(gpa, key, next);
            if (next >= generic_cost and (self.slips.get(key) orelse 0) < 0.01) {
                _ = self.costs.orderedRemove(key);
                _ = self.slips.orderedRemove(key);
                _ = self.reverts.orderedRemove(key);
            }
        }
        try self.rebuildModel();
    }

    fn addTo(map: *PairMap, gpa: Allocator, pair: Pair, weight: f64) !void {
        const slot = try map.getOrPut(gpa, pairKey(pair.typed, pair.intended));
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += weight;
    }

    // MARK: - Persistence (Swift Codable layout, sorted keys)

    pub fn encode(self: *const ChannelLearner, gpa: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"costs\":");
        try writePairs(w, &self.costs);
        try w.writeAll(",\"opportunities\":{");
        var first = true;
        for (0..128) |k| {
            const v = self.opportunities.get(@intCast(k)) orelse continue;
            if (!first) try w.writeByte(',');
            first = false;
            try writeKey(w, @intCast(k));
            try w.print(":{d}", .{v});
        }
        try w.writeAll("},\"reverts\":");
        try writePairs(w, &self.reverts);
        try w.writeAll(",\"slips\":");
        try writePairs(w, &self.slips);
        try w.writeByte('}');
        return out.toOwnedSlice();
    }

    fn writeKey(w: *std.Io.Writer, k: u8) !void {
        try std.json.Stringify.value(@as([]const u8, &.{k}), .{}, w);
    }

    fn writePairs(w: *std.Io.Writer, map: *const PairMap) !void {
        try w.writeByte('{');
        var first_row = true;
        for (0..128) |typed| {
            var any = false;
            for (0..128) |intended| {
                const v = map.get(pairKey(@intCast(typed), @intCast(intended))) orelse continue;
                if (!any) {
                    if (!first_row) try w.writeByte(',');
                    first_row = false;
                    try writeKey(w, @intCast(typed));
                    try w.writeAll(":{");
                } else try w.writeByte(',');
                any = true;
                try writeKey(w, @intCast(intended));
                try w.print(":{d}", .{v});
            }
            if (any) try w.writeByte('}');
        }
        try w.writeByte('}');
    }

    pub fn decode(gpa: Allocator, data: []const u8) !ChannelLearner {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{});
        defer parsed.deinit();
        var out = ChannelLearner.init(gpa);
        errdefer out.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidFormat,
        };
        if (root.get("opportunities")) |v| {
            const o = switch (v) {
                .object => |o| o,
                else => return error.InvalidFormat,
            };
            var it = o.iterator();
            while (it.next()) |e| {
                const k = keyboard.single(e.key_ptr.*) orelse continue;
                try out.opportunities.put(gpa, k, @import("user_lexicon.zig").number(e.value_ptr.*) orelse return error.InvalidFormat);
            }
        } else return error.InvalidFormat;
        try readPairs(gpa, root.get("slips") orelse return error.InvalidFormat, &out.slips);
        try readPairs(gpa, root.get("reverts") orelse return error.InvalidFormat, &out.reverts);
        try readPairs(gpa, root.get("costs") orelse return error.InvalidFormat, &out.costs);
        try out.rebuildModel();
        return out;
    }

    fn readPairs(gpa: Allocator, value: std.json.Value, map: *PairMap) !void {
        const rows = switch (value) {
            .object => |o| o,
            else => return error.InvalidFormat,
        };
        var it = rows.iterator();
        while (it.next()) |row| {
            const typed = keyboard.single(row.key_ptr.*) orelse continue;
            const cols = switch (row.value_ptr.*) {
                .object => |o| o,
                else => return error.InvalidFormat,
            };
            var ct = cols.iterator();
            while (ct.next()) |col| {
                const intended = keyboard.single(col.key_ptr.*) orelse continue;
                try map.put(gpa, pairKey(typed, intended), @import("user_lexicon.zig").number(col.value_ptr.*) orelse return error.InvalidFormat);
            }
        }
    }
};

/// The one-key substitution turning `typed` into `intended`, if that is all
/// that differs.
pub fn substitution(typed: []const u8, intended: []const u8) ?Pair {
    if (typed.len != intended.len) return null;
    var found: ?Pair = null;
    for (typed, intended) |t, i| {
        if (t == i) continue;
        if (found != null) return null;
        found = .{ .typed = t, .intended = i };
    }
    return found;
}

test "learner moves toward a repeated slip" {
    var learner = ChannelLearner.init(std.testing.allocator);
    defer learner.deinit();
    var evidence: Evidence = .{ .explicit = true };
    defer evidence.intended.deinit(std.testing.allocator);
    defer evidence.repaired.deinit(std.testing.allocator);
    try evidence.intended.appendSlice(std.testing.allocator, "p");
    try evidence.repaired.append(std.testing.allocator, .{ .typed = '/', .intended = 'p' });
    for (0..20) |_| try learner.observe(&evidence);
    try std.testing.expect(learner.model() != null);
    try std.testing.expectEqual(@as(usize, 1), learner.pairCount());
    const data = try learner.encode(std.testing.allocator);
    defer std.testing.allocator.free(data);
    var back = try ChannelLearner.decode(std.testing.allocator, data);
    defer back.deinit();
    try std.testing.expectEqual(@as(usize, 1), back.pairCount());
}
