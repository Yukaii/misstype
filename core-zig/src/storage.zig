//! Local files and clocks for the engine: user data paths, atomic writes,
//! modification stamps. Missing or unreadable files are empty data, never
//! errors (the offline baseline).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn read(io: Io, gpa: Allocator, path: []const u8) ?[]u8 {
    const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return null;
    if (!std.unicode.utf8ValidateSlice(data)) {
        gpa.free(data);
        return null;
    }
    return data;
}

/// Write via a temporary file and rename, creating the directory first.
pub fn writeAtomic(io: Io, gpa: Allocator, path: []const u8, data: []const u8) bool {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch return false;
    const tmp = std.fmt.allocPrint(gpa, "{s}.misstype-tmp", .{path}) catch return false;
    defer gpa.free(tmp);
    defer cwd.deleteFile(io, tmp) catch {};
    cwd.writeFile(io, .{ .sub_path = tmp, .data = data }) catch return false;
    Io.Dir.rename(cwd, tmp, cwd, path, io) catch return false;
    return true;
}

/// Modification time in nanoseconds, null when the file is missing.
pub fn mtime(io: Io, path: []const u8) ?i96 {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return stat.mtime.nanoseconds;
}

/// Seconds since the Unix epoch (record timestamps).
pub fn nowUnix(io: Io) f64 {
    const ns = Io.Timestamp.now(io, .real).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / 1e9;
}

/// Seconds on a monotonic clock (Shift-tap timing when the host sends none).
pub fn nowMonotonic(io: Io) f64 {
    const ns = Io.Timestamp.now(io, .awake).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / 1e9;
}

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

/// Directory of the user data files: ~/Library/Application Support/Misstype
/// on macOS, $XDG_DATA_HOME/misstype (absolute only, default
/// ~/.local/share/misstype) elsewhere.
pub fn dataDirectory(gpa: Allocator) ![]u8 {
    const home = getenv("HOME") orelse "";
    if (builtin.os.tag == .macos) return std.fmt.allocPrint(gpa, "{s}/Library/Application Support/Misstype", .{home});
    if (getenv("XDG_DATA_HOME")) |xdg| if (xdg.len > 0 and xdg[0] == '/') return std.fmt.allocPrint(gpa, "{s}/misstype", .{xdg});
    return std.fmt.allocPrint(gpa, "{s}/.local/share/misstype", .{home});
}

pub fn defaultPath(gpa: Allocator, file: []const u8) ![]u8 {
    const dir = try dataDirectory(gpa);
    defer gpa.free(dir);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, file });
}
