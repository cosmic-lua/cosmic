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
/// with sancov's per-block flags, once linked without the block-to-line
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

/// mbedtls's compile-time configuration, which is
/// `core/mbedtls_cosmic_config.h` and nothing else: that header is named
/// as both configuration files the library reads (tf-psa-crypto's and
/// mbedtls's own), and no `MBEDTLS_` or `PSA_WANT_` macro is passed on a
/// command line. Every file that includes the library's headers -- the
/// crypto subtree, the TLS and X.509 layer, curl's mbedtls backend and
/// the core's own C -- is compiled with exactly these flags, so none of
/// them can see a struct laid out differently from the one the library
/// was built with. An edit to the header rebuilds every object that
/// includes it: the compiler's dependency list, not the flag text, is
/// what puts a header in a compile's cache key.
const mbedtls_config = [_][]const u8{
    "-DTF_PSA_CRYPTO_CONFIG_FILE=\"mbedtls_cosmic_config.h\"",
    "-DMBEDTLS_CONFIG_FILE=\"mbedtls_cosmic_config.h\"",
};

/// The TLS 1.2/1.3 client and X.509 chain sources under mbedtls's own
/// `library/`. Server-only (`ssl_tls12_server.c`, `ssl_tls13_server.c`),
/// session-cache/ticket/cookie, DTLS, CRL and certificate-writing sources
/// are left out: nothing here serves, resumes from a ticket, or signs.
const mbedtls_tls_sources = [_][]const u8{
    "ssl_tls.c",
    "ssl_msg.c",
    "ssl_ciphersuites.c",
    "ssl_client.c",
    "ssl_tls12_client.c",
    "ssl_tls13_client.c",
    "ssl_tls13_generic.c",
    "ssl_tls13_keys.c",
    "error.c",
    "version.c",
    "x509.c",
    "x509_crt.c",
    "x509_oid.c",
};

/// c-ares's own thread support (CARES_THREADS) is never built -- the core
/// drives one poll loop itself -- so windows_port.c, ares_sysconfig_win.c
/// (Windows-only, gated `#ifdef _WIN32`) and ares_android.c
/// (`#ifdef __ANDROID__`) are left out as dead weight on every target
/// this tree ships. Everything else under src/lib compiles clean on all
/// three (see ares_config.h and the macOS SystemConfiguration shim next
/// to it in core/darwin-compat/ for what that took).
const cares_sources = [_][]const u8{
    "ares_addrinfo2hostent.c",
    "ares_addrinfo_localhost.c",
    "ares_cancel.c",
    "ares_close_sockets.c",
    "ares_conn.c",
    "ares_cookie.c",
    "ares_data.c",
    "ares_destroy.c",
    "ares_free_hostent.c",
    "ares_free_string.c",
    "ares_freeaddrinfo.c",
    "ares_getaddrinfo.c",
    "ares_getenv.c",
    "ares_gethostbyaddr.c",
    "ares_gethostbyname.c",
    "ares_getnameinfo.c",
    "ares_hosts_file.c",
    "ares_init.c",
    "ares_library_init.c",
    "ares_metrics.c",
    "ares_options.c",
    "ares_parse_into_addrinfo.c",
    "ares_process.c",
    "ares_qcache.c",
    "ares_query.c",
    "ares_search.c",
    "ares_send.c",
    "ares_set_socket_functions.c",
    "ares_socket.c",
    "ares_sortaddrinfo.c",
    "ares_strerror.c",
    "ares_sysconfig.c",
    "ares_sysconfig_files.c",
    "ares_sysconfig_mac.c",
    "ares_timeout.c",
    "ares_update_servers.c",
    "ares_version.c",
    "dsa/ares_array.c",
    "dsa/ares_htable.c",
    "dsa/ares_htable_asvp.c",
    "dsa/ares_htable_dict.c",
    "dsa/ares_htable_strvp.c",
    "dsa/ares_htable_szvp.c",
    "dsa/ares_htable_vpstr.c",
    "dsa/ares_htable_vpvp.c",
    "dsa/ares_llist.c",
    "dsa/ares_slist.c",
    "event/ares_event_configchg.c",
    "event/ares_event_epoll.c",
    "event/ares_event_kqueue.c",
    "event/ares_event_poll.c",
    "event/ares_event_select.c",
    "event/ares_event_thread.c",
    "event/ares_event_wake_pipe.c",
    "inet_net_pton.c",
    "inet_ntop.c",
    "legacy/ares_create_query.c",
    "legacy/ares_expand_name.c",
    "legacy/ares_expand_string.c",
    "legacy/ares_fds.c",
    "legacy/ares_getsock.c",
    "legacy/ares_parse_a_reply.c",
    "legacy/ares_parse_aaaa_reply.c",
    "legacy/ares_parse_caa_reply.c",
    "legacy/ares_parse_mx_reply.c",
    "legacy/ares_parse_naptr_reply.c",
    "legacy/ares_parse_ns_reply.c",
    "legacy/ares_parse_ptr_reply.c",
    "legacy/ares_parse_soa_reply.c",
    "legacy/ares_parse_srv_reply.c",
    "legacy/ares_parse_txt_reply.c",
    "legacy/ares_parse_uri_reply.c",
    "record/ares_dns_mapping.c",
    "record/ares_dns_multistring.c",
    "record/ares_dns_name.c",
    "record/ares_dns_parse.c",
    "record/ares_dns_record.c",
    "record/ares_dns_write.c",
    "str/ares_buf.c",
    "str/ares_str.c",
    "str/ares_strsplit.c",
    "util/ares_iface_ips.c",
    "util/ares_math.c",
    "util/ares_rand.c",
    "util/ares_threads.c",
    "util/ares_timeval.c",
    "util/ares_uri.c",
};

/// curl's own file list, minus what vendor/curl's PIN already prunes
/// (every non-HTTP(S) protocol, every TLS backend but mbedtls, NTLM/
/// Kerberos/SASL) and minus its Windows- and AmigaOS-only sources
/// (`amigaos.c`, `dllmain.c`, `curl_sspi.c`, `system_win32.c`,
/// `version_win32.c`, `winapi.c`), which would compile to nothing on
/// these targets but add nothing either. Everything named here compiled
/// clean, individually, on all three targets before being wired in.
///
/// `socks.c` is in, despite SOCKS proxying being out of scope: its
/// `Curl_cft_socks_proxy`/`Curl_cf_socks_proxy_insert_after` are
/// referenced unconditionally by `cf-setup.c`/`curl_trc.c` (the proxy
/// connection filter chain is wired up generically, whichever proxy
/// type ends up chosen at runtime) -- HTTP proxying through
/// HTTPS_PROXY, the thing this tree actually wants, needs the same
/// file present to link, whether or not a caller ever asks for a
/// `socks5://` proxy URL. `vquic/vquic.c` is in for the same reason:
/// `Curl_conn_may_http3` is referenced from `http.c`/
/// `cf-https-connect.c` regardless of HTTP/3 support; without
/// `USE_NGTCP2`/`USE_NGHTTP3`/`USE_QUICHE` defined (none are, and none
/// of those libraries are vendored) the file's own `#else` branch
/// compiles to a five-line stub that always answers
/// `CURLE_NOT_BUILT_IN`.
const curl_sources = [_][]const u8{
    "altsvc.c",           "api.c",
    "bufq.c",              "bufref.c",
    "cf-h1-proxy.c",       "cf-h2-proxy.c",
    "cf-haproxy.c",        "cf-https-connect.c",
    "cf-ip-happy.c",       "cf-recvbuf.c",
    "cf-setup.c",          "cf-socket.c",
    "cfilters.c",          "conncache.c",
    "connect.c",           "content_encoding.c",
    "cookie.c",            "creds.c",
    "cshutdn.c",           "curl_addrinfo.c",
    "curl_ed25519.c",      "curl_endian.c",
    "curl_fnmatch.c",      "curl_fopen.c",
    "curl_get_line.c",     "curl_gssapi.c",
    "curl_memrchr.c",      "curl_range.c",
    "curl_sha512_256.c",   "curl_share.c",
    "curl_threads.c",      "curl_trc.c",
    "curlx/base64.c",      "curlx/basename.c",
    "curlx/dynbuf.c",      "curlx/fopen.c",
    "curlx/inet_ntop.c",   "curlx/inet_pton.c",
    "curlx/multibyte.c",   "curlx/nonblock.c",
    "curlx/snprintf.c",    "curlx/strcopy.c",
    "curlx/strdup.c",      "curlx/strerr.c",
    "curlx/strparse.c",    "curlx/timediff.c",
    "curlx/timeval.c",     "curlx/wait.c",
    "curlx/warnless.c",    "cw-out.c",
    "cw-pause.c",          "dynhds.c",
    "easy.c",              "easygetopt.c",
    "easyoptions.c",       "escape.c",
    "fake_addrinfo.c",     "fileinfo.c",
    "formdata.c",          "getenv.c",
    "getinfo.c",           "hash.c",
    "headers.c",           "hmac.c",
    "hsts.c",              "http.c",
    "http1.c",             "http2.c",
    "http_aws_sigv4.c",    "http_chunks.c",
    "http_digest.c",       "http_httpsig.c",
    "http_negotiate.c",    "http_ntlm.c",
    "http_proxy.c",        "idn.c",
    "if2ip.c",             "llist.c",
    "macos.c",             "md4.c",
    "md5.c",               "memdebug.c",
    "mime.c",              "mprintf.c",
    "multi.c",             "multi_ev.c",
    "multi_ntfy.c",        "netrc.c",
    "parsedate.c",         "peer.c",
    "pingpong.c",          "progress.c",
    "protocol.c",          "proxy.c",
    "psl.c",               "rand.c",
    "ratelimit.c",         "request.c",
    "select.c",            "sendf.c",
    "setopt.c",            "sha256.c",
    "slist.c",             "socketpair.c",
    "socks.c",
    "splay.c",             "strcase.c",
    "strequal.c",          "strerror.c",
    "thrdpool.c",          "thrdqueue.c",
    "transfer.c",          "uint-bset.c",
    "uint-hash.c",         "uint-hashset.c",
    "uint-spbset.c",       "uint-table.c",
    "url.c",               "urlapi.c",
    "vauth/cleartext.c",   "vauth/cram.c",
    "vauth/digest.c",      "vauth/digest_sspi.c",
    "vauth/oauth2.c",      "vauth/spnego_gssapi.c",
    "vauth/spnego_sspi.c", "vauth/vauth.c",
    "vdns/asyn-ares.c",    "vdns/asyn-base.c",
    "vdns/cf-dns.c",       "vdns/dnscache.c",
    "vdns/doh.c",          "vdns/hostip.c",
    "vdns/hostip4.c",      "vdns/hostip6.c",
    "vdns/httpsrr.c",      "version.c",
    "vquic/vquic.c",
    "vtls/apple.c",        "vtls/cipher_suite.c",
    "vtls/hostcheck.c",    "vtls/keylog.c",
    "vtls/mbedtls.c",      "vtls/vtls.c",
    "vtls/vtls_config.c",  "vtls/vtls_scache.c",
    "vtls/vtls_spack.c",   "vtls/x509asn1.c",
    "ws.c",
};

const core_sources = [_][]const u8{
    "boot.c",
    "coverage.c",
    "compress.c",
    "crypto.c",
    "environment.c",
    "executable.c",
    "hash.c",
    "http.c",
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
    const cares = patched(b, applier, "cares");
    const curl = patched(b, applier, "curl");
    const cacert_data = embedCacert(b);

    // The patched copies land under o/vendor, which is where the boot
    // bridge reads the Teal compiler from.
    const vendored = b.step("vendor", "write the patched vendor trees");
    for ([_]struct { []const u8, std.Build.LazyPath }{
        .{ "lua", lua },         .{ "sqlite", sqlite },
        .{ "tl", tl },           .{ "miniz", miniz },
        .{ "mbedtls", mbedtls }, .{ "bzip2", bzip2 },
        .{ "xz", xz },           .{ "cares", cares },
        .{ "curl", curl },
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
        const exe = core(b, t, release_configuration, resolved, lua, sqlite, miniz, mbedtls, bzip2, xz, cares, curl, cacert_data, false, .off);
        const out = b.addInstallFile(
            exe.getEmittedBin(),
            b.fmt("core/{s}/cosmic-core", .{t.name}),
        );
        cores.dependOn(&out.step);

        const hooked = core(b, t, release_configuration, resolved, lua, sqlite, miniz, mbedtls, bzip2, xz, cares, curl, cacert_data, true, .off);
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
    // On an ELF host it also observes its own C, so the suite it runs
    // writes the core's lines into the same coverage tables as Teal's.
    const sanitized = b.step("sanitized", "build and boot the checked core");
    const checked_target = hostTarget(b);
    const checked_host = baselineHostTarget(b);
    const checked = checked: {
        // The map reads DWARF from an ELF file; a Mach-O host's checked
        // core stays uninstrumented rather than half-mapped.
        if (checked_host.result.ofmt != .elf)
            break :checked core(b, checked_target, sanitized_configuration, checked_host, lua, sqlite, miniz, mbedtls, bzip2, xz, cares, curl, cacert_data, false, .off);
        const first = core(b, checked_target, sanitized_configuration, checked_host, lua, sqlite, miniz, mbedtls, bzip2, xz, cares, curl, cacert_data, false, .first_link);
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
        const second = core(b, checked_target, sanitized_configuration, checked_host, lua, sqlite, miniz, mbedtls, bzip2, xz, cares, curl, cacert_data, false, .{ .map = map });
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

/// Reads `vendor/cacert/cacert.pem` and writes a generated C source
/// defining it as a byte array the core links in (`core/cacert.h`
/// declares the two symbols). Read once, at `build.zig` graph
/// construction, the same way `bin/zig.pin` is read through
/// `@embedFile` above -- there is no vendor patch mechanism to route a
/// single plain-text file through, and generating C source text is
/// simpler than an `.incbin` assembly stub given how this module is
/// otherwise a pure C compile with no Zig root source of its own.
/// $SSL_CERT_FILE, when the sandbox's HTTPS-proxying environment sets
/// one, is read and added to the trust store at runtime instead (in
/// `core/http.c`), not baked in here: it names a file the *running*
/// machine provides, which is not this build's to see.
fn embedCacert(b: *std.Build) std.Build.LazyPath {
    const path = "vendor/cacert/cacert.pem";
    const pem = b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(1 << 20)) catch |err|
        std.debug.panic("reading {s}: {s}", .{ path, @errorName(err) });

    var source = std.ArrayList(u8).empty;
    source.appendSlice(b.allocator, "/* Generated by build.zig's embedCacert from vendor/cacert/cacert.pem. */\n#include <stddef.h>\nconst unsigned char cosmic_cacert_pem[] = {\n") catch @panic("OOM");
    for (pem, 0..) |byte, i| {
        source.appendSlice(b.allocator, b.fmt("{d},", .{byte})) catch @panic("OOM");
        if (i % 20 == 19) source.append(b.allocator, '\n') catch @panic("OOM");
    }
    source.appendSlice(b.allocator, "\n};\nconst size_t cosmic_cacert_pem_len = sizeof(cosmic_cacert_pem);\n") catch @panic("OOM");

    const generated = b.addWriteFiles();
    return generated.add("cacert_data.c", source.items);
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
    cares: std.Build.LazyPath,
    curl: std.Build.LazyPath,
    cacert_data: std.Build.LazyPath,
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
    // on either OS, and dynamic loading from Lua is never wanted -- the
    // module store is the only door. Same flag on both, so `nm`/`strings`
    // finds no dlopen symbol reachable from Lua in either core.
    //
    // The one dlopen the macOS core itself does is c-ares's, in
    // ares_sysconfig_mac.c: Apple's DNS configuration only comes out
    // whole through a handful of configd-internal symbols that
    // `libresolv` and `scutil` use and that c-ares reaches by dlopening
    // libSystem, since there is no header or static import for them.
    // That is a deliberate, narrow carve-out to this rule -- one
    // library, one target, one already-loaded system library -- not a
    // door into the module store.
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

    // mbedtls: the PSA crypto subtree, then the TLS 1.2/1.3 client and
    // X.509 layer above it, all under the one configuration header (see
    // `mbedtls_config`). The crypto files below are the ones that hold
    // code under that configuration; every other one compiles to nothing.
    const mbedtls_flags = [_][]const u8{"-std=c11"} ++ mbedtls_config;
    const crypto = mbedtls.path(b, "tf-psa-crypto");
    mod.addCSourceFiles(.{
        .root = crypto,
        .files = &.{
            "core/psa_crypto.c",
            "core/psa_crypto_client.c",
            "core/psa_crypto_driver_wrappers_no_static.c",
            "core/psa_crypto_random.c",
            "core/psa_crypto_slot_management.c",
            "core/psa_util.c",
            "platform/platform_util.c",
            "utilities/constant_time.c",
            // Digests, MACs and the cipher/AEAD dispatch layers.
            "drivers/builtin/src/md5.c",
            "drivers/builtin/src/sha1.c",
            "drivers/builtin/src/sha256.c",
            "drivers/builtin/src/sha3.c",
            "drivers/builtin/src/sha512.c",
            "drivers/builtin/src/psa_crypto_aead.c",
            "drivers/builtin/src/psa_crypto_cipher.c",
            "drivers/builtin/src/psa_crypto_ecp.c",
            "drivers/builtin/src/psa_crypto_hash.c",
            "drivers/builtin/src/psa_crypto_mac.c",
            "drivers/builtin/src/psa_crypto_rsa.c",
            "drivers/builtin/src/psa_util_internal.c",
            "drivers/builtin/src/cipher.c",
            "drivers/builtin/src/cipher_wrap.c",
            "drivers/builtin/src/block_cipher.c",
            // Big-number and elliptic-curve arithmetic for ECDH, ECDSA
            // and RSA, and HMAC-DRBG (deterministic ECDSA's nonce
            // generator -- the only DRBG built, since everything else
            // draws randomness from the OS through
            // mbedtls_psa_external_get_random).
            "drivers/builtin/src/bignum.c",
            "drivers/builtin/src/bignum_core.c",
            "drivers/builtin/src/bignum_mod.c",
            "drivers/builtin/src/bignum_mod_raw.c",
            "drivers/builtin/src/ecp.c",
            "drivers/builtin/src/ecp_curves.c",
            "drivers/builtin/src/ecp_curves_new.c",
            "drivers/builtin/src/ecdsa.c",
            "drivers/builtin/src/rsa.c",
            "drivers/builtin/src/rsa_alt_helpers.c",
            "drivers/builtin/src/hmac_drbg.c",
            // Record protection. aesni.c holds the x86_64 AES-NI path
            // and aesce.c the Armv8 one; each is empty on the other
            // architecture. On aarch64, chacha20_neon.c holds the
            // NEON-multiblock update() and is empty elsewhere.
            "drivers/builtin/src/aes.c",
            "drivers/builtin/src/aesni.c",
            "drivers/builtin/src/aesce.c",
            "drivers/builtin/src/gcm.c",
            "drivers/builtin/src/chacha20.c",
            "drivers/builtin/src/chacha20_neon.c",
            "drivers/builtin/src/chachapoly.c",
            "drivers/builtin/src/poly1305.c",
            // Certificate public keys and the encodings under them.
            "extras/md.c",
            "extras/pk.c",
            "extras/pkparse.c",
            "extras/pk_wrap.c",
            "extras/pk_ecc.c",
            "extras/pk_rsa.c",
            "utilities/asn1parse.c",
            "utilities/asn1write.c",
            "utilities/base64.c",
            "utilities/pem.c",
            "utilities/oid.c",
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
    mod.addCSourceFiles(.{
        .root = mbedtls.path(b, "library"),
        .files = &mbedtls_tls_sources,
        .flags = &mbedtls_flags,
    });
    mod.addIncludePath(mbedtls.path(b, "include"));
    mod.addIncludePath(mbedtls.path(b, "library"));

    // c-ares: DNS resolution for the `fetch`/`http` module, on every
    // target -- including macOS, where AGENTS.md's usual "dynamic
    // loading is never wanted" rule gets its one deliberate carve-out.
    // Apple's DNS configuration is only fully readable through configd,
    // whose relevant symbols c-ares dlopens from libSystem itself
    // (ares_sysconfig_mac.c) rather than linking against; there is no
    // static alternative, so this is that one door left open, and only
    // on macOS. c-ares's own thread support (CARES_THREADS) is off: the
    // core drives one poll loop itself, matching `cosmic.child`.
    const cares_flags = [_][]const u8{
        "-std=c11",      "-DHAVE_CONFIG_H",
        "-D_GNU_SOURCE", "-D_DEFAULT_SOURCE",
    };
    mod.addCSourceFiles(.{
        .root = cares.path(b, "src/lib"),
        .files = &cares_sources,
        .flags = &cares_flags,
    });
    mod.addIncludePath(cares.path(b, "include"));
    mod.addIncludePath(cares.path(b, "src/lib"));
    mod.addIncludePath(cares.path(b, "src/lib/include"));
    if (target_record.query.os_tag == .macos) {
        mod.addIncludePath(b.path("core/darwin-compat"));
    }

    // curl: HTTP and HTTPS only (every other protocol's sources are
    // already gone from vendor/curl's PIN), DNS through the c-ares just
    // built (USE_ARES) rather than curl's own thread-pool or plain
    // getaddrinfo() resolver, TLS through mbedtls (USE_MBEDTLS) rather
    // than any of the half-dozen other backends curl supports. No zlib
    // (no Content-Encoding decompression), no HTTP/2, no cookies -- see
    // core/curl_config.h for the full rationale. vtls/mbedtls.c includes
    // mbedtls's headers, so curl is compiled against the same mbedtls
    // configuration as the library itself.
    const curl_flags = [_][]const u8{
        "-std=c11", "-DHAVE_CONFIG_H", "-DBUILDING_LIBCURL",
        "-D_GNU_SOURCE", "-D_DEFAULT_SOURCE",
    } ++ mbedtls_config;
    mod.addCSourceFiles(.{
        .root = curl.path(b, "lib"),
        .files = &curl_sources,
        .flags = &curl_flags,
    });
    mod.addIncludePath(curl.path(b, "lib"));
    mod.addIncludePath(curl.path(b, "include"));

    // The embedded Mozilla CA bundle (see embedCacert above), one
    // generated source, no flags of its own beyond -std=c11.
    mod.addCSourceFile(.{ .file = cacert_data, .flags = &.{"-std=c11"} });

    // The core sees the library through the same configuration it was
    // built with, or the headers would describe another library.
    const core_flags = [_][]const u8{
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
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
    // Last, and uninstrumented, so both links hold the same blocks in the
    // same order: the table is data and adds none.
    switch (native_coverage) {
        .off, .first_link => {},
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
