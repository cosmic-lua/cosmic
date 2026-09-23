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

/// Whether a core observes its own C (`core/coverage.c`): not at all, or
/// with sancov's per-block flags, once linked with an empty block-to-line
/// table (`first_link`, read for its debug information and never run) and
/// once carrying the table `core/coverage_map.zig` wrote from that link.
const NativeCoverage = union(enum) {
    off,
    first_link,
    map: std.Build.LazyPath,
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
/// The warnings every C file of this tree's own is held to, as errors.
/// Past -Wall and -Wextra: a shadowed name, an implicit narrowing or
/// change of sign, an undefined macro in an #if, a string literal
/// treated as writable, a function without a prototype, a fallthrough
/// nothing marks, a variable-length array, and a function that never
/// returns without saying so. -Wcast-qual is not among them: the calls
/// this core makes take their const-dropping casts by design --
/// execve's argv, lua_pushlightuserdata of a const record. The vendored
/// libraries are theirs to hold to their own warnings, not these.
const own_warnings = [_][]const u8{
    "-Wall",
    "-Wextra",
    "-Werror",
    "-Wshadow",
    "-Wconversion",
    "-Wsign-conversion",
    "-Wundef",
    "-Wwrite-strings",
    "-Wmissing-prototypes",
    "-Wstrict-prototypes",
    "-Wimplicit-fallthrough",
    "-Wvla",
    "-Wmissing-noreturn",
};
const own_c = [_][]const u8{"-std=c11"} ++ own_warnings;

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

/// Where the crypto library's headers are, under its `tf-psa-crypto`.
const crypto_include_dirs = [_][]const u8{
    "include",             "core",     "drivers/builtin/include",
    "drivers/builtin/src", "dispatch", "utilities",
    "platform",            "extras",
};

const core_sources = [_][]const u8{
    "boot.c",
    "coverage.c",
    "crypto.c",
    "environment.c",
    "executable.c",
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
        .flags = &own_c,
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
        .flags = &own_c,
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
        .flags = &own_c,
    });
    environment_check.root_module.addIncludePath(b.path("core"));
    boot.dependOn(&b.addRunArtifact(environment_check).step);

    for (targets) |t| {
        const resolved = b.resolveTargetQuery(t.query);
        const exe = core(b, t, release_configuration, resolved, lua, sqlite, miniz, mbedtls, false, .off);
        const out = b.addInstallFile(
            exe.getEmittedBin(),
            b.fmt("core/{s}/cosmic-core", .{t.name}),
        );
        cores.dependOn(&out.step);

        const hooked = core(b, t, release_configuration, resolved, lua, sqlite, miniz, mbedtls, true, .off);
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
    // It also observes its own C, so the suite it runs
    // writes the core's lines into the same coverage tables as Teal's.
    const sanitized = b.step("sanitized", "build and boot the checked core");
    const analyzed = b.step("analyze", "run the static analyzer over the tree's own C");
    analyze(b, analyzed, lua, sqlite, miniz, mbedtls);
    // The checked build is where CI already looks for what the release
    // build would only do quietly; the analyzer's findings are the same
    // kind of thing, found without running anything.
    sanitized.dependOn(analyzed);
    const checked_target = hostTarget(b);
    const checked_host = baselineHostTarget(b);
    const checked = checked: {
        const first = core(b, checked_target, sanitized_configuration, checked_host, lua, sqlite, miniz, mbedtls, false, .first_link);
        const mapper = b.addExecutable(.{
            .name = "coverage-map",
            .root_module = b.createModule(.{
                .root_source_file = b.path("core/coverage_map.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        const write_map = b.addRunArtifact(mapper);
        write_map.addArg("write");
        write_map.addFileArg(first.getEmittedBin());
        write_map.addArg(b.pathFromRoot("."));
        const map = write_map.addOutputFileArg("coverage_map.c");
        const second = core(b, checked_target, sanitized_configuration, checked_host, lua, sqlite, miniz, mbedtls, false, .{ .map = map });
        // The table is indexed by block, and only holds for a link whose
        // blocks are the first's, in the first's order: the second link is
        // mapped again and must say the same.
        const check_map = b.addRunArtifact(mapper);
        check_map.addArg("check");
        check_map.addFileArg(second.getEmittedBin());
        check_map.addArg(b.pathFromRoot("."));
        check_map.addFileArg(map);
        sanitized.dependOn(&check_map.step);
        break :checked second;
    };
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
        .flags = &own_c,
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
        .flags = &own_c,
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

/// Clang's static analyzer, the one `bin/zig cc` carries, over every C
/// file of this tree's own that a core or the patch applier is built
/// from, with the includes, defines and warnings those builds use: a
/// finding fails the step. The vendored libraries are not analyzed; their
/// findings are theirs.
fn analyze(
    b: *std.Build,
    step: *std.Build.Step,
    lua: std.Build.LazyPath,
    sqlite: std.Build.LazyPath,
    miniz: std.Build.LazyPath,
    mbedtls: std.Build.LazyPath,
) void {
    const extra = [_][]const u8{
        "entry.c", "startup_hook.c", "testing.c", "testing_checked.c", "patch.c",
    };
    const crypto = mbedtls.path(b, "tf-psa-crypto");
    for (core_sources ++ extra) |file| {
        // -S, not -c: `zig cc` would take the analyzer's report for an
        // object and try to link it; as assembly it is left alone.
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-S", "--analyze", "-Xanalyzer", "-analyzer-werror" });
        run.addArgs(&own_c);
        // `zig cc` passes options the analyzer has no use for.
        run.addArg("-Wno-unused-command-line-argument");
        run.addArgs(&mbedtls_config);
        run.addArgs(&.{
            "-DLUA_USE_POSIX",
            "-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES",
            "-DCOSMIC_TARGET_ID=1",
            "-DCOSMIC_TARGET_NAME=\"analyze\"",
            "-DCOSMIC_CONFIGURATION_ID=1",
            "-DCOSMIC_CONFIGURATION_NAME=\"analyze\"",
            b.fmt("-DCOSMIC_PORTABLE_REQUIRED_TARGET_MASK=UINT64_C({d})", .{requiredTargetMask()}),
            b.fmt("-DCOSMIC_PORTABLE_RELEASE_CONFIGURATION_ID={d}", .{release_configuration.id}),
        });
        run.addPrefixedDirectoryArg("-I", b.path("core"));
        run.addPrefixedDirectoryArg("-I", lua.path(b, "src"));
        run.addPrefixedDirectoryArg("-I", sqlite);
        run.addPrefixedDirectoryArg("-I", miniz);
        for (crypto_include_dirs) |dir| {
            run.addPrefixedDirectoryArg("-I", crypto.path(b, dir));
        }
        run.addArg("-o");
        _ = run.addOutputFileArg(b.fmt("{s}.analysis", .{file}));
        run.addFileArg(b.path(b.fmt("core/{s}", .{file})));
        step.dependOn(&run.step);
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
    portable_startup_test_hooks: bool,
    native_coverage: NativeCoverage,
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
    const lua_base = [_][]const u8{ "-std=c11", "-DLUA_USE_POSIX", "-DLUA_COMPAT_GLOBAL=0" };
    // The checked core also turns on Lua's own internal assertions and
    // its C API checks, which catch a binding that misuses the Lua stack
    // -- a buffer popped out from under itself, a pointer to a string no
    // longer on the stack -- where UBSan sees nothing wrong. Lua's
    // headers change with them, so the core's own C gets them too.
    const lua_checks = [_][]const u8{ "-DLUAI_ASSERT", "-DLUA_USE_APICHECK" };
    const lua_checked = lua_base ++ lua_checks;
    const lua_flags: []const []const u8 =
        if (configuration.sanitize) &lua_checked else &lua_base;
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
    for (crypto_include_dirs) |dir| {
        mod.addIncludePath(crypto.path(b, dir));
    }

    // The core sees the library through the same configuration it was
    // built with, or the headers would describe another library.
    const core_flags = own_c ++ [_][]const u8{
        "-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES",
    } ++ mbedtls_config;
    // Only the core's own C is instrumented: the vendored libraries have
    // their own tests, and their blocks would outnumber the core's.
    const observed = [_][]const u8{
        "-fsanitize-coverage=inline-bool-flag,pc-table",
        "-DCOSMIC_NATIVE_COVERAGE",
    };
    const observed_flags = core_flags ++ observed;
    const checked_flags = core_flags ++ lua_checks;
    const checked_observed_flags = checked_flags ++ observed;
    const own_flags: []const []const u8 = switch (native_coverage) {
        .off => if (configuration.sanitize) &checked_flags else &core_flags,
        .first_link, .map => if (configuration.sanitize) &checked_observed_flags else &observed_flags,
    };
    mod.addCSourceFiles(.{
        .root = b.path("core"),
        .files = &core_sources,
        .flags = own_flags,
    });
    mod.addCSourceFile(.{
        .file = b.path("core/entry.c"),
        .flags = own_flags,
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
        .flags = own_flags,
    });
    // The checked core alone carries the test instruments -- a failing
    // allocator, a count of the store's open statements -- so no core
    // that ships has an allocator a program can make fail.
    mod.addCSourceFile(.{
        .file = b.path(if (configuration.sanitize)
            "core/testing_checked.c"
        else
            "core/testing.c"),
        .flags = own_flags,
    });
    // Last, and uninstrumented, so both links hold the same blocks in the
    // same order: the table is data and adds none.
    switch (native_coverage) {
        .off => {},
        .first_link => mod.addCSourceFile(.{ .file = b.path("core/coverage_map_empty.c"), .flags = &.{"-std=c11"} }),
        .map => |map| mod.addCSourceFile(.{ .file = map, .flags = &.{"-std=c11"} }),
    }

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
