//! The block-to-line table a core observing its own C carries
//! (`core/coverage.c`). clang's sancov gives every basic block of the
//! instrumented files one flag byte, in `__sancov_bools`, and one entry
//! in `__sancov_pcs` naming the block's address; both are in link order.
//! This reads a linked core's PC table, resolves each block's address to
//! the line it begins on through the core's DWARF, and writes the answer
//! as C indexed by block:
//!
//!     coverage-map write <core> <root> <out.c>
//!     coverage-map check <core> <root> <map.c>
//!
//! `write` maps a first link, which has no table. `check` maps the
//! second link, the one carrying the table, and fails unless it says the
//! same: the table is only true of a link holding the same blocks in the
//! same order. Only blocks on lines of files under `<root>/core/` are
//! mapped, by repository path; any other block (inlined from a vendored
//! header, or on compiler-made code with no line) is mapped to nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Coverage = std.debug.Coverage;

/// The path index a block on no mapped line gets.
const no_path = std.math.maxInt(u16);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) fatal("usage: coverage-map write|check <core> <root> <map.c>", .{});
    const mode = args[1];
    const table = try generate(arena, io, args[2], args[3]);
    if (std.mem.eql(u8, mode, "write")) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[4], .data = table });
    } else if (std.mem.eql(u8, mode, "check")) {
        const carried = try Io.Dir.cwd().readFileAlloc(io, args[4], arena, .limited(1 << 30));
        if (!std.mem.eql(u8, carried, table))
            fatal("{s}: its blocks are not the ones {s} maps", .{ args[2], args[4] });
    } else {
        fatal("unknown mode '{s}'", .{mode});
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("coverage-map: " ++ format ++ "\n", args);
    std.process.exit(1);
}

const Section = struct { address: u64, data: []const u8 };

/// A section of a 64-bit little-endian ELF file, by name.
fn section(file: []const u8, name: []const u8) ?Section {
    if (file.len < 64 or !std.mem.eql(u8, file[0..4], "\x7fELF") or file[4] != 2 or file[5] != 1)
        fatal("not a 64-bit little-endian ELF file", .{});
    const shoff = read(u64, file, 0x28);
    const shentsize = read(u16, file, 0x3a);
    const shnum = read(u16, file, 0x3c);
    const shstrndx = read(u16, file, 0x3e);
    const names = shoff + @as(u64, shstrndx) * shentsize;
    const names_offset = read(u64, file, names + 0x18);
    for (0..shnum) |i| {
        const header = shoff + i * shentsize;
        const name_offset = names_offset + read(u32, file, header);
        const found = std.mem.sliceTo(file[name_offset..], 0);
        if (!std.mem.eql(u8, found, name)) continue;
        const offset = read(u64, file, header + 0x18);
        const size = read(u64, file, header + 0x20);
        return .{ .address = read(u64, file, header + 0x10), .data = file[offset..][0..size] };
    }
    return null;
}

fn read(comptime T: type, file: []const u8, at: u64) T {
    return std.mem.readInt(T, file[at..][0..@sizeOf(T)], .little);
}

fn generate(arena: Allocator, io: Io, core_path: []const u8, root: []const u8) ![]const u8 {
    const file = try Io.Dir.cwd().readFileAlloc(io, core_path, arena, .limited(1 << 31));
    const pcs = section(file, "__sancov_pcs") orelse fatal("{s} has no sancov PC table", .{core_path});
    const flags = section(file, "__sancov_bools") orelse fatal("{s} has no sancov flags", .{core_path});
    // One (address, flags) pair of words per block.
    const count = pcs.data.len / 16;
    if (pcs.data.len % 16 != 0 or flags.data.len != count)
        fatal("{s}: {d} flags for a {d}-byte PC table", .{ core_path, flags.data.len, pcs.data.len });

    const Block = struct { pc: u64, index: u32, location: Coverage.SourceLocation };
    var blocks: std.MultiArrayList(Block) = .empty;
    try blocks.resize(arena, count);
    for (blocks.items(.pc), blocks.items(.index), 0..) |*pc, *index, i| {
        pc.* = read(u64, pcs.data, i * 16);
        // A position-independent link leaves these for the loader to fill.
        if (pc.* == 0) fatal("{s}: the PC table is not filled in; link without PIE", .{core_path});
        index.* = @intCast(i);
    }
    blocks.sortUnstable(struct {
        pcs: []const u64,
        pub fn lessThan(context: @This(), a: usize, b: usize) bool {
            return context.pcs[a] < context.pcs[b];
        }
    }{ .pcs = blocks.items(.pc) });

    var coverage: Coverage = .init;
    var info = try std.debug.Info.load(arena, io, .{
        .root_dir = .cwd(),
        .sub_path = core_path,
    }, &coverage, .elf, @import("builtin").cpu.arch);
    try info.resolveAddresses(arena, io, blocks.items(.pc), blocks.items(.location));

    // Each block's line and repository path, by the block's own index.
    const lines = try arena.alloc(u32, count);
    const files = try arena.alloc(?[]const u8, count);
    var paths: std.StringArrayHashMapUnmanaged(void) = .empty;
    const prefix = try std.fmt.allocPrint(arena, "{s}/", .{std.mem.trimEnd(u8, root, "/")});
    for (blocks.items(.index), blocks.items(.location)) |index, location| {
        lines[index] = location.line;
        files[index] = null;
        if (location.file == .invalid or location.line == 0) continue;
        const source = coverage.fileAt(location.file);
        const directory = coverage.stringAt(coverage.directories.keys()[source.directory_index]);
        const absolute = try std.fs.path.resolvePosix(arena, &.{
            root, directory, coverage.stringAt(source.basename),
        });
        if (!std.mem.startsWith(u8, absolute, prefix)) continue;
        const relative = absolute[prefix.len..];
        if (!std.mem.startsWith(u8, relative, "core/")) continue;
        files[index] = relative;
        try paths.put(arena, relative, {});
    }
    if (paths.count() == 0) fatal("{s}: no block resolves to a line under {s}core/", .{ core_path, prefix });
    if (paths.count() >= no_path) fatal("{s}: too many files to index", .{core_path});
    paths.sort(struct {
        keys: []const []const u8,
        pub fn lessThan(context: @This(), a: usize, b: usize) bool {
            return std.mem.lessThan(u8, context.keys[a], context.keys[b]);
        }
    }{ .keys = paths.keys() });

    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print(
        \\/* Generated by core/coverage_map.zig: which line each of this core's
        \\ * {d} sancov blocks begins on, by block. Not a source file. */
        \\#include <stdint.h>
        \\
        \\const uint32_t cosmic_native_coverage_blocks = {d};
        \\
        \\const char *const cosmic_native_coverage_paths[] = {{
        \\
    , .{ count, count });
    for (paths.keys()) |path| try w.print("  \"{s}\",\n", .{path});
    try w.writeAll("};\n\nconst uint16_t cosmic_native_coverage_path[] = {\n");
    for (files, 0..) |path, i| {
        const index: usize = if (path) |p| paths.getIndex(p).? else no_path;
        try w.print("{s}{d},", .{ if (i % 12 == 0) "  " else " ", index });
        if (i % 12 == 11 or i == count - 1) try w.writeAll("\n");
    }
    try w.writeAll("};\n\nconst uint32_t cosmic_native_coverage_line[] = {\n");
    for (lines, 0..) |line, i| {
        try w.print("{s}{d},", .{ if (i % 12 == 0) "  " else " ", line });
        if (i % 12 == 11 or i == count - 1) try w.writeAll("\n");
    }
    try w.writeAll("};\n");
    return out.written();
}
