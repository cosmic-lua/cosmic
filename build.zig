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
    "crypto.c",
    "locate.c",
    "sqlite.c",
    "store.c",
    "surface.c",
    "syscalls.c",
    "syscalls_fs.c",
    "vfs.c",
    "main.c",
    "portable.c",
    "startup.c",
};

pub fn build(b: *std.Build) void {
    const portable_probe = b.option(bool, "portable-probe", "build the experimental external-artifact entry") orelse false;
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

    // The patched copies land under o/vendor, which is where the boot
    // bridge reads the Teal compiler from.
    const vendored = b.step("vendor", "write the patched vendor trees");
    for ([_]struct { []const u8, std.Build.LazyPath }{
        .{ "lua", lua },         .{ "sqlite", sqlite },
        .{ "tl", tl },           .{ "miniz", miniz },
        .{ "mbedtls", mbedtls },
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
    const portable_fixture_cores = b.step(
        "portable-fixture-cores",
        "build release, retained-artifact test, and checked fixture cores",
    );

    // Both the boot bridge and the prototype packer consume this generated
    // projection. The Target array above remains the only target list.
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

    for (targets) |t| {
        const resolved = b.resolveTargetQuery(t.query);
        const exe = core(b, t, release_configuration, resolved, lua, sqlite, miniz, mbedtls, portable_probe, false);
        const out = b.addInstallFile(
            exe.getEmittedBin(),
            b.fmt("core/{s}/cosmic-core", .{t.name}),
        );
        cores.dependOn(&out.step);

        const hooked = core(b, t, release_configuration, resolved, lua, sqlite, miniz, mbedtls, portable_probe, true);
        const hooked_out = b.addInstallFile(
            hooked.getEmittedBin(),
            b.fmt("portable-fixture/core/{s}/cosmic-core", .{t.name}),
        );
        portable_fixture_cores.dependOn(&hooked_out.step);

        if (std.mem.eql(u8, t.name, hostName(b))) {
            const bridge = b.addRunArtifact(exe);
            bridge.addArg("--boot");
            bridge.addDirectoryArg(b.path("."));
            bridge.addDirectoryArg(tl);
            bridge.addArg(t.name);
            bridge.addFileArg(target_records);
            // The bridge reads every core image and writes the database
            // beside them, so it runs after both.
            bridge.step.dependOn(cores);
            bridge.step.dependOn(vendored);
            bridge.has_side_effects = true;
            boot.dependOn(&bridge.step);
        }
    }

    // A fourth core, checked for undefined behavior: same sources, built
    // for the host only, and installed beside the others rather than over
    // them. Both boot and the attached host executable use this image;
    // checked artifacts stay under o/sanitized.
    const sanitized = b.step("sanitized", "build and boot the checked core");
    const checked_target = hostTarget(b);
    const checked = core(b, checked_target, sanitized_configuration, baselineHostTarget(b), lua, sqlite, miniz, mbedtls, portable_probe, false);
    const checked_install = b.addInstallFile(
        checked.getEmittedBin(),
        "sanitized/cosmic-core",
    );
    const checked_boot = b.addRunArtifact(checked);
    checked_boot.addArg("--boot");
    checked_boot.addDirectoryArg(b.path("."));
    checked_boot.addDirectoryArg(tl);
    checked_boot.addArg(checked_target.name);
    checked_boot.addFileArg(target_records);
    checked_boot.addArg(b.getInstallPath(.prefix, "sanitized"));
    checked_boot.addFileArg(checked.getEmittedBin());
    checked_boot.step.dependOn(cores);
    checked_boot.step.dependOn(vendored);
    checked_boot.has_side_effects = true;
    sanitized.dependOn(&checked_install.step);
    sanitized.dependOn(&checked_boot.step);

    const checked_fixture_install = b.addInstallFile(
        checked.getEmittedBin(),
        "portable-fixture/sanitized/cosmic-core",
    );
    portable_fixture_cores.dependOn(cores);
    portable_fixture_cores.dependOn(&checked_fixture_install.step);

    b.getInstallStep().dependOn(cores);
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
    portable_probe: bool,
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
    // core image (three images per binary).
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
        .file = b.path(if (portable_probe) "experiments/portable/entry.c" else "core/entry.c"),
        .flags = &core_flags,
    });
    mod.addIncludePath(b.path("core"));

    mod.addCMacro("COSMIC_TARGET_ID", b.fmt("{d}", .{target_record.id}));
    mod.addCMacro("COSMIC_TARGET_NAME", b.fmt("\"{s}\"", .{target_record.name}));
    mod.addCMacro("COSMIC_CONFIGURATION_ID", b.fmt("{d}", .{configuration.id}));
    mod.addCMacro("COSMIC_CONFIGURATION_NAME", b.fmt("\"{s}\"", .{configuration.name}));

    var required_target_mask: u64 = 0;
    for (targets) |required| {
        if (required.id >= 64) @panic("portable target id does not fit the v1 required-target mask");
        required_target_mask |= @as(u64, 1) << @intCast(required.id);
    }
    mod.addCMacro("COSMIC_PORTABLE_REQUIRED_TARGET_MASK", b.fmt("UINT64_C({d})", .{required_target_mask}));
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
