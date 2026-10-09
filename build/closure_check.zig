//! Holds the headers a copy of a C file carries (`Own` in build.zig) to
//! the ones the compiler reads:
//!
//!     closure-check <root> <file> <deps> <header>...
//!
//! `<deps>` is the `-MM` dependency list `zig cc` wrote for `<file>`, a
//! path of the tree under `<root>`, and each `<header>` a path the copy
//! holds. A dependency inside the tree's `core/` or `test/` that the copy
//! does not hold fails the check, naming both: the file would be compiled
//! from a copy that lacks it, and an edit to it would leave the object
//! stale.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) fatal("usage: closure-check <root> <file> <deps> <header>...", .{});
    const root = std.mem.trimEnd(u8, args[1], "/");
    const file = args[2];
    const text = try Io.Dir.cwd().readFileAlloc(io, args[3], arena, .limited(1 << 24));
    const held = args[4..];
    var missing: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (tokens.next()) |token| {
        // The target (`x.o:`), and the continuation of a line.
        if (std.mem.eql(u8, token, "\\") or std.mem.endsWith(u8, token, ":")) continue;
        if (!std.mem.startsWith(u8, token, root) or token.len <= root.len or token[root.len] != '/') continue;
        const relative = token[root.len + 1 ..];
        if (!std.mem.startsWith(u8, relative, "core/") and !std.mem.startsWith(u8, relative, "test/")) continue;
        for (held) |name| {
            if (std.mem.eql(u8, name, relative)) break;
        } else {
            std.debug.print("closure-check: {s} includes {s}, which its copy does not hold\n", .{ file, relative });
            missing += 1;
        }
    }
    if (missing != 0) std.process.exit(1);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("closure-check: " ++ format ++ "\n", args);
    std.process.exit(1);
}
