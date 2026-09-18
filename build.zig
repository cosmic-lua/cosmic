//! The C build: the patch applier, the patched vendor trees, and the core
//! executable for each target.
//!
//!     bin/zig build cores     the core for all three targets
//!     bin/zig build boot      the host core, then the boot bridge
//!
//! Everything lands under `o/`, which is the only thing to delete. Run it
//! through `bin/zig`, which pins the compiler and points both zig caches
//! at `o/` as well.

const std = @import("std");
const builtin = @import("builtin");

/// The one zig this tree builds with. `bin/zig.pin` names the same version
/// and the sha256 of each host's tarball; this check is what makes a zig
/// from anywhere else fail at the first line rather than somewhere in the
/// middle of a C file.
const pinned_zig = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0 };

comptime {
    if (builtin.zig_version.order(pinned_zig) != .eq) {
        @compileError("cosmic pins zig 0.16.0; run bin/zig");
    }
}

const Target = struct {
    /// The name the database and `o/bin/` use.
    name: []const u8,
    query: std.Target.Query,
};

const targets = [_]Target{
    .{ .name = "x86_64-linux-musl", .query = .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    } },
    .{ .name = "aarch64-linux-musl", .query = .{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .musl,
    } },
    .{ .name = "aarch64-macos", .query = .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    } },
};

/// Lua's own sources, minus the two that hold a `main`.
const lua_sources = [_][]const u8{
    "lapi.c",     "lauxlib.c",  "lbaselib.c", "lcode.c",
    "lcorolib.c", "lctype.c",   "ldblib.c",   "ldebug.c",
    "ldo.c",      "ldump.c",    "lfunc.c",    "lgc.c",
    "linit.c",    "liolib.c",   "llex.c",     "lmathlib.c",
    "lmem.c",     "loadlib.c",  "lobject.c",  "lopcodes.c",
    "loslib.c",   "lparser.c",  "lstate.c",   "lstring.c",
    "lstrlib.c",  "ltable.c",   "ltablib.c",  "ltm.c",
    "lundump.c",  "lutf8lib.c", "lvm.c",      "lzio.c",
};

const core_sources = [_][]const u8{
    "boot.c",
    "locate.c",
    "main.c",
    "sha256.c",
    "sqlite.c",
    "store.c",
    "surface.c",
    "syscalls.c",
    "syscalls_fs.c",
    "vfs.c",
};

pub fn build(b: *std.Build) void {
    const sanitize = b.option(bool, "sanitize", "build the sanitized core") orelse false;

    // The applier is a host tool, built before anything it feeds.
    const applier = b.addExecutable(.{
        .name = "patch",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    applier.root_module.addCSourceFile(.{
        .file = b.path("core/patch.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });

    const lua = patched(b, applier, "lua");
    const sqlite = patched(b, applier, "sqlite");
    const tl = patched(b, applier, "tl");
    const miniz = patched(b, applier, "miniz");

    const cores = b.step("cores", "build the core for every target");
    const boot = b.step("boot", "build the host core, then bridge into Teal");

    for (targets) |t| {
        const resolved = b.resolveTargetQuery(t.query);
        const exe = core(b, resolved, sanitize, lua, sqlite, miniz);
        const out = b.addInstallFile(
            exe.getEmittedBin(),
            b.fmt("core/{s}/cosmic-core", .{t.name}),
        );
        cores.dependOn(&out.step);

        if (std.mem.eql(u8, t.name, hostName(b))) {
            const bridge = b.addRunArtifact(exe);
            bridge.addArg("--boot");
            bridge.addDirectoryArg(b.path("."));
            // The bridge reads the patched tl beside the tree, and every
            // core image, so both are its inputs.
            bridge.addDirectoryArg(tl);
            bridge.step.dependOn(cores);
            bridge.has_side_effects = true;
            boot.dependOn(&bridge.step);
        }
    }

    b.getInstallStep().dependOn(cores);
}

/// The patched copy of one vendored library, as a directory the core's
/// sources are read from. The dependency on the applier is expressed by
/// consuming its output, so nothing declares an order by hand.
fn patched(b: *std.Build, applier: *std.Build.Step.Compile, name: []const u8) std.Build.LazyPath {
    const run = b.addRunArtifact(applier);
    run.addDirectoryArg(b.path(b.fmt("vendor/{s}", .{name})));
    run.addDirectoryArg(b.path(b.fmt("patches/{s}", .{name})));
    return run.addOutputDirectoryArg(name);
}

fn core(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    sanitize: bool,
    lua: std.Build.LazyPath,
    sqlite: std.Build.LazyPath,
    miniz: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const macos = target.result.os.tag == .macos;

    const mod = b.createModule(.{
        .target = target,
        .optimize = if (sanitize) .ReleaseSafe else .ReleaseFast,
        .link_libc = true,
        // Stripping is what makes two builds at different paths produce
        // the same bytes: debug info carries the absolute path.
        .strip = !sanitize,
        .sanitize_c = if (sanitize) .full else .off,
    });

    // LUA_USE_MACOSX drags in readline; POSIX is the whole of what the
    // core needs, and dynamic loading is never wanted.
    const lua_flags: []const []const u8 = if (macos)
        &.{ "-std=c11", "-DLUA_USE_POSIX" }
    else
        &.{ "-std=c11", "-DLUA_USE_LINUX", "-DLUA_USE_READLINE=0" };
    mod.addCSourceFiles(.{
        .root = lua.path(b, "src"),
        .files = &lua_sources,
        .flags = lua_flags,
    });
    mod.addIncludePath(lua.path(b, "src"));

    mod.addCSourceFiles(.{
        .root = sqlite,
        .files = &.{"sqlite3.c"},
        // SQLite's own hook for a configuration header, rather than
        // -include, which zig's C cache does not track.
        .flags = &.{ "-std=c11", "-DSQLITE_CUSTOM_INCLUDE=sqlite_config.h" },
    });
    mod.addIncludePath(sqlite);

    // miniz reaches for fseeko/ftello, which are POSIX rather than C11.
    // Its zlib-compatible aliases are off: the core calls the mz_ names,
    // and the aliases are static wrappers every including file warns on.
    mod.addCSourceFiles(.{
        .root = miniz,
        .files = &.{"miniz.c"},
        .flags = &.{
            "-std=c11",
            "-D_XOPEN_SOURCE=700",
            "-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES",
        },
    });
    mod.addIncludePath(miniz);

    mod.addCSourceFiles(.{
        .root = b.path("core"),
        .files = &core_sources,
        .flags = &.{
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES",
        },
    });
    mod.addIncludePath(b.path("core"));

    return b.addExecutable(.{
        .name = "cosmic-core",
        .root_module = mod,
    });
}

fn hostName(b: *std.Build) []const u8 {
    const host = b.graph.host.result;
    return switch (host.os.tag) {
        .macos => switch (host.cpu.arch) {
            .aarch64 => "aarch64-macos",
            else => "unsupported",
        },
        .linux => switch (host.cpu.arch) {
            .x86_64 => "x86_64-linux-musl",
            .aarch64 => "aarch64-linux-musl",
            else => "unsupported",
        },
        else => "unsupported",
    };
}
