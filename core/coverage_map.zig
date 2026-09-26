//! The block-to-line table a core observing its own C carries
//! (`core/coverage.c`). clang's sancov gives every basic block of the
//! instrumented files one flag byte, in `__sancov_bools`, and one entry
//! in `__sancov_pcs` naming the block's address; both are in link order.
//! This reads a linked core's PC table, resolves each block's address to
//! the line it begins on through the core's DWARF (in an ELF core itself;
//! in the objects a Mach-O core's debug map names), and writes the answer
//! as C indexed by block, with whether each block is its function's entry
//! and, for an entry, its function's name from the first link's symbols:
//!
//!     coverage-map write <first> <out.c> <root>...
//!     coverage-map check <first> <second>
//!
//! `write` maps a first link, which has no table and keeps its debug
//! information. `check` holds the second link, the one carrying the table
//! and stripped like any shipped core, to the first: the table is only
//! true of a link with the same blocks in the same order, so the two must
//! have as many blocks, each with the same flags, at the same distance
//! from the first block. Only blocks on lines of files under a `<root>/core/`
//! are mapped, by repository path; any other block (inlined from a vendored
//! header, or on compiler-made code with no line) is mapped to nothing.
//! Each `<root>` is a copy of the tree's own sources in zig's cache, as
//! the core is compiled from them (build.zig's `Own`), laid out as the
//! tree is: its `core/x.c` is the tree's.

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
    const mode = if (args.len > 1) args[1] else "";
    if (std.mem.eql(u8, mode, "write") and args.len >= 5) {
        const table = try generate(arena, io, args[2], args[4..]);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = table });
    } else if (std.mem.eql(u8, mode, "check") and args.len == 4) {
        const first = try blocksOf(arena, io, args[2]);
        const second = try blocksOf(arena, io, args[3]);
        if (first.count != second.count)
            fatal("{s} has {d} blocks, {s} {d}; " ++ different_code, .{ args[3], second.count, args[2], first.count });
        for (0..first.count) |i| {
            const a = read(u64, first.pcs, i * 16) -% read(u64, first.pcs, 0);
            const b = read(u64, second.pcs, i * 16) -% read(u64, second.pcs, 0);
            if (a != b or read(u64, first.pcs, i * 16 + 8) != read(u64, second.pcs, i * 16 + 8))
                fatal("{s}: block {d} is not the one {s} mapped; " ++ different_code, .{ args[3], i, args[2] });
        }
    } else {
        fatal("usage: coverage-map write <first> <out.c> <root>... | check <first> <second>", .{});
    }
}

/// What a check failure means: the two links of one core compiled
/// different sources. Both links compile the same files, so the usual
/// cause is a source edited while the build ran, landing in one link and
/// not the other.
const different_code = "the two links hold different code, most likely because a source " ++
    "changed during the build; run the build again";

/// A core's sancov PC table: one (address, flags) pair of words per block.
const Blocks = struct { pcs: []const u8, count: usize, format: Format };

fn blocksOf(arena: Allocator, io: Io, core_path: []const u8) !Blocks {
    const file = try Io.Dir.cwd().readFileAlloc(io, core_path, arena, .limited(1 << 31));
    const kind = objectFormat(file);
    const pcs = section(file, kind.ofmt, "__sancov_pcs") orelse fatal("{s} has no sancov PC table", .{core_path});
    const flags = section(file, kind.ofmt, "__sancov_bools") orelse fatal("{s} has no sancov flags", .{core_path});
    const count = pcs.data.len / 16;
    if (pcs.data.len % 16 != 0 or flags.data.len != count)
        fatal("{s}: {d} flags for a {d}-byte PC table", .{ core_path, flags.data.len, pcs.data.len });
    return .{ .pcs = pcs.data, .count = count, .format = kind };
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("coverage-map: " ++ format ++ "\n", args);
    std.process.exit(1);
}

const Section = struct { data: []const u8 };

/// The kind of file a core is, as `std.debug.Info.load` wants it.
const Format = struct { ofmt: std.Target.ObjectFormat, arch: std.Target.Cpu.Arch };

/// Which of the two 64-bit little-endian formats a core is linked as:
/// ELF on Linux, Mach-O on macOS.
fn objectFormat(file: []const u8) Format {
    if (file.len >= 64 and std.mem.eql(u8, file[0..4], "\x7fELF") and file[4] == 2 and file[5] == 1) {
        return .{ .ofmt = .elf, .arch = switch (read(u16, file, 0x12)) {
            0x3e => .x86_64,
            0xb7 => .aarch64,
            else => |machine| fatal("unsupported ELF machine {d}", .{machine}),
        } };
    }
    if (file.len >= 32 and read(u32, file, 0) == 0xfeedfacf) {
        return .{ .ofmt = .macho, .arch = switch (read(u32, file, 4)) {
            0x01000007 => .x86_64,
            0x0100000c => .aarch64,
            else => |cpu| fatal("unsupported Mach-O CPU {x}", .{cpu}),
        } };
    }
    fatal("not a 64-bit little-endian ELF or Mach-O file", .{});
}

/// A section of the core, by name: in ELF, among the section headers; in
/// Mach-O, among the sections of the `LC_SEGMENT_64` load commands. Either
/// way its bytes are what the file holds.
fn section(file: []const u8, ofmt: std.Target.ObjectFormat, name: []const u8) ?Section {
    return switch (ofmt) {
        .elf => elfSection(file, name),
        .macho => machoSection(file, name),
        else => unreachable,
    };
}

fn elfSection(file: []const u8, name: []const u8) ?Section {
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
        return .{ .data = file[offset..][0..size] };
    }
    return null;
}

/// Zig's Mach-O linker records rebases as dyld opcodes, not chained
/// fixups, so a pointer section holds plain link-time addresses.
fn machoSection(file: []const u8, name: []const u8) ?Section {
    const lc_segment_64 = 0x19;
    const ncmds = read(u32, file, 16);
    var command: u64 = 32; // past the 64-bit header
    for (0..ncmds) |_| {
        const cmd = read(u32, file, command);
        const cmdsize = read(u32, file, command + 4);
        if (cmd == lc_segment_64) {
            const nsects = read(u32, file, command + 64);
            for (0..nsects) |i| {
                const header = command + 72 + i * 80;
                const found = std.mem.sliceTo(file[header..][0..16], 0);
                if (!std.mem.eql(u8, found, name)) continue;
                const size = read(u64, file, header + 40);
                const offset = read(u32, file, header + 48);
                return .{ .data = file[offset..][0..size] };
            }
        }
        command += cmdsize;
    }
    return null;
}

const Symbol = struct { address: u64, name: []const u8 };

/// A first link's function symbols, ascending by address: an ELF file's
/// `.symtab` functions, or a Mach-O file's section symbols less the
/// leading underscore Mach-O gives every C name.
fn functionSymbols(arena: Allocator, file: []const u8, ofmt: std.Target.ObjectFormat) ![]Symbol {
    var found: std.ArrayList(Symbol) = .empty;
    switch (ofmt) {
        .elf => {
            const table = (elfSection(file, ".symtab") orelse return &.{}).data;
            const names = (elfSection(file, ".strtab") orelse return &.{}).data;
            var at: usize = 0;
            while (at + 24 <= table.len) : (at += 24) {
                if (table[at + 4] & 0xf != 2) continue; // STT_FUNC
                const name = std.mem.sliceTo(names[read(u32, table, at)..], 0);
                try found.append(arena, .{ .address = read(u64, table, at + 8), .name = name });
            }
        },
        .macho => {
            const lc_symtab = 0x2;
            const ncmds = read(u32, file, 16);
            var command: u64 = 32;
            for (0..ncmds) |_| {
                if (read(u32, file, command) == lc_symtab) {
                    const symoff = read(u32, file, command + 8);
                    const nsyms = read(u32, file, command + 12);
                    const stroff = read(u32, file, command + 16);
                    for (0..nsyms) |i| {
                        const entry = symoff + i * 16;
                        const kind = file[entry + 4];
                        if (kind & 0xe0 != 0 or kind & 0x0e != 0x0e) continue; // a stab, or not in a section
                        var name = std.mem.sliceTo(file[stroff + read(u32, file, entry) ..], 0);
                        if (name.len > 0 and name[0] == '_') name = name[1..];
                        try found.append(arena, .{ .address = read(u64, file, entry + 8), .name = name });
                    }
                }
                command += read(u32, file, command + 4);
            }
        },
        else => unreachable,
    }
    std.mem.sort(Symbol, found.items, {}, struct {
        fn lessThan(_: void, a: Symbol, b: Symbol) bool {
            return a.address < b.address;
        }
    }.lessThan);
    return found.items;
}

/// The function `pc` lies in: the last symbol at or before it.
fn functionAt(symbols: []const Symbol, pc: u64) ?[]const u8 {
    var low: usize = 0;
    var high: usize = symbols.len;
    while (low < high) {
        const middle = (low + high) / 2;
        if (symbols[middle].address <= pc) low = middle + 1 else high = middle;
    }
    return if (low == 0) null else symbols[low - 1].name;
}

fn read(comptime T: type, file: []const u8, at: u64) T {
    return std.mem.readInt(T, file[at..][0..@sizeOf(T)], .little);
}

fn generate(arena: Allocator, io: Io, core_path: []const u8, roots: []const []const u8) ![]const u8 {
    const found = try blocksOf(arena, io, core_path);
    const kind = found.format;
    const pcs = found.pcs;
    const count = found.count;

    const Block = struct { pc: u64, index: u32, location: Coverage.SourceLocation };
    var blocks: std.MultiArrayList(Block) = .empty;
    try blocks.resize(arena, count);
    for (blocks.items(.pc), blocks.items(.index), 0..) |*pc, *index, i| {
        pc.* = read(u64, pcs, i * 16);
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
    }, &coverage, kind.ofmt, kind.arch);
    try info.resolveAddresses(arena, io, blocks.items(.pc), blocks.items(.location));

    // Each block's line and repository path, by the block's own index, and
    // whether it is its function's entry: bit 0 of the PC table's second word.
    const lines = try arena.alloc(u32, count);
    const entries = try arena.alloc(bool, count);
    for (entries, 0..) |*entry, i| entry.* = read(u64, pcs, i * 16 + 8) & 1 != 0;
    // Each entry's function, by name, for a caller to report and exempt.
    const file = try Io.Dir.cwd().readFileAlloc(io, core_path, arena, .limited(1 << 31));
    const symbols = try functionSymbols(arena, file, kind.ofmt);
    const functions = try arena.alloc(?[]const u8, count);
    for (functions, entries, 0..) |*function, entry, i| {
        function.* = if (entry) functionAt(symbols, read(u64, pcs, i * 16)) else null;
    }
    const files = try arena.alloc(?[]const u8, count);
    var paths: std.StringArrayHashMapUnmanaged(void) = .empty;
    // A root, and a line's directory, may be relative to the directory
    // the build runs in -- zig's cache named relative to it, as a local
    // CI run's under the candidate's o/ is -- which is this one's too.
    const here = try std.process.currentPathAlloc(io, arena);
    const prefixes = try arena.alloc([]const u8, roots.len);
    for (prefixes, roots) |*prefix, root| {
        const absolute = try std.fs.path.resolvePosix(arena, &.{ here, root });
        prefix.* = try std.fmt.allocPrint(arena, "{s}/", .{std.mem.trimEnd(u8, absolute, "/")});
    }
    for (blocks.items(.index), blocks.items(.location)) |index, location| {
        lines[index] = location.line;
        files[index] = null;
        if (location.file == .invalid or location.line == 0) continue;
        const source = coverage.fileAt(location.file);
        const directory = coverage.stringAt(coverage.directories.keys()[source.directory_index]);
        const absolute = try std.fs.path.resolvePosix(arena, &.{
            here, directory, coverage.stringAt(source.basename),
        });
        for (prefixes) |prefix| {
            if (!std.mem.startsWith(u8, absolute, prefix)) continue;
            const relative = absolute[prefix.len..];
            if (!std.mem.startsWith(u8, relative, "core/")) continue;
            files[index] = relative;
            try paths.put(arena, relative, {});
            break;
        }
    }
    if (paths.count() == 0) fatal("{s}: no block resolves to a line under a root's core/", .{core_path});
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
    try w.writeAll("};\n\nconst uint8_t cosmic_native_coverage_entry[] = {\n");
    for (entries, 0..) |entry, i| {
        try w.print("{s}{d},", .{ if (i % 12 == 0) "  " else " ", @intFromBool(entry) });
        if (i % 12 == 11 or i == count - 1) try w.writeAll("\n");
    }
    try w.writeAll("};\n\nconst char *const cosmic_native_coverage_function[] = {\n");
    for (functions) |function| {
        if (function) |name| try w.print("  \"{s}\",\n", .{name}) else try w.writeAll("  0,\n");
    }
    try w.writeAll("};\n");
    return out.written();
}
