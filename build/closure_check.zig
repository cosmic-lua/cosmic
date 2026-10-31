//! Holds the headers a copy of a C file carries (`Own` in build.zig) to
//! the ones the compiler reads:
//!
//!     closure-check <source> <file> <deps> <header>...
//!
//! `<file>` is a path of the tree, `<source>` its absolute path, which
//! names the tree's root as it is when the check runs, `<deps>` the `-MM`
//! dependency list `zig cc` wrote for `<source>`, and each `<header>` a
//! path the copy holds. A dependency inside the tree's `core/` or `test/`
//! that the copy does not hold fails the check, naming both: the file
//! would be compiled from a copy that lacks it, and an edit to it would
//! leave the object stale. So does a list that does not name `<source>`:
//! one written of another tree would have nothing under this root, and
//! pass having checked nothing.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) fatal("usage: closure-check <source> <file> <deps> <header>...", .{});
    const source = args[1];
    const file = args[2];
    if (!std.fs.path.isAbsolute(source) or !std.mem.endsWith(u8, source, file) or
        source.len <= file.len or source[source.len - file.len - 1] != '/')
        fatal("{s} is not the absolute path of {s}", .{ source, file });
    const root = source[0 .. source.len - file.len - 1];
    const text = try Io.Dir.cwd().readFileAlloc(io, args[3], arena, .limited(1 << 24));
    const held = args[4..];
    var missing: usize = 0;
    var named = false;
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (tokens.next()) |token| {
        // The target (`x.o:`), and the continuation of a line.
        if (std.mem.eql(u8, token, "\\") or std.mem.endsWith(u8, token, ":")) continue;
        if (!std.mem.startsWith(u8, token, root) or token.len <= root.len or token[root.len] != '/') continue;
        const relative = token[root.len + 1 ..];
        if (std.mem.eql(u8, relative, file)) named = true;
        if (!std.mem.startsWith(u8, relative, "core/") and !std.mem.startsWith(u8, relative, "test/")) continue;
        for (held) |name| {
            if (std.mem.eql(u8, name, relative)) break;
        } else {
            std.debug.print("closure-check: {s} includes {s}, which its copy does not hold\n", .{ file, relative });
            missing += 1;
        }
    }
    if (!named) fatal("{s} does not name {s}", .{ args[3], source });
    if (missing != 0) std.process.exit(1);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("closure-check: " ++ format ++ "\n", args);
    std.process.exit(1);
}
