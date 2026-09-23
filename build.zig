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

/// `bin/zig.pin`, read at comptime so there is exactly one place that
/// names the pinned version: this file no longer carries a second,
/// separately-maintained literal that could drift from it.
const zig_pin = @embedFile("bin/zig.pin");

/// The version line out of `bin/zig.pin` ("version X.Y.Z"), parsed at
/// comptime. A missing or malformed line fails the build by name rather
/// than falling back to some default.
fn pinnedZigVersion() std.SemanticVersion {
    var lines = std.mem.splitScalar(u8, zig_pin, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "version ")) {
            const text = std.mem.trim(u8, line["version ".len..], " \t\r");
            return std.SemanticVersion.parse(text) catch
                @compileError("bin/zig.pin: version line does not parse: " ++ text);
        }
    }
    @compileError("bin/zig.pin: no version line");
}

// The one zig this tree builds with. This check is what makes a zig
// from anywhere else fail at the first line rather than somewhere in the
// middle of a C file.
comptime {
    const pinned_zig = pinnedZigVersion();
    if (builtin.zig_version.order(pinned_zig) != .eq) {
        @compileError("cosmic pins the zig version named in bin/zig.pin; run bin/zig");
    }
}

const Target = struct {
    /// Stable identifier used by portable artifact records. Never renumber.
    id: u32,
    /// The name the database and `o/bin/` use.
    name: []const u8,
    /// The pair printed by `uname -s` and `uname -m` on this target.
    uname_os: []const u8,
    uname_arch: []const u8,
    query: std.Target.Query,
};

const Configuration = struct {
    /// Stable identifier used by portable artifact records. Never renumber.
    id: u32,
    name: []const u8,
    sanitize: bool,
};

const release_configuration = Configuration{ .id = 1, .name = "release", .sanitize = false };
const sanitized_configuration = Configuration{ .id = 2, .name = "sanitized", .sanitize = true };

const targets = [_]Target{
    .{ .id = 1, .name = "x86_64-linux-musl", .uname_os = "Linux", .uname_arch = "x86_64", .query = .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    } },
    .{ .id = 2, .name = "aarch64-linux-musl", .uname_os = "Linux", .uname_arch = "aarch64", .query = .{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .musl,
    } },
    .{ .id = 3, .name = "aarch64-macos", .uname_os = "Darwin", .uname_arch = "arm64", .query = .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .abi = .none,
    } },
};

/// Lua's own sources, minus the two that hold a `main` and the unopened
/// standard libraries.
const lua_sources = [_][]const u8{
    "lapi.c",     "lauxlib.c",  "lbaselib.c", "lcode.c",
    "lcorolib.c", "lctype.c",   "ldebug.c",   "ldo.c",
    "ldump.c",    "lfunc.c",    "lgc.c",      "llex.c",
    "lmathlib.c", "lmem.c",     "loadlib.c",  "lobject.c",
    "lopcodes.c", "lparser.c",  "lstate.c",   "lstring.c",
    "lstrlib.c",  "ltable.c",   "ltablib.c",  "ltm.c",
    "lundump.c",  "lutf8lib.c", "lvm.c",      "lzio.c",
};

/// mbedtls's compile-time configuration: digests and HMAC through the
/// PSA API and nothing else, with randomness from the OS rather than
/// the library's own entropy and DRBG modules. Flags rather than a
/// header, for the same reason SQLite's are; the header the library
/// insists on naming is empty. Every file that includes the library's
/// headers is compiled with these, the core's own included, or the
/// headers would describe another library.
const mbedtls_config = [_][]const u8{
    "-DTF_PSA_CRYPTO_CONFIG_FILE=\"crypto_config.h\"",
    "-DPSA_WANT_ALG_MD5=1",
    "-DPSA_WANT_ALG_SHA_1=1",
    "-DPSA_WANT_ALG_SHA_224=1",
    "-DPSA_WANT_ALG_SHA_256=1",
    "-DPSA_WANT_ALG_SHA_384=1",
    "-DPSA_WANT_ALG_SHA_512=1",
    "-DPSA_WANT_ALG_SHA3_224=1",
    "-DPSA_WANT_ALG_SHA3_256=1",
    "-DPSA_WANT_ALG_SHA3_384=1",
    "-DPSA_WANT_ALG_SHA3_512=1",
    "-DPSA_WANT_ALG_HMAC=1",
    "-DPSA_WANT_KEY_TYPE_HMAC=1",
    "-DMBEDTLS_PSA_CRYPTO_C",
    "-DMBEDTLS_PSA_CRYPTO_EXTERNAL_RNG",
    "-DMBEDTLS_PSA_ASSUME_EXCLUSIVE_BUFFERS",
};

const core_sources = [_][]const u8{
    "boot.c",
    "coverage.c",
    "compress.c",
    "crypto.c",
    "environment.c",
    "executable.c",
    "hash.c",
    "sqlite.c",
    "store.c",
    "strnlen.c",
    "surface.c",
    "syscalls.c",
    "syscalls_fs.c",
    "vfs.c",
    "main.c",
    "portable.c",
    "startup.c",
};

pub fn build(b: *std.Build) void {
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
    const mbedtls = patched(b, applier, "mbedtls");
    const bzip2 = patched(b, applier, "bzip2");
    const xz = patched(b, applier, "xz");

    // The patched copies land under o/vendor, which is where the boot
    // bridge reads the Teal compiler from.
    const vendored = b.step("vendor", "write the patched vendor trees");
    for ([_]struct { []const u8, std.Build.LazyPath }{
        .{ "lua", lua },         .{ "sqlite", sqlite },
        .{ "tl", tl },           .{ "miniz", miniz },
        .{ "mbedtls", mbedtls }, .{ "bzip2", bzip2 },
        .{ "xz", xz },
    }) |pair| {
        const install = b.addInstallDirectory(.{
            .source_dir = pair[1],
            .install_dir = .prefix,
            .install_subdir = b.fmt("vendor/{s}", .{pair[0]}),
        });
        vendored.dependOn(&install.step);
    }

    const cores = b.step("cores", "build the core for every target");
    const boot = b.step("boot", "build the host core, then bridge into Teal");
    const portable_hook_cores = b.step(
        "portable-hook-cores",
        "build release and retained-artifact test fixture cores",
    );
    const portable_format_fixtures = b.step(
        "portable-format-fixtures",
        "build native and target portable-format decoders",
    );
    const portable_launcher_fixtures = b.step(
        "portable-launcher-fixtures",
        "build target launcher payload and socket helpers",
    );

    // The boot bridge and portable writer consume this generated projection.
    // The Target array above remains the only target list.
    var records: []const u8 = "";
    for (targets) |t| {
        records = b.fmt("{s}{d}\t{d}\t{s}\t{s}\t{s}\t{s}\n", .{
            records,
            t.id,
            release_configuration.id,
            release_configuration.name,
            t.name,
            t.uname_os,
            t.uname_arch,
        });
    }
    const generated = b.addWriteFiles();
    const target_records = generated.add("targets.tsv", records);
    const install_target_records = b.addInstallFile(target_records, "targets.tsv");
    cores.dependOn(&install_target_records.step);

    // Keeping these test executables in this graph makes their sources,
    // included headers, flags, and target definitions inputs to Zig's restored
    // build cache. Their installed paths are stable inputs to the pinned Teal
    // CI code, which owns fixture orchestration and assertions.
    const native_format_decoder = formatDecoder(
        b,
        "format-test-native",
        b.graph.host,
        .Debug,
        null,
    );
    const native_format_install = b.addInstallFile(
        native_format_decoder.getEmittedBin(),
        "portable-fixture/format/format-test-native",
    );
    const portable_format_native = b.step(
        "portable-format-native",
        "build the native portable-format decoder",
    );
    portable_format_native.dependOn(&native_format_install.step);
    portable_format_fixtures.dependOn(&native_format_install.step);
    portable_format_fixtures.dependOn(&install_target_records.step);

    for (targets) |t| {
        const resolved = b.resolveTargetQuery(t.query);
        const target_format_decoder = formatDecoder(
            b,
            b.fmt("format-test-{s}", .{t.name}),
            resolved,
            .ReleaseFast,
            t,
        );
        const target_format_install = b.addInstallFile(
            target_format_decoder.getEmittedBin(),
            b.fmt("portable-fixture/format/format-test-{s}", .{t.name}),
        );
        const target_format_step = b.step(
            b.fmt("portable-format-{s}", .{t.name}),
            b.fmt("build the {s} portable-format decoder", .{t.name}),
        );
        target_format_step.dependOn(&target_format_install.step);
        portable_format_fixtures.dependOn(&target_format_install.step);

        const payload = launcherHelper(
            b,
            b.fmt("launcher-payload-{s}", .{t.name}),
            "test/portable/launcher_payload.c",
            resolved,
        );
        const payload_install = b.addInstallFile(
            payload.getEmittedBin(),
            b.fmt("portable-fixture/launcher/payload-{s}", .{t.name}),
        );
        const payload_step = b.step(
            b.fmt("portable-launcher-payload-{s}", .{t.name}),
            b.fmt("build the {s} launcher payload", .{t.name}),
        );
        payload_step.dependOn(&payload_install.step);
        portable_launcher_fixtures.dependOn(&payload_install.step);

        const socket = launcherHelper(
            b,
            b.fmt("launcher-socket-{s}", .{t.name}),
            "test/portable/launcher_socket_fd.c",
            resolved,
        );
        const socket_install = b.addInstallFile(
            socket.getEmittedBin(),
            b.fmt("portable-fixture/launcher/socket-{s}", .{t.name}),
        );
        const socket_step = b.step(
            b.fmt("portable-launcher-socket-{s}", .{t.name}),
            b.fmt("build the {s} launcher socket helper", .{t.name}),
        );
        socket_step.dependOn(&socket_install.step);
        portable_launcher_fixtures.dependOn(&socket_install.step);
    }
    portable_launcher_fixtures.dependOn(&install_target_records.step);

    // The core's strnlen stands in for the toolchain's, which reads past
    // the end of a mapping (core/strnlen.c). The case that tells them
    // apart runs on the host with every boot.
    const strnlen_check = b.addExecutable(.{
        .name = "strnlen-check",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    strnlen_check.root_module.addCSourceFiles(.{
        .root = b.path("core"),
        .files = &.{ "strnlen.c", "strnlen_test.c" },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    boot.dependOn(&b.addRunArtifact(strnlen_check).step);

    // Startup's reserved-prefix sweep has no fixed name count or length.
    const environment_check = b.addExecutable(.{
        .name = "environment-check",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    environment_check.root_module.addCSourceFiles(.{
        .root = b.path("core"),
        .files = &.{ "environment.c", "environment_test.c" },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    environment_check.root_module.addIncludePath(b.path("core"));
    boot.dependOn(&b.addRunArtifact(environment_check).step);

    for (targets) |t| {
        const resolved = b.resolveTargetQuery(t.query);
        const exe = core(b, t, release_configuration, resolved, lua, sqlite, miniz, mbedtls, bzip2, xz, false);
        const out = b.addInstallFile(
            exe.getEmittedBin(),
            b.fmt("core/{s}/cosmic-core", .{t.name}),
        );
        cores.dependOn(&out.step);

        const hooked = core(b, t, release_configuration, resolved, lua, sqlite, miniz, mbedtls, bzip2, xz, true);
        const hooked_out = b.addInstallFile(
            hooked.getEmittedBin(),
            b.fmt("portable-fixture/core/{s}/cosmic-core", .{t.name}),
        );
        portable_hook_cores.dependOn(&hooked_out.step);

        if (std.mem.eql(u8, t.name, hostName(b))) {
            const bridge = b.addRunArtifact(exe);
            bridge.addArg("--boot");
            bridge.addDirectoryArg(b.path("."));
            bridge.addDirectoryArg(tl);
            bridge.addArg(t.name);
            bridge.addFileArg(target_records);
            // The bridge reads every raw core and writes the database
            // beside them, so it runs after both.
            bridge.step.dependOn(cores);
            bridge.step.dependOn(vendored);
            bridge.has_side_effects = true;
            boot.dependOn(&bridge.step);
        }
    }

    // A fourth core, checked for undefined behavior: same sources, built
    // for the host only, and installed beside the release cores. Its portable
    // artifact still carries all three required release entries, plus this
    // host's configuration-2 entry selected by its private launcher.
    const sanitized = b.step("sanitized", "build and boot the checked core");
    const checked_target = hostTarget(b);
    const checked = core(b, checked_target, sanitized_configuration, baselineHostTarget(b), lua, sqlite, miniz, mbedtls, bzip2, xz, false);
    const checked_install = b.addInstallFile(
        checked.getEmittedBin(),
        "sanitized/cosmic-core",
    );
    const checked_name = b.fmt("sanitized-{s}", .{checked_target.name});
    const checked_records = generated.add("sanitized-targets.tsv", b.fmt(
        "{s}{d}\t{d}\t{s}\t{s}\t{s}\t{s}\n",
        .{
            records,
            checked_target.id,
            sanitized_configuration.id,
            sanitized_configuration.name,
            checked_name,
            checked_target.uname_os,
            checked_target.uname_arch,
        },
    ));
    const checked_records_install = b.addInstallFile(
        checked_records,
        "sanitized/targets.tsv",
    );
    const checked_boot = b.addRunArtifact(checked);
    checked_boot.addArg("--boot");
    checked_boot.addDirectoryArg(b.path("."));
    checked_boot.addDirectoryArg(tl);
    checked_boot.addArg(checked_target.name);
    checked_boot.addFileArg(target_records);
    checked_boot.addArg(b.getInstallPath(.prefix, "sanitized"));
    checked_boot.addFileArg(checked.getEmittedBin());
    checked_boot.addFileArg(checked_records);
    checked_boot.step.dependOn(cores);
    checked_boot.step.dependOn(vendored);
    checked_boot.has_side_effects = true;
    sanitized.dependOn(&checked_install.step);
    sanitized.dependOn(&checked_records_install.step);
    sanitized.dependOn(&checked_boot.step);

    portable_hook_cores.dependOn(cores);

    b.getInstallStep().dependOn(cores);
}

fn requiredTargetMask() u64 {
    var mask: u64 = 0;
    for (targets) |required| {
        if (required.id >= 64) @panic("portable target id does not fit the v1 required-target mask");
        mask |= @as(u64, 1) << @intCast(required.id);
    }
    return mask;
}

fn formatDecoder(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    target_record: ?Target,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Stripped like `core()` so a target build reuses the musl libc
        // `cores` already built; see `launcherHelper()`. The native Debug
        // decoder keeps its symbols.
        .strip = optimize != .Debug,
    });
    mod.addCSourceFiles(.{
        .root = b.path("."),
        .files = &.{ "core/portable.c", "test/portable/format_test.c" },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    mod.addIncludePath(b.path("core"));
    mod.addCMacro(
        "COSMIC_PORTABLE_REQUIRED_TARGET_MASK",
        b.fmt("UINT64_C({d})", .{requiredTargetMask()}),
    );
    mod.addCMacro(
        "COSMIC_PORTABLE_RELEASE_CONFIGURATION_ID",
        b.fmt("{d}", .{release_configuration.id}),
    );
    if (target_record) |record| {
        mod.addCMacro("PORTABLE_TEST_TARGET_ID", b.fmt("{d}", .{record.id}));
        mod.addCMacro(
            "PORTABLE_TEST_CONFIGURATION_ID",
            b.fmt("{d}", .{release_configuration.id}),
        );
    }
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

fn launcherHelper(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        // Matching `core()`'s strip setting keeps this module's musl libc
        // build cache-compatible with the one `cores` already built for
        // the same target: without it, `zig build` reruns a from-scratch
        // musl libc/compiler_rt build for this one-file helper, which cost
        // over a minute per cross target on a cold cache.
        .strip = true,
    });
    mod.addCSourceFile(.{
        .file = b.path(source),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

/// The patched copy of one vendored library, as a directory the core's
/// sources are read from. The dependency on the applier is expressed by
/// consuming its output, so nothing declares an order by hand.
fn patched(
    b: *std.Build,
    applier: *std.Build.Step.Compile,
    name: []const u8,
) std.Build.LazyPath {
    const vendor = b.fmt("vendor/{s}", .{name});
    const patch_dir = b.fmt("patch/{s}", .{name});

    const run = b.addRunArtifact(applier);
    run.addDirectoryArg(b.path(vendor));
    run.addDirectoryArg(b.path(patch_dir));

    // A directory argument names a place, not its contents. Every file
    // under both trees is added as an input in its own right, so editing
    // one record or one upstream file reruns the applier.
    watchTree(b, run, vendor);
    watchTree(b, run, patch_dir);

    return run.addOutputDirectoryArg(name);
}

/// Adds every file under `rel` as an input of `run`.
fn watchTree(b: *std.Build, run: *std.Build.Step.Run, rel: []const u8) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, rel, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        run.addFileInput(b.path(b.pathJoin(&.{ rel, entry.path })));
    }
}

fn core(
    b: *std.Build,
    target_record: Target,
    configuration: Configuration,
    target: std.Build.ResolvedTarget,
    lua: std.Build.LazyPath,
    sqlite: std.Build.LazyPath,
    miniz: std.Build.LazyPath,
    mbedtls: std.Build.LazyPath,
    bzip2: std.Build.LazyPath,
    xz: std.Build.LazyPath,
    portable_startup_test_hooks: bool,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = if (configuration.sanitize) .ReleaseSafe else .ReleaseFast,
        .link_libc = true,
        // Stripping is what makes two builds at different paths produce
        // the same bytes: debug info carries the absolute path.
        .strip = !configuration.sanitize,
        .sanitize_c = if (configuration.sanitize) .full else .off,
    });

    // LUA_USE_LINUX and LUA_USE_MACOSX both drag in LUA_USE_DLOPEN (and
    // macOS's also readline); POSIX is the whole of what the core needs
    // on either OS, and dynamic loading is never wanted -- the module
    // store is the only door. Same flag on both, so `nm`/`strings` finds
    // no dlopen symbol in either core.
    // LUA_COMPAT_GLOBAL off: assigning to an undeclared global (no
    // `global` statement) is a compile error rather than silently
    // creating one, catching the classic Lua typo bug. The vendored
    // compiler and every Teal-generated chunk run unchanged under it --
    // neither ever assigns an undeclared global -- so there is nothing
    // to trade for the safety.
    const lua_flags: []const []const u8 =
        &.{ "-std=c11", "-DLUA_USE_POSIX", "-DLUA_COMPAT_GLOBAL=0" };
    mod.addCSourceFiles(.{
        .root = lua.path(b, "src"),
        .files = &lua_sources,
        .flags = lua_flags,
    });
    mod.addIncludePath(lua.path(b, "src"));

    // SQLite's compile-time configuration, as flags rather than a
    // configuration header: a flag is part of the compile's cache key,
    // where a header pulled in through SQLITE_CUSTOM_INCLUDE was seen to
    // change without the object being rebuilt. The build is
    // single-threaded and the shipped database is read-only and opened
    // through our own VFS, so everything that exists for other shapes of
    // use is off. The `dbstat` virtual table is on: it is what every
    // table and index costs in pages and bytes, which `cosmic db`
    // reports. `fts5` is on: it backs the shipped catalog an uncaught
    // error and `cosmic docs` search against, and costs ~222 KB per
    // raw core (three raw cores per portable artifact).
    const sqlite_flags: []const []const u8 = &.{
        "-std=c11",
        "-DSQLITE_THREADSAFE=0",
        "-DSQLITE_OMIT_LOAD_EXTENSION=1",
        "-DSQLITE_OMIT_SHARED_CACHE=1",
        "-DSQLITE_OMIT_DEPRECATED=1",
        "-DSQLITE_OMIT_AUTOINIT=1",
        "-DSQLITE_OMIT_PROGRESS_CALLBACK=1",
        "-DSQLITE_OMIT_UTF16=1",
        "-DSQLITE_DQS=0",
        "-DSQLITE_DEFAULT_MEMSTATUS=0",
        "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
        "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS=1",
        "-DSQLITE_MAX_EXPR_DEPTH=0",
        "-DSQLITE_USE_ALLOCA=1",
        "-DSQLITE_ENABLE_COLUMN_METADATA=1",
        "-DSQLITE_ENABLE_DBSTAT_VTAB=1",
        "-DSQLITE_ENABLE_FTS5=1",
    };
    mod.addCSourceFiles(.{
        .root = sqlite,
        .files = &.{"sqlite3.c"},
        .flags = sqlite_flags,
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

    // bzip2's decompressor is a true push-streaming API (bz_stream's
    // next_in/avail_in/next_out), which is what the Compress.Stream
    // contract needs; BZ_NO_STDIO keeps its file-handle helpers, which
    // this core never calls, from pulling in FILE*. blocksort.c and
    // compress.c hold the compress-side symbols bzlib.c references even
    // though only BZ2_bzDecompress* is ever called here -- without them
    // the link fails, since C links whole translation units, not just
    // the functions a caller reaches. The K&R-flavored source predates
    // -Wall/-Wextra/-Werror by a wide margin, so it gets its own quiet
    // flag set rather than the core's.
    mod.addCSourceFiles(.{
        .root = bzip2,
        .files = &.{
            "bzlib.c", "blocksort.c", "compress.c", "decompress.c",
            "huffman.c", "crctable.c", "randtable.c",
        },
        .flags = &.{ "-std=c11", "-DBZ_NO_STDIO" },
    });
    mod.addIncludePath(bzip2);

    // xz's liblzma, a decoder-only subset (LZMA1/LZMA2, the delta and
    // x86/arm64 BCJ filters, and the CRC-32/CRC-64/SHA-256 checks) --
    // see core/xz_config for why: the tree vendors no config.h of its
    // own, autoconf's usual job, so core/xz_config/config.h stands in
    // for it, on an include path scoped to just these files.
    const xz_src = xz.path(b, "src");
    mod.addCSourceFiles(.{
        .root = xz_src,
        .files = &.{
            "liblzma/check/check.c",
            "liblzma/check/crc32_small.c",
            "liblzma/check/crc64_small.c",
            "liblzma/check/sha256.c",
            "liblzma/common/block_decoder.c",
            "liblzma/common/block_header_decoder.c",
            "liblzma/common/block_util.c",
            "liblzma/common/common.c",
            "liblzma/common/filter_common.c",
            "liblzma/common/filter_decoder.c",
            "liblzma/common/filter_flags_decoder.c",
            "liblzma/common/index.c",
            "liblzma/common/index_hash.c",
            "liblzma/common/stream_decoder.c",
            "liblzma/common/stream_flags_common.c",
            "liblzma/common/stream_flags_decoder.c",
            "liblzma/common/vli_decoder.c",
            "liblzma/common/vli_size.c",
            "liblzma/delta/delta_common.c",
            "liblzma/delta/delta_decoder.c",
            "liblzma/lz/lz_decoder.c",
            "liblzma/lzma/lzma2_decoder.c",
            "liblzma/lzma/lzma_decoder.c",
            "liblzma/lzma/lzma_encoder_presets.c",
            "liblzma/simple/arm64.c",
            "liblzma/simple/simple_coder.c",
            "liblzma/simple/simple_decoder.c",
            "liblzma/simple/x86.c",
        },
        .flags = &.{
            "-std=c11",         "-D_XOPEN_SOURCE=700",
            "-D_DEFAULT_SOURCE", "-DHAVE_CONFIG_H",
        },
    });
    mod.addIncludePath(b.path("core/xz_config"));
    mod.addIncludePath(xz.path(b, "src/common"));
    mod.addIncludePath(xz_src.path(b, "liblzma/api"));
    mod.addIncludePath(xz_src.path(b, "liblzma/common"));
    mod.addIncludePath(xz_src.path(b, "liblzma/check"));
    mod.addIncludePath(xz_src.path(b, "liblzma/lzma"));
    mod.addIncludePath(xz_src.path(b, "liblzma/lz"));
    mod.addIncludePath(xz_src.path(b, "liblzma/rangecoder"));
    mod.addIncludePath(xz_src.path(b, "liblzma/delta"));
    mod.addIncludePath(xz_src.path(b, "liblzma/simple"));

    // mbedtls, its crypto subtree only: the files below are the ones
    // that hold any code under the configuration above, every other one
    // compiles to nothing. TLS is not built; the `fetch` module pulls it
    // in when it lands.
    const mbedtls_flags = [_][]const u8{"-std=c11"} ++ mbedtls_config;
    const crypto = mbedtls.path(b, "tf-psa-crypto");
    mod.addCSourceFiles(.{
        .root = crypto,
        .files = &.{
            "core/psa_crypto.c",
            "core/psa_crypto_client.c",
            "core/psa_crypto_driver_wrappers_no_static.c",
            "core/psa_crypto_slot_management.c",
            "core/psa_util.c",
            "drivers/builtin/src/md5.c",
            "drivers/builtin/src/psa_crypto_cipher.c",
            "drivers/builtin/src/psa_crypto_hash.c",
            "drivers/builtin/src/psa_crypto_mac.c",
            "drivers/builtin/src/psa_crypto_rsa.c",
            "drivers/builtin/src/psa_util_internal.c",
            "drivers/builtin/src/sha1.c",
            "drivers/builtin/src/sha256.c",
            "drivers/builtin/src/sha3.c",
            "drivers/builtin/src/sha512.c",
            "platform/platform_util.c",
            "utilities/constant_time.c",
        },
        .flags = &mbedtls_flags,
    });
    for ([_][]const u8{
        "include",             "core",     "drivers/builtin/include",
        "drivers/builtin/src", "dispatch", "utilities",
        "platform",            "extras",
    }) |dir| {
        mod.addIncludePath(crypto.path(b, dir));
    }

    // The core sees the library through the same configuration it was
    // built with, or the headers would describe another library.
    const core_flags = [_][]const u8{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES",
    } ++ mbedtls_config;
    mod.addCSourceFiles(.{
        .root = b.path("core"),
        .files = &core_sources,
        .flags = &core_flags,
    });
    mod.addCSourceFile(.{
        .file = b.path("core/entry.c"),
        .flags = &core_flags,
    });
    mod.addIncludePath(b.path("core"));

    mod.addCMacro("COSMIC_TARGET_ID", b.fmt("{d}", .{target_record.id}));
    mod.addCMacro("COSMIC_TARGET_NAME", b.fmt("\"{s}\"", .{target_record.name}));
    mod.addCMacro("COSMIC_CONFIGURATION_ID", b.fmt("{d}", .{configuration.id}));
    mod.addCMacro("COSMIC_CONFIGURATION_NAME", b.fmt("\"{s}\"", .{configuration.name}));

    mod.addCMacro("COSMIC_PORTABLE_REQUIRED_TARGET_MASK", b.fmt("UINT64_C({d})", .{requiredTargetMask()}));
    mod.addCMacro("COSMIC_PORTABLE_RELEASE_CONFIGURATION_ID", b.fmt("{d}", .{release_configuration.id}));
    mod.addCSourceFile(.{
        .file = b.path(if (portable_startup_test_hooks)
            "test/portable/startup_hook.c"
        else
            "core/startup_hook.c"),
        .flags = &core_flags,
    });

    return b.addExecutable(.{
        .name = "cosmic-core",
        .root_module = mod,
    });
}

fn hostName(b: *std.Build) []const u8 {
    return hostTarget(b).name;
}

/// Keeps the sanitizer's native OS, ABI, and version while making its CPU
/// instruction set safe to transport between different machines of that
/// architecture. `b.graph.host` includes features detected on the build
/// machine, which an exported checked core cannot assume on its runner.
fn baselineHostTarget(b: *std.Build) std.Build.ResolvedTarget {
    var query = b.graph.host.query;
    query.cpu_model = .baseline;
    query.cpu_features_add = .empty;
    query.cpu_features_sub = .empty;
    const resolved = b.resolveTargetQuery(query);
    const expected = std.Target.Cpu.Model.baseline(
        resolved.result.cpu.arch,
        resolved.result.os,
    );
    if (resolved.result.cpu.model != expected)
        @panic("checked core did not resolve the baseline host CPU");
    return resolved;
}

fn hostTarget(b: *std.Build) Target {
    const host = b.graph.host.result;
    for (targets) |target| {
        // The sanitized core uses the native host libc, while its target
        // identity names the shipped OS/architecture pair. ABI is therefore
        // deliberately not part of this match.
        if (target.query.os_tag == host.os.tag and
            target.query.cpu_arch == host.cpu.arch) return target;
    }
    @panic("unsupported build host");
}
