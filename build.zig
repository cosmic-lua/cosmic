//! The C build: the core executable for each target, from the patched
//! vendor trees bin/zig writes first (build/patch.tl).
//!
//!     bin/zig build cores     the core for all three targets
//!     bin/zig build boot      all release cores, then the boot bridge
//!
//! Everything lands in the install prefix bin/zig hands it: the build
//! directory build/paths.tl names. Run it through [`bin/zig`], which pins the
//! compiler and names zig's two caches, which every checkout shares
//! (build/zig.tl): everything, vendored or the tree's own, compiles from
//! copies in the project cache, so a checkout at a path no build has seen
//! compiles nothing another has ([`Own`]).

const std = @import("std");
const builtin = @import("builtin");

/// [`bin/zig.pin`], read at comptime so that it is the one place that names
/// the pinned version.
const zig_pin = @embedFile("bin/zig.pin");

/// The version line out of [`bin/zig.pin`] ("version X.Y.Z"), parsed at
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
    /// The name the database and the build directory's `bin/` use.
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

/// Whether a core observes its own C ([`core/coverage.c`]): not at all, or
/// with sancov's per-block flags, once linked with an empty block-to-line
/// table (`first_link`, read for its debug information and never run) and
/// once carrying the table [`core/coverage_map.zig`] wrote from that link.
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

/// The checked core also turns on Lua's own internal assertions and its C
/// API checks, which catch a binding that misuses the Lua stack -- a buffer
/// popped out from under itself, a pointer to a string no longer on the
/// stack -- where UBSan sees nothing wrong. Lua's headers change with
/// them, so the core's own C gets them too.
const lua_checks = [_][]const u8{ "-DLUAI_ASSERT", "-DLUA_USE_APICHECK" };

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
/// Every C compile's debug information names its directory `.` rather
/// than the tree root of whichever build first compiled it: zig's object
/// cache does not key an object by the cwd, so a cached object would
/// carry an old checkout's path into the checked core, which keeps its
/// debug information, and move its bytes (and every checked verdict's
/// key) from one build to the next.
///
/// Two paths of the build are left in the checked core. One is musl's
/// (the TODO below). The other is the vendored trees' own paths, under
/// the project cache's `cosmic-vendor/`, in their `assert` strings and
/// type names. Each directory is named by its contents, so those paths
/// are the same from every checkout at one cache path, which CI's is
/// (COSMIC_ZIG_CACHE_SEED); a checkout's own `zig-cache`, in its build
/// directory, names that
/// checkout, as run-local's does.
// TODO: compile musl's debug information with `.` for its directory,
// or strip it alone, once zig's libc build takes our flags (zig 0.17
// builds it in the global cache with none of ours, keyed without the
// cwd): each musl unit names the tree root of whichever checkout first
// built libc into zig-global, so the checked core's bytes are not the
// same from every checkout, and ci/cosmic_ci/orchestration.tl cannot
// hold every unit's DW_AT_comp_dir to `.`. No verdict's key moves with
// it: a core carrying DWARF is keyed by its image, which leaves the
// debug sections out (build/core_image.tl). Building from a fixed cwd
// (bin/zig starting zig elsewhere than the tree) would do it now, at
// the cost of every relative path bin/zig and build.zig take.
const debug_dir = "-fdebug-compilation-dir=.";
const own_c = [_][]const u8{ "-std=c11", debug_dir } ++ own_warnings;

/// mbedtls's compile-time configuration, which is
/// [`core/mbedtls_cosmic_config.h`] and nothing else: that header is named
/// as both configuration files the library reads (tf-psa-crypto's and
/// mbedtls's own), and no `MBEDTLS_` or `PSA_WANT_` macro is passed on a
/// command line. Every file that includes the library's headers -- the
/// crypto subtree, the TLS and X.509 layer, curl's mbedtls backend and
/// the core's own C -- is compiled with exactly these flags, so none of
/// them can see a struct laid out differently from the one the library
/// was built with. Its directory is named by its contents, so an edit to
/// it compiles again every file given that directory: mbedtls, curl and
/// the core's own C ([`vendorLibraries`], [`core`]).
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

/// c-ares's sources that hold code on at least one target here. Its own
/// thread support (CARES_THREADS) is never built -- the core drives one
/// poll loop itself -- so the event-thread backends under event/ (epoll,
/// kqueue, poll, select, the wake pipe) compile to nothing and are left
/// out, as are the Windows-only (windows_port.c, ares_sysconfig_win.c,
/// ares_getenv.c) and Android-only (ares_android.c) files.
/// ares_sysconfig_mac.c holds code on macOS only. See ares_config.h and
/// the SystemConfiguration shim in core/darwin-compat/.
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
    "event/ares_event_thread.c",
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

/// curl's sources that hold code under core/curl_config.h on at least
/// one target here. What vendor/curl's PIN prunes (every non-HTTP(S)
/// protocol, every TLS backend but mbedtls, NTLM/Kerberos/SASL, the
/// Windows- and AmigaOS-only files) is not named, and neither is any
/// file the configuration empties: cookies, HSTS, Alt-Svc, DoH, .netrc,
/// PSL, the GSSAPI/SSPI/NTLM/AWS/HTTP-signature auth files, the
/// threaded and getaddrinfo resolvers (c-ares resolves), hostcheck.c
/// (mbedtls checks the host name itself), and the Apple helpers. A
/// file that becomes non-empty after a curl_config.h change has to be
/// added back, or the link says which symbol it misses.
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
    "api.c",
    "bufq.c",
    "bufref.c",
    "cf-h1-proxy.c",
    "cf-haproxy.c",
    "cf-https-connect.c",
    "cf-ip-happy.c",
    "cf-setup.c",
    "cf-socket.c",
    "cfilters.c",
    "conncache.c",
    "connect.c",
    "content_encoding.c",
    "creds.c",
    "cshutdn.c",
    "curl_addrinfo.c",
    "curl_endian.c",
    "curl_memrchr.c",
    "curl_share.c",
    "curl_trc.c",
    "curlx/base64.c",
    "curlx/dynbuf.c",
    "curlx/fopen.c",
    "curlx/inet_ntop.c",
    "curlx/inet_pton.c",
    "curlx/nonblock.c",
    "curlx/strcopy.c",
    "curlx/strdup.c",
    "curlx/strerr.c",
    "curlx/strparse.c",
    "curlx/timediff.c",
    "curlx/timeval.c",
    "curlx/wait.c",
    "curlx/warnless.c",
    "cw-out.c",
    "cw-pause.c",
    "dynhds.c",
    "easy.c",
    "easygetopt.c",
    "easyoptions.c",
    "escape.c",
    "formdata.c",
    "getenv.c",
    "getinfo.c",
    "hash.c",
    "headers.c",
    "hmac.c",
    "http.c",
    "http1.c",
    "http2.c",
    "http_chunks.c",
    "http_digest.c",
    "http_proxy.c",
    "idn.c",
    "if2ip.c",
    "llist.c",
    "md5.c",
    "mime.c",
    "mprintf.c",
    "multi.c",
    "multi_ev.c",
    "multi_ntfy.c",
    "parsedate.c",
    "peer.c",
    "progress.c",
    "protocol.c",
    "proxy.c",
    "rand.c",
    "ratelimit.c",
    "request.c",
    "select.c",
    "sendf.c",
    "setopt.c",
    "sha256.c",
    "slist.c",
    "socketpair.c",
    "socks.c",
    "splay.c",
    "strcase.c",
    "strequal.c",
    "strerror.c",
    "transfer.c",
    "uint-bset.c",
    "uint-hash.c",
    "uint-hashset.c",
    "uint-spbset.c",
    "uint-table.c",
    "url.c",
    "urlapi.c",
    "vauth/cram.c",
    "vauth/digest.c",
    "vauth/vauth.c",
    "vdns/asyn-ares.c",
    "vdns/asyn-base.c",
    "vdns/cf-dns.c",
    "vdns/dnscache.c",
    "vdns/hostip.c",
    "version.c",
    "vquic/vquic.c",
    "vtls/cipher_suite.c",
    "vtls/keylog.c",
    "vtls/mbedtls.c",
    "vtls/vtls.c",
    "vtls/vtls_config.c",
    "vtls/vtls_scache.c",
    "vtls/x509asn1.c",
    "ws.c",
};

/// Where the crypto library's headers are, under its `tf-psa-crypto`.
const crypto_include_dirs = [_][]const u8{
    "include",             "core",     "drivers/builtin/include",
    "drivers/builtin/src", "dispatch", "utilities",
    "platform",            "extras",
};

/// Those of [`crypto_include_dirs`] that hold the crypto library's public
/// headers, all that curl and the core's own C read of it.
const crypto_public_dirs = [_][]const u8{ "include", "drivers/builtin/include" };

/// `names`, directories under `crypto`, the library's `tf-psa-crypto`.
fn cryptoIncludes(
    b: *std.Build,
    crypto: std.Build.LazyPath,
    comptime names: []const []const u8,
) [names.len]std.Build.LazyPath {
    var dirs: [names.len]std.Build.LazyPath = undefined;
    for (&dirs, names) |*dir, name| dir.* = crypto.path(b, name);
    return dirs;
}

const core_sources = [_][]const u8{
    "assertions.c",
    "boot.c",
    "coverage.c",
    "compress.c",
    "connector.c",
    "crypto.c",
    "environment.c",
    "errnos.c",
    "executable.c",
    "hash.c",
    "html.c",
    "http.c",
    "json.c",
    "namespace_calls.c",
    "socket.c",
    "sqlite.c",
    "store.c",
    "strnlen.c",
    "surface.c",
    "syscalls.c",
    "syscalls_fs.c",
    "vfs.c",
    "main.c",
    "portable.c",
    "promises.c",
    "startup.c",
};

/// The tree's own C, compiled from copies in zig's project cache as
/// vendor/ is (see the head of `build`): zig keys a C object by its
/// source's absolute path and its flags' bytes, an include directory's
/// among them, so a file compiled where the tree is would be compiled
/// again for every path a checkout sits at -- CI's is a new one each commit
/// (ci/cosmic_ci/place_tree.tl). A copy sits in a directory named by
/// its contents, so its path is the same from every checkout.
///
/// Each source file is copied on its own, beside a copy of the headers it
/// includes, directly or through another header, laid out as the tree is
/// (`core/x.c` beside `core/x.h`): a quoted `#include` finds its neighbour
/// first, as in the tree. An edit to a header moves the copy of exactly the
/// files that include it, so only their objects compile again; the compiler
/// itself records the headers an object read, so a copy that holds one it
/// did not read costs nothing but the copy. A file outside core/ (test/...)
/// names core/'s headers with no include path: the copy holds a header
/// of that name beside it that includes core's, so nothing but the
/// closure is a flag or a path. `closure` finds the headers by reading
/// `#include` lines, whether or not a `#if` keeps them, so a copy holds
/// at least what any configuration reads; a quoted name found neither
/// beside the includer nor in core/ is a library's, which an include path
/// of the library's own tree finds (and keys). [`closureChecks`] holds the
/// scan to the compiler's own list, in `analyze`.
///
/// Only a quoted `#include` of a name is followed: one of a macro, a
/// `..` path, or an angle-bracket name that is a header of core/ fails the
/// build, naming the line. Debug information names the copy, which is
/// there to read, and whose path ends in the tree's own (`.../core/x.c`):
/// [`core/coverage_map.zig`] maps a line back to the tree by it. The
/// checked core's sanitizer names the tree's `core/x.c` (`checked_flags`)
/// -- except in an unnamed type's name, which holds the copy's path, so
/// the core's own C names its types -- and the analyzer reads the tree's
/// own files (`analyze`).
// TODO: name the tree's file in a compile's error, not its copy in the
// cache: clang has no flag remapping a diagnostic's path, so bin/zig
// would rewrite zig's output, `<cache>/o/<digest>/` to the tree's root.
const Own = struct {
    b: *std.Build,
    /// Each source file copied so far, by its path in the tree, to the
    /// directory holding its copy at that path. One copy per file, however
    /// many compiles read it: two steps writing one directory at once
    /// could hand a compile a file half written.
    roots: std.StringArrayHashMapUnmanaged(std.Build.LazyPath),
    /// Each tree file `closure` read, by path: its text, or null where
    /// there is no such file.
    texts: std.StringHashMapUnmanaged(?[]const u8),
    /// Each file's closure, by its path.
    closures: std.StringHashMapUnmanaged(Closure),

    /// The tree files a source file's copy holds, sorted: the file, and
    /// each header it includes, however deep.
    const Closure = struct {
        files: []const []const u8,
        /// A header beside a file outside core/ that includes core's of the
        /// same name, for a name the file includes that only core/ holds.
        forwards: []const Forward,
    };

    const Forward = struct {
        /// The tree path the header sits at in the copy.
        at: []const u8,
        /// The core header it includes: a tree path.
        target: []const u8,
        /// `target` as the header names it, relative to its own directory.
        relative: []const u8,
    };

    fn init(b: *std.Build) *Own {
        const own = b.allocator.create(Own) catch @panic("OOM");
        own.* = .{ .b = b, .roots = .empty, .texts = .empty, .closures = .empty };
        return own;
    }

    /// The text of the tree's `path`, or null if there is none. zig caches
    /// what build.zig configures, keyed by what it reads through the build
    /// API alone: a file read is declared so that an edit to it, to an
    /// include line above all, configures again, and a directory listed
    /// so that a header added beside the includer, shadowing a library's,
    /// does too.
    fn text(own: *Own, path: []const u8) ?[]const u8 {
        const b = own.b;
        if (own.texts.get(path)) |found| return found;
        const key = b.graph.dupeString(path);
        const at = b.root.joinString(b.allocator, path) catch @panic("OOM");
        const read: ?[]const u8 = std.Io.Dir.cwd().readFileAlloc(b.graph.io, at, b.allocator, .limited(1 << 24)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                std.debug.print("build.zig: cannot read {s}: {s}\n", .{ path, @errorName(err) });
                std.process.exit(1);
            },
        };
        if (read != null) b.dependOnFileContents(b.path(path));
        own.texts.put(b.allocator, key, read) catch @panic("OOM");
        return read;
    }

    fn fail(path: []const u8, number: usize, comptime what: []const u8) noreturn {
        std.debug.print("build.zig: {s}:{d}: " ++ what ++ "\n", .{ path, number });
        std.process.exit(1);
    }

    /// The headers `path`, a C file of the tree, includes, as a closure.
    fn closure(own: *Own, path: []const u8) Closure {
        const b = own.b;
        if (own.closures.get(path)) |found| return found;
        var files: std.ArrayList([]const u8) = .empty;
        var forwards: std.ArrayList(Forward) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        files.append(b.allocator, b.graph.dupeString(path)) catch @panic("OOM");
        seen.put(b.allocator, files.items[0], {}) catch @panic("OOM");
        var next: usize = 0;
        while (next < files.items.len) : (next += 1) {
            const current = files.items[next];
            const directory = std.fs.path.dirname(current) orelse "";
            // Where a directory's listing matters: a header added beside
            // the includer, or to core/, changes what a name finds.
            b.dependOnDirectoryContents(b.path(if (directory.len == 0) "." else directory));
            b.dependOnDirectoryContents(b.path("core"));
            const source = own.text(current) orelse {
                std.debug.print("build.zig: {s} is not a file of the tree\n", .{current});
                std.process.exit(1);
            };
            var number: usize = 0;
            var lines = std.mem.splitScalar(u8, source, '\n');
            while (lines.next()) |line| {
                number += 1;
                var rest = std.mem.trimStart(u8, line, " \t");
                if (!std.mem.startsWith(u8, rest, "#")) continue;
                rest = std.mem.trimStart(u8, rest[1..], " \t");
                if (!std.mem.startsWith(u8, rest, "include")) continue;
                rest = rest["include".len..];
                if (rest.len > 0 and (std.ascii.isAlphanumeric(rest[0]) or rest[0] == '_'))
                    fail(current, number, "an `#include` directive other than include is not followed");
                rest = std.mem.trimStart(u8, rest, " \t");
                if (rest.len == 0) continue;
                const close: u8 = switch (rest[0]) {
                    '"' => '"',
                    '<' => '>',
                    else => fail(current, number, "an `#include` of a macro is not followed; name the header"),
                };
                const end = std.mem.indexOfScalarPos(u8, rest, 1, close) orelse
                    fail(current, number, "an `#include` that does not close");
                const name = rest[1..end];
                if (std.mem.indexOf(u8, name, "..") != null)
                    fail(current, number, "an `#include` with `..` is not followed");
                const beside = if (directory.len == 0) name else b.fmt("{s}/{s}", .{ directory, name });
                const in_core = b.fmt("core/{s}", .{name});
                if (close == '>') {
                    // A system name; but a header of core/ in angle
                    // brackets would have been found in core/'s include path,
                    // which a copy no longer has.
                    if (own.text(in_core) != null)
                        fail(current, number, "an angle-bracket `#include` of a header of core/; quote it");
                    continue;
                }
                var found: ?[]const u8 = null;
                if (own.text(beside) != null) {
                    found = beside;
                } else if (!std.mem.eql(u8, directory, "core") and own.text(in_core) != null) {
                    found = in_core;
                    var up: usize = 0;
                    if (directory.len > 0) {
                        up = 1;
                        for (directory) |c| up += @intFromBool(c == '/');
                    }
                    var relative: std.ArrayList(u8) = .empty;
                    for (0..up) |_| relative.appendSlice(b.allocator, "../") catch @panic("OOM");
                    relative.appendSlice(b.allocator, in_core) catch @panic("OOM");
                    for (forwards.items) |forward| {
                        if (std.mem.eql(u8, forward.at, beside)) break;
                    } else forwards.append(b.allocator, .{
                        .at = b.graph.dupeString(beside),
                        .target = b.graph.dupeString(in_core),
                        .relative = relative.items,
                    }) catch @panic("OOM");
                }
                const header = found orelse continue;
                if (seen.contains(header)) continue;
                const kept = b.graph.dupeString(header);
                seen.put(b.allocator, kept, {}) catch @panic("OOM");
                files.append(b.allocator, kept) catch @panic("OOM");
            }
        }
        std.mem.sort([]const u8, files.items, {}, lessThan);
        std.mem.sort(Forward, forwards.items, {}, struct {
            fn lessThan(_: void, x: Forward, y: Forward) bool {
                return std.mem.lessThan(u8, x.at, y.at);
            }
        }.lessThan);
        const done: Closure = .{ .files = files.items, .forwards = forwards.items };
        own.closures.put(b.allocator, b.graph.dupeString(path), done) catch @panic("OOM");
        return done;
    }

    fn lessThan(_: void, x: []const u8, y: []const u8) bool {
        return std.mem.lessThan(u8, x, y);
    }

    /// The directory holding the copy of `path`, a C file of the tree,
    /// at `path`, beside the headers it includes.
    fn root(own: *Own, path: []const u8) std.Build.LazyPath {
        const b = own.b;
        if (own.roots.get(path)) |found| return found;
        const files = b.addWriteFiles();
        const closed = own.closure(path);
        for (closed.files) |name| _ = files.addCopyFile(b.path(name), name);
        for (closed.forwards) |forward|
            _ = files.add(forward.at, b.fmt("#include \"{s}\"\n", .{forward.relative}));
        const copied = files.getDirectory();
        own.roots.put(b.allocator, b.graph.dupeString(path), copied) catch @panic("OOM");
        return copied;
    }

    /// The copy of `path`, a C file of the tree, to compile.
    fn file(own: *Own, path: []const u8) std.Build.LazyPath {
        return own.root(path).path(own.b, path);
    }

    /// Each of `paths`, C files of the tree, added to `mod` from its copy.
    fn add(own: *Own, mod: *std.Build.Module, paths: []const []const u8, flags: []const []const u8) void {
        for (paths) |path| mod.addCSourceFile(.{ .file = own.file(path), .flags = flags });
    }
};

pub fn build(b: *std.Build) void {
    // Everything the vendored libraries are compiled from sits in the zig
    // cache, where its path is the same from every checkout of the tree:
    // zig keys a C object by its source's path and its flags' bytes, and a
    // path into the tree is an absolute one. The patched trees are
    // build/patch.tl's output, which bin/zig writes before it runs zig into
    // directories named by their contents ([`patchedTrees`]), and the
    // configuration headers the libraries read from core/ are copied here.
    // A checkout sharing another's zig cache then compiles none of vendor/
    // again.
    const config = configHeaders(b);
    const own = Own.init(b);

    const trees = patchedTrees(b);
    const lua = patched(b, trees, "lua");
    const sqlite = patched(b, trees, "sqlite");
    const tl = patched(b, trees, "tl");
    const miniz = patched(b, trees, "miniz");
    const mbedtls = patched(b, trees, "mbedtls");
    const bzip2 = patched(b, trees, "bzip2");
    const xz = patched(b, trees, "xz");
    const cares = patched(b, trees, "cares");
    const curl = patched(b, trees, "curl");
    const yyjson = patched(b, trees, "yyjson");

    // The patched copies land in the build directory's vendor/, which is
    // where the boot
    // bridge reads the Teal compiler from.
    const vendored = b.step("vendor", "write the patched vendor trees");
    for ([_]struct { []const u8, std.Build.LazyPath }{
        .{ "lua", lua },         .{ "sqlite", sqlite },
        .{ "tl", tl },           .{ "miniz", miniz },
        .{ "mbedtls", mbedtls }, .{ "bzip2", bzip2 },
        .{ "xz", xz },           .{ "cares", cares },
        .{ "curl", curl },       .{ "yyjson", yyjson },
    }) |pair| {
        const install = b.addInstallDirectory(.{
            .source_dir = pair[1],
            .install_dir = .prefix,
            .install_subdir = b.fmt("vendor/{s}", .{pair[0]}),
        });
        vendored.dependOn(&install.step);
    }

    const cores = b.step("cores", "build the core for every target");
    const boot = b.step("boot", "build all release cores, then bridge into Teal");
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
        records = b.fmt("{s}{s}", .{ records, targetRecord(b, t, release_configuration, t.name) });
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
        own,
        "format-test-native",
        baselineHostTarget(b),
        .debug,
        null,
    );
    installFixture(
        b,
        portable_format_fixtures,
        native_format_decoder,
        "portable-fixture/format/format-test-native",
        "portable-format-native",
        "build the native portable-format decoder",
    );
    portable_format_fixtures.dependOn(&install_target_records.step);

    for (targets) |t| {
        const resolved = b.resolveTargetQuery(t.query);
        const target_format_decoder = formatDecoder(
            b,
            own,
            b.fmt("format-test-{s}", .{t.name}),
            resolved,
            .fast,
            t,
        );
        installFixture(
            b,
            portable_format_fixtures,
            target_format_decoder,
            b.fmt("portable-fixture/format/format-test-{s}", .{t.name}),
            b.fmt("portable-format-{s}", .{t.name}),
            b.fmt("build the {s} portable-format decoder", .{t.name}),
        );

        const payload = launcherHelper(
            b,
            own,
            b.fmt("launcher-payload-{s}", .{t.name}),
            "test/portable/launcher_payload.c",
            resolved,
        );
        installFixture(
            b,
            portable_launcher_fixtures,
            payload,
            b.fmt("portable-fixture/launcher/payload-{s}", .{t.name}),
            b.fmt("portable-launcher-payload-{s}", .{t.name}),
            b.fmt("build the {s} launcher payload", .{t.name}),
        );

        const socket = launcherHelper(
            b,
            own,
            b.fmt("launcher-socket-{s}", .{t.name}),
            "test/portable/launcher_socket_fd.c",
            resolved,
        );
        installFixture(
            b,
            portable_launcher_fixtures,
            socket,
            b.fmt("portable-fixture/launcher/socket-{s}", .{t.name}),
            b.fmt("portable-launcher-socket-{s}", .{t.name}),
            b.fmt("build the {s} launcher socket helper", .{t.name}),
        );
    }
    portable_launcher_fixtures.dependOn(&install_target_records.step);

    // The core's strnlen stands in for the toolchain's, which reads past
    // the end of a mapping (core/strnlen.c). The case that tells them
    // apart runs on the host with every boot.
    const strnlen_check = b.addExecutable(.{
        .name = "strnlen-check",
        .root_module = b.createModule(.{
            .target = baselineHostTarget(b),
            .optimize = .fast,
            .link_libc = true,
        }),
    });
    own.add(strnlen_check.root_module, &.{ "core/strnlen.c", "core/strnlen_test.c" }, &own_c);
    boot.dependOn(&b.addRunArtifact(strnlen_check).step);

    // Startup's reserved-prefix sweep has no fixed name count or length.
    const environment_check = b.addExecutable(.{
        .name = "environment-check",
        .root_module = b.createModule(.{
            .target = baselineHostTarget(b),
            .optimize = .safe,
            .link_libc = true,
        }),
    });
    own.add(environment_check.root_module, &.{ "core/environment.c", "core/environment_test.c" }, &own_c);
    boot.dependOn(&b.addRunArtifact(environment_check).step);

    // Every core but the test fixtures observes its own C: a table from
    // each core's first link, carried by its second ([`observedCore`]).
    // Debug, which keeps every safety check ReleaseSafe does: it reads a
    // core in tens of milliseconds either way, and compiles in a fifth of
    // the time, at the head of every cold build.
    const mapper = b.addExecutable(.{
        .name = "coverage-map",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/coverage_map.zig"),
            .target = baselineHostTarget(b),
            .optimize = .debug,
        }),
    });
    const sources: Sources = .{ .own = own, .lua = lua, .sqlite = sqlite, .miniz = miniz, .mbedtls = mbedtls, .bzip2 = bzip2, .xz = xz, .cares = cares, .curl = curl, .yyjson = yyjson, .config = config };

    for (targets) |t| {
        const resolved = b.resolveTargetQuery(t.query);
        const vendor = vendorLibraries(b, t, release_configuration, resolved, sources);
        const exe = observedCore(b, mapper, cores, t, release_configuration, resolved, sources, vendor);
        const out = b.addInstallFile(
            exe.getEmittedBin(),
            b.fmt("core/{s}/cosmic-core", .{t.name}),
        );
        cores.dependOn(&out.step);

        const hooked = core(b, t, release_configuration, resolved, sources, vendor, true, .off);
        const hooked_out = b.addInstallFile(
            hooked.getEmittedBin(),
            b.fmt("portable-fixture/core/{s}/cosmic-core", .{t.name}),
        );
        portable_hook_cores.dependOn(&hooked_out.step);

        if (std.mem.eql(u8, t.name, hostName(b))) {
            const bridge = b.addRunArtifact(exe);
            bridge.addArg("--boot");
            bridge.addDirectoryArg2(b.path("."), .{});
            bridge.addDirectoryArg2(tl, .{});
            bridge.addArg(t.name);
            bridge.addFileArg2(target_records, .{});
            bridge.addDirectoryArg2(
                .{ .relative = .{ .base = .install_prefix, .sub_path = "" } },
                .{ .make_absolute = true },
            );
            // The bridge reads every raw core and writes the database
            // beside them, so it runs after both.
            bridge.step.dependOn(cores);
            bridge.step.dependOn(vendored);
            bridge.has_side_effects = true;
            boot.dependOn(&bridge.step);
        }
    }

    // A fourth core, checked for undefined behavior: same sources, built
    // for the host's shipped target only, and installed beside the release
    // cores. Its portable artifact still carries all three required release
    // entries, plus this host's configuration-2 entry selected by its private
    // launcher.
    //
    // It is built for the shipped triple, static musl on Linux and
    // libSystem on macOS, never the build host's own libc: the libc under
    // test is then the one that ships (zig's lib/c and musl, whose printf
    // measures a string with core/strnlen.c, where glibc's used its own); its
    // floats are the release core's, where glibc's libm picked FMA
    // variants of pow, asin, acos and atan2 by the processor's features
    // and rounded a last bit differently (a Teal benchmark printed
    // -831.56112555875472 on a glibc checked core, -831.5611255587545 on
    // the release and musl ones); and every runner of one architecture,
    // glibc or musl, builds its checked core for the same target.
    //
    // What that gives up, for now, is what glibc's headers carried, which
    // musl's do not and zig adds nothing to: `__nonnull` on their
    // declarations gave the sanitizer 1389 null-argument checks
    // (`__ubsan_handle_nonnull_arg`), and `_FORTIFY_SOURCE` 77 calls to
    // checked copies (`__*_chk`) where an object's size is known. The
    // stack protector, which catches an overflow only once it reaches a
    // return address, remains.
    // TODO: recover the null-argument checks with a header the checked
    // build force-includes (`-include`), redeclaring with
    // `__attribute__((nonnull))` the libc functions the tree calls; it
    // waits on a list of those functions and their nonnull arguments,
    // which nothing in the tree yet derives from glibc's headers.
    // TODO: recover the fortify checks the same way, or with vendored
    // fortify-headers: 34 of the 77 were memcpy, memmove, memset and
    // strcpy, whose `__*_chk` zig's compiler_rt exports
    // (lib/compiler_rt/ssp.zig), so the header need only route them
    // through `__builtin___*_chk` with `__builtin_object_size`; the other
    // 43 (vsnprintf, vfprintf, read, pread, poll, getcwd, readlink,
    // realpath, explicit_bzero, longjmp) want wrappers in the header that
    // compare the size and call `__chk_fail`. It waits on that header,
    // and on the list of the calls it is to cover.
    const sanitized = b.step("sanitized", "build and boot the checked core");
    const analyzed = b.step("analyze", "run the static analyzer over the tree's own C");
    analyze(b, analyzed, sources);
    // The checked build is where CI already looks for what the release
    // build would only do quietly; the analyzer's findings are the same
    // kind of thing, found without running anything.
    sanitized.dependOn(analyzed);
    const checked_target = hostTarget(b);
    const checked_host = baselineTarget(b, checked_target.query);
    const checked_vendor = vendorLibraries(b, checked_target, sanitized_configuration, checked_host, sources);
    const checked = observedCore(b, mapper, sanitized, checked_target, sanitized_configuration, checked_host, sources, checked_vendor);
    const checked_install = b.addInstallFile(
        checked.getEmittedBin(),
        "sanitized/cosmic-core",
    );
    const checked_name = b.fmt("sanitized-{s}", .{checked_target.name});
    const checked_records = generated.add("sanitized-targets.tsv", b.fmt(
        "{s}{s}",
        .{ records, targetRecord(b, checked_target, sanitized_configuration, checked_name) },
    ));
    const checked_records_install = b.addInstallFile(
        checked_records,
        "sanitized/targets.tsv",
    );
    const checked_boot = b.addRunArtifact(checked);
    checked_boot.addArg("--boot");
    checked_boot.addDirectoryArg2(b.path("."), .{});
    checked_boot.addDirectoryArg2(tl, .{});
    checked_boot.addArg(checked_target.name);
    checked_boot.addFileArg2(target_records, .{});
    checked_boot.addDirectoryArg2(
        .{ .relative = .{ .base = .install_prefix, .sub_path = "" } },
        .{ .make_absolute = true },
    );
    checked_boot.addFileArg2(checked.getEmittedBin(), .{});
    checked_boot.addFileArg2(checked_records, .{});
    checked_boot.addDirectoryArg2(
        .{ .relative = .{ .base = .install_prefix, .sub_path = "sanitized" } },
        .{ .make_absolute = true },
    );
    checked_boot.step.dependOn(cores);
    checked_boot.step.dependOn(vendored);
    checked_boot.has_side_effects = true;
    sanitized.dependOn(&checked_install.step);
    sanitized.dependOn(&checked_records_install.step);
    sanitized.dependOn(&checked_boot.step);

    portable_hook_cores.dependOn(cores);

    b.getInstallStep().dependOn(cores);
}

fn targetRecord(b: *std.Build, target: Target, configuration: Configuration, name: []const u8) []const u8 {
    return b.fmt("{d}\t{d}\t{s}\t{s}\t{s}\t{s}\n", .{
        target.id,
        configuration.id,
        configuration.name,
        name,
        target.uname_os,
        target.uname_arch,
    });
}

fn installFixture(
    b: *std.Build,
    group: *std.Build.Step,
    executable: *std.Build.Step.Compile,
    path: []const u8,
    name: []const u8,
    description: []const u8,
) void {
    const install = b.addInstallFile(executable.getEmittedBin(), path);
    const step = b.step(name, description);
    step.dependOn(&install.step);
    group.dependOn(&install.step);
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
    own: *Own,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    target_record: ?Target,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Stripped like [`core()`] so a target build reuses the musl libc
        // `cores` already built; see [`launcherHelper()`]. The native Debug
        // decoder keeps its symbols.
        .strip = optimize != .debug,
    });
    own.add(mod, &.{ "core/portable.c", "test/portable/format_test.c" }, &own_c);
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
    own: *Own,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = .fast,
        .link_libc = true,
        // Matching [`core()`]'s strip setting keeps this module's musl libc
        // build cache-compatible with the one `cores` already built for
        // the same target: without it, `zig build` reruns a from-scratch
        // musl libc/compiler_rt build for this one-file helper, which cost
        // over a minute per cross target on a cold cache.
        .strip = true,
    });
    own.add(mod, &.{source}, &own_c);
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

/// The patched vendor trees bin/zig wrote before it ran zig
/// (build/patch.tl), as the manifest it names with `-Dpatched=` holds them:
/// a name, a tab and a directory per line. Each directory is named by its contents, so its path is the
/// same from every checkout.
fn patchedTrees(b: *std.Build) []const u8 {
    const manifest = b.option([]const u8, "patched", "the patched vendor trees' manifest bin/zig writes") orelse {
        std.debug.print("build.zig: no -Dpatched=; run bin/zig build, which patches vendor/ first\n", .{});
        std.process.exit(1);
    };
    // Immutable manifests in the shared cache have the same absolute path
    // in every checkout. Relative manifests remain valid for direct callers.
    const path: std.Build.LazyPath = if (std.fs.path.isAbsolute(manifest))
        .{ .cwd_relative = manifest }
    else
        b.path(manifest);
    b.dependOnFileContents(path);
    const at = if (std.fs.path.isAbsolute(manifest)) manifest else b.root.joinString(b.allocator, manifest) catch @panic("OOM");
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, at, b.allocator, .limited(1 << 20)) catch |err| {
        std.debug.print("build.zig: cannot read {s}: {s}\n", .{ manifest, @errorName(err) });
        std.process.exit(1);
    };
}

/// The patched copy of one vendored library, as a directory the core's
/// sources are read from: the one `trees`, the manifest bin/zig wrote,
/// names for it. Its contents are its name, so nothing under it is
/// watched.
fn patched(b: *std.Build, trees: []const u8, name: []const u8) std.Build.LazyPath {
    var lines = std.mem.splitScalar(u8, trees, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (std.mem.eql(u8, line[0..tab], name)) {
            return b.graph.cwdRelativePath(line[tab + 1 ..]);
        }
    }
    std.debug.print("build.zig: the patched trees' manifest names no {s}\n", .{name});
    std.process.exit(1);
}

/// Clang's static analyzer, the one `bin/zig cc` carries, over every C
/// file of this tree's own that a core is built from, with the includes,
/// defines and warnings those builds use: a finding fails the step. The
/// vendored libraries are not analyzed; their findings are theirs.
fn analyze(
    b: *std.Build,
    step: *std.Build.Step,
    sources: Sources,
) void {
    const extra = [_][]const u8{
        "entry.c", "startup_hook.c", "testing.c", "testing_checked.c",
    };
    for (core_sources ++ extra) |file| {
        // -S, not -c: `zig cc` would take the analyzer's report for an
        // object and try to link it; as assembly it is left alone.
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-S", "--analyze", "-Xanalyzer", "-analyzer-werror" });
        addSyntaxFlags(b, run, sources);
        run.addArg("-o");
        _ = run.addOutputFileArg2(b.fmt("{s}.analysis", .{file}), .{});
        // The tree's own file, so a finding names it: a file argument's
        // key is its path under the build root and its contents, the same
        // from every checkout, where a compile's is its absolute path.
        run.addFileArg2(b.path(b.fmt("core/{s}", .{file})), .{});
        step.dependOn(&run.step);
    }
    closureChecks(b, step, sources);
}

/// The flags the analyzer and the closure check read the tree's own C
/// with: the warnings, defines and include directories a core is built
/// with, but for the tree's own, which a file finds beside it.
fn addSyntaxFlags(b: *std.Build, run: *std.Build.Step.Run, sources: Sources) void {
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
    run.addDirectoryArg2(sources.config.mbedtls, .{ .prefix = "-I" });
    for (libraryIncludes(b, sources)) |dir| run.addDirectoryArg2(dir, .{ .prefix = "-I" });
}

/// Every C file of the tree a core, a check or a helper is built from.
const closure_checked = [_][]const u8{
    "core/entry.c",                       "core/startup_hook.c",
    "core/testing.c",                     "core/testing_checked.c",
    "core/coverage_map_empty.c",          "core/strnlen_test.c",
    "core/environment_test.c",            "test/portable/format_test.c",
    "test/portable/startup_hook.c",       "test/portable/launcher_payload.c",
    "test/portable/launcher_socket_fd.c",
};

/// What a copy of a C file holds ([`Own`]) against what the compiler
/// reads: `zig cc -MM` lists the headers of the tree a file includes, and
/// each must be in the copy's closure, or the file would compile from a
/// copy that lacks one -- an error where the header is missing, but a
/// stale object where another header of the same name is found. It runs
/// for the host's target and the other cores' (their `#if` branches keep
/// different includes) and the checked core's defines, over every C file a
/// core is built from.
fn closureChecks(b: *std.Build, step: *std.Build.Step, sources: Sources) void {
    const checker = b.addExecutable(.{
        .name = "closure-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/closure_check.zig"),
            .target = baselineHostTarget(b),
            .optimize = .debug,
        }),
    });
    const variants = [_]struct { name: []const u8, flags: []const []const u8 }{
        .{ .name = "host", .flags = &.{} },
        .{ .name = "aarch64-linux-musl", .flags = &.{ "-target", "aarch64-linux-musl" } },
        .{ .name = "aarch64-macos", .flags = &.{ "-target", "aarch64-macos" } },
        .{ .name = "checked", .flags = &.{ "-DCOSMIC_CHECKED", "-DLUAI_ASSERT", "-DLUA_USE_APICHECK" } },
    };
    var paths: std.ArrayList([]const u8) = .empty;
    for (core_sources) |name| paths.append(b.allocator, b.fmt("core/{s}", .{name})) catch @panic("OOM");
    paths.appendSlice(b.allocator, &closure_checked) catch @panic("OOM");
    for (variants) |variant| for (paths.items) |path| {
        const deps = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-MM" });
        deps.addArgs(variant.flags);
        addSyntaxFlags(b, deps, sources);
        // A file outside core/ finds core/'s headers as its copy does, by
        // the header beside it that includes them. Each path of the tree
        // is a lazy one, resolved where the tree is when the step runs: zig
        // reuses a configured graph from another checkout (its key holds no
        // build root), so a string naming the root would name that one.
        if (!std.mem.startsWith(u8, path, "core/")) deps.addDirectoryArg2(b.path("core"), .{ .prefix = "-I", .make_absolute = true });
        deps.addArg("-MF");
        const list = deps.addOutputFileArg2(b.fmt("{s}-{s}.d", .{ variant.name, std.fs.path.basename(path) }), .{});
        deps.addFileArg2(b.path(path), .{ .make_absolute = true });
        // The headers it reads are no input of this step, so it asks again
        // each run; the check below stands on the list.
        deps.has_side_effects = true;
        const check = b.addRunArtifact(checker);
        check.addFileArg2(b.path(path), .{ .make_absolute = true });
        check.addArg(path);
        check.addFileArg2(list, .{});
        check.addArgs(sources.own.closure(path).files);
        step.dependOn(&check.step);
    };
}

/// The configuration headers the vendored libraries read from core/, each
/// copied into a directory of its own in the zig cache, named by its
/// contents (see the head of `build`). A module's include directory is
/// part of every compile's flags, so a directory holding more than a
/// module needs moves that module's compiles when it changes.
const ConfigHeaders = struct {
    ares: std.Build.LazyPath,
    curl: std.Build.LazyPath,
    mbedtls: std.Build.LazyPath,
    xz: std.Build.LazyPath,
    darwin_compat: std.Build.LazyPath,
};

fn configHeaders(b: *std.Build) ConfigHeaders {
    return .{
        .ares = configFile(b, "core/ares_config.h"),
        .curl = configFile(b, "core/curl_config.h"),
        .mbedtls = configFile(b, "core/mbedtls_cosmic_config.h"),
        .xz = configFile(b, "core/xz_config/config.h"),
        .darwin_compat = darwinCompat(b).path(b, "darwin-compat"),
    };
}

/// A directory holding the tree's `path`, a header, by its basename.
fn configFile(b: *std.Build, path: []const u8) std.Build.LazyPath {
    const copies = b.addWriteFiles();
    _ = copies.addCopyFile(b.path(path), std.fs.path.basename(path));
    return copies.getDirectory();
}

fn darwinCompat(b: *std.Build) std.Build.LazyPath {
    const copies = b.addWriteFiles();
    _ = copies.addCopyDirectory(b.path("core/darwin-compat"), "darwin-compat", .{});
    return copies.getDirectory();
}

/// The vendored trees every core is built from.
const Sources = struct {
    /// The tree's own C, from its copies.
    own: *Own,
    lua: std.Build.LazyPath,
    sqlite: std.Build.LazyPath,
    miniz: std.Build.LazyPath,
    mbedtls: std.Build.LazyPath,
    bzip2: std.Build.LazyPath,
    xz: std.Build.LazyPath,
    cares: std.Build.LazyPath,
    curl: std.Build.LazyPath,
    yyjson: std.Build.LazyPath,
    /// The configuration headers the libraries read from core/, copied
    /// into the zig cache (see the head of `build`).
    config: ConfigHeaders,
};

/// A core that observes its own C: linked first with an empty block table
/// and its debug information, which [`core/coverage_map.zig`] reads to write
/// the table, then linked again carrying it. The table is indexed by block,
/// so it is only true of a second link holding the first's blocks in the
/// first's order; `checks` gains the step that holds it to that.
fn observedCore(
    b: *std.Build,
    mapper: *std.Build.Step.Compile,
    checks: *std.Build.Step,
    target_record: Target,
    configuration: Configuration,
    target: std.Build.ResolvedTarget,
    sources: Sources,
    vendor: []const *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const first = core(b, target_record, configuration, target, sources, vendor, false, .first_link);
    const write_map = b.addRunArtifact(mapper);
    write_map.addArg("write");
    write_map.addFileArg2(first.getEmittedBin(), .{});
    const map = write_map.addOutputFileArg2("coverage_map.c", .{});
    // Where each file the core observes was compiled from: a copy holds
    // the headers it includes.
    for (ownCoreFiles(b, configuration, false)) |path| {
        write_map.addDirectoryArg2(sources.own.root(path), .{});
    }
    const second = core(b, target_record, configuration, target, sources, vendor, false, .{ .map = map });
    const check_map = b.addRunArtifact(mapper);
    check_map.addArg("check");
    check_map.addFileArg2(first.getEmittedBin(), .{});
    check_map.addFileArg2(second.getEmittedBin(), .{});
    checks.dependOn(&check_map.step);
    return second;
}

/// One vendored library of a core, a static library of its own, appended
/// to `libraries`: the module its C is added to, with only the include
/// directories `includes` names, in order. An include directory is a flag
/// of every file of its module, and a configuration header's is named by
/// the header's contents, so a library that does not read a header is not
/// compiled again when it changes.
///
/// A library is a compile of its own rather than a module imported into
/// one compile: zig 0.17 keys a compilation by its root module's include
/// directories, not by those of the C-only modules it imports, so a
/// library imported as a module would not be compiled again when its
/// configuration header's directory moves.
fn vendorPart(
    b: *std.Build,
    libraries: *std.ArrayList(*std.Build.Step.Compile),
    configuration: Configuration,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    includes: []const std.Build.LazyPath,
) *std.Build.Module {
    const mod = b.createModule(.{
        .target = target,
        .optimize = coreOptimize(configuration),
        .link_libc = true,
        .strip = !configuration.sanitize,
        .sanitize_c = if (configuration.sanitize) .full else .off,
    });
    for (includes) |dir| mod.addIncludePath(dir);
    const lib = b.addLibrary(.{
        .name = b.fmt("cosmic-{s}", .{name}),
        .linkage = .static,
        .root_module = mod,
    });
    // See the core's own, at the end of `core`.
    lib.link_function_sections = true;
    lib.link_data_sections = true;
    libraries.append(b.allocator, lib) catch @panic("OOM");
    return mod;
}

/// The vendored libraries of one core, compiled once for a target and
/// configuration and linked by every core built from them: both links of
/// an observed core, and the test fixture's hooked core. They are never
/// instrumented, and never carry debug information even where the core's
/// own C does (a first link), so no core's build compiles them again.
/// Each is a library of its own ([`vendorPart`]), with the include
/// directories it reads: an edit to core/curl_config.h compiles curl
/// again, to core/ares_config.h c-ares, and to
/// core/mbedtls_cosmic_config.h mbedtls and curl, which reads its headers.
fn vendorLibraries(
    b: *std.Build,
    target_record: Target,
    configuration: Configuration,
    target: std.Build.ResolvedTarget,
    sources: Sources,
) []const *std.Build.Step.Compile {
    var libraries: std.ArrayList(*std.Build.Step.Compile) = .empty;
    const config = sources.config;
    const lua = sources.lua;
    const sqlite = sources.sqlite;
    const miniz = sources.miniz;
    const mbedtls = sources.mbedtls;
    const bzip2 = sources.bzip2;
    const xz = sources.xz;
    const cares = sources.cares;
    const curl = sources.curl;
    const yyjson = sources.yyjson;
    const crypto = mbedtls.path(b, "tf-psa-crypto");

    // The libraries' compiles run beside one another; the longest are
    // added first, so they are not the last to start: SQLite's
    // amalgamation is the longest single compile by far (over 20 s
    // released, 80 s under the checked core's sanitizer), then yyjson.
    //
    // SQLite's compile-time configuration, as flags rather than a
    // configuration header: a flag is part of the compile's cache key,
    // where a header pulled in through SQLITE_CUSTOM_INCLUDE was seen to
    // change without the object being rebuilt. The build is
    // single-threaded and the shipped database is read-only and opened
    // through our own VFS, so everything that exists for other shapes of
    // use is off. The `dbstat` virtual table is on: it is what every
    // table and index costs in pages and bytes, which `cosmic db`
    // reports. `fts5` is on: it backs the shipped catalog, which an
    // uncaught error and `cosmic docs` search, and costs ~222 KB per raw
    // core (three raw cores per portable artifact).
    const sqlite_flags: []const []const u8 = &.{
        "-std=c11",
        debug_dir,
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
    vendorPart(b, &libraries, configuration, target, "sqlite", &.{sqlite}).addCSourceFiles(.{
        .root = sqlite,
        .files = &.{"sqlite3.c"},
        .flags = sqlite_flags,
    });

    // yyjson reads JSON for cosmic.json, and writes each number's
    // shortest form for its encoder. What the core never calls is
    // compiled out: the incremental reader, file and FILE* I/O, and
    // JSON Pointer and Patch. The non-standard extensions stay, for
    // the JSON5 a caller asks for by name; every other read is RFC 8259.
    const yyjson_src = yyjson.path(b, "src");
    vendorPart(b, &libraries, configuration, target, "yyjson", &.{yyjson_src}).addCSourceFiles(.{
        .root = yyjson_src,
        .files = &.{"yyjson.c"},
        .flags = &.{
            "-std=c11",
            debug_dir,
            "-DYYJSON_DISABLE_INCR_READER=1",
            "-DYYJSON_DISABLE_FILE=1",
            "-DYYJSON_DISABLE_UTILS=1",
        },
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
    //
    // LUA_COMPAT_GLOBAL off: assigning to an undeclared global (no
    // `global` statement) is a compile error rather than silently
    // creating one, catching the classic Lua typo bug. The vendored
    // compiler and every Teal-generated chunk run unchanged under it --
    // neither ever assigns an undeclared global -- so there is nothing
    // to trade for the safety.
    const lua_base = [_][]const u8{ "-std=c11", debug_dir, "-DLUA_USE_POSIX", "-DLUA_COMPAT_GLOBAL=0" };
    const lua_checked = lua_base ++ lua_checks;
    const lua_flags: []const []const u8 =
        if (configuration.sanitize) &lua_checked else &lua_base;
    const lua_src = lua.path(b, "src");
    vendorPart(b, &libraries, configuration, target, "lua", &.{lua_src}).addCSourceFiles(.{
        .root = lua_src,
        .files = &lua_sources,
        .flags = lua_flags,
    });

    // miniz reaches for fseeko/ftello, which are POSIX rather than C11.
    // Its zlib-compatible aliases are off: the core calls the mz_ names,
    // and the aliases are static wrappers every including file warns on.
    vendorPart(b, &libraries, configuration, target, "miniz", &.{miniz}).addCSourceFiles(.{
        .root = miniz,
        .files = &.{"miniz.c"},
        .flags = &.{
            "-std=c11",
            debug_dir,
            "-D_XOPEN_SOURCE=700",
            "-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES",
        },
    });

    // bzip2's decompressor is a true push-streaming API (bz_stream's
    // next_in/avail_in/next_out), which is what the Compress.Stream
    // contract needs; BZ_NO_STDIO keeps its file-handle helpers, which
    // this core never calls, from pulling in FILE*. blocksort.c and
    // compress.c hold the compress-side symbols bzlib.c references even
    // though only BZ2_bzDecompress* is ever called here, so they are
    // compiled for the link to resolve; per-function sections (see the
    // end of this function) let the linker drop them again, since
    // nothing reachable calls BZ2_bzCompress. The K&R-flavored source predates
    // -Wall/-Wextra/-Werror by a wide margin, so it gets its own quiet
    // flag set rather than the core's.
    vendorPart(b, &libraries, configuration, target, "bzip2", &.{bzip2}).addCSourceFiles(.{
        .root = bzip2,
        .files = &.{
            "bzlib.c",   "blocksort.c", "compress.c",  "decompress.c",
            "huffman.c", "crctable.c",  "randtable.c",
        },
        .flags = &.{ "-std=c11", debug_dir, "-DBZ_NO_STDIO" },
    });

    // xz's liblzma, a decoder-only subset (LZMA1/LZMA2, the delta and
    // x86/arm64 BCJ filters, and the CRC-32/CRC-64/SHA-256 checks) --
    // see core/xz_config for why: the tree vendors no config.h of its
    // own, autoconf's usual job, so core/xz_config/config.h stands in
    // for it, on an include path of this library's alone.
    const xz_src = xz.path(b, "src");
    vendorPart(b, &libraries, configuration, target, "xz", &.{
        config.xz,
        xz_src.path(b, "common"),
        xz_src.path(b, "liblzma/api"),
        xz_src.path(b, "liblzma/common"),
        xz_src.path(b, "liblzma/check"),
        xz_src.path(b, "liblzma/lzma"),
        xz_src.path(b, "liblzma/lz"),
        xz_src.path(b, "liblzma/rangecoder"),
        xz_src.path(b, "liblzma/delta"),
        xz_src.path(b, "liblzma/simple"),
    }).addCSourceFiles(.{
        .root = xz_src,
        .files = &.{
            "liblzma/check/check.c",
            "liblzma/check/crc32_fast.c",
            "liblzma/check/crc64_fast.c",
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
            "-std=c11",            debug_dir,
            "-D_XOPEN_SOURCE=700", "-D_DEFAULT_SOURCE",
            "-DHAVE_CONFIG_H",
        },
    });

    // mbedtls: the PSA crypto subtree, then the TLS 1.2/1.3 client and
    // X.509 layer above it, all under the one configuration header (see
    // [`mbedtls_config`]). The crypto files below are the ones that hold
    // code under that configuration; every other one compiles to nothing.
    const mbedtls_flags = [_][]const u8{ "-std=c11", debug_dir } ++ mbedtls_config;
    const mbedtls_part = vendorPart(b, &libraries, configuration, target, "mbedtls", &(cryptoIncludes(b, crypto, &crypto_include_dirs) ++ [_]std.Build.LazyPath{
        mbedtls.path(b, "include"),
        mbedtls.path(b, "library"),
        config.mbedtls,
    }));
    mbedtls_part.addCSourceFiles(.{
        .root = crypto,
        .files = &.{
            "core/psa_crypto.c",
            "core/psa_crypto_client.c",
            "core/psa_crypto_driver_wrappers_no_static.c",
            "core/psa_crypto_slot_management.c",
            "core/psa_util.c",
            "platform/platform_util.c",
            "utilities/constant_time.c",
            // Digests, MACs, and the PSA cipher and AEAD drivers.
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
            "drivers/builtin/src/block_cipher.c",
            // Big-number and elliptic-curve arithmetic for ECDH, ECDSA
            // and RSA, and HMAC-DRBG (deterministic ECDSA's nonce
            // generator -- the only DRBG built, since everything else
            // draws randomness from the OS through
            // mbedtls_psa_external_get_random).
            "drivers/builtin/src/bignum.c",
            "drivers/builtin/src/bignum_core.c",
            "drivers/builtin/src/ecp.c",
            "drivers/builtin/src/ecp_curves.c",
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
    mbedtls_part.addCSourceFiles(.{
        .root = mbedtls.path(b, "library"),
        .files = &mbedtls_tls_sources,
        .flags = &mbedtls_flags,
    });

    // c-ares: DNS resolution for [`cosmic.http`], on every target --
    // including macOS, where the rule against dynamic loading (see
    // `lua_base`) gets its one deliberate carve-out.
    // Apple's DNS configuration is only fully readable through configd,
    // whose relevant symbols c-ares dlopens from libSystem itself
    // (ares_sysconfig_mac.c) rather than linking against; there is no
    // static alternative, so this is that one door left open, and only
    // on macOS. c-ares's own thread support (CARES_THREADS) is off: the
    // core drives one poll loop itself, matching [`cosmic.child`].
    const cares_flags = [_][]const u8{
        "-std=c11",          debug_dir,
        "-DHAVE_CONFIG_H",   "-D_GNU_SOURCE",
        "-D_DEFAULT_SOURCE",
    };
    const cares_part = vendorPart(b, &libraries, configuration, target, "cares", &.{
        cares.path(b, "include"),
        cares.path(b, "src/lib"),
        cares.path(b, "src/lib/include"),
        config.ares,
    });
    if (target_record.query.os_tag == .macos) cares_part.addIncludePath(config.darwin_compat);
    cares_part.addCSourceFiles(.{
        .root = cares.path(b, "src/lib"),
        .files = &cares_sources,
        .flags = &cares_flags,
    });

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
        "-std=c11",        debug_dir,
        "-DHAVE_CONFIG_H", "-DBUILDING_LIBCURL",
        "-D_GNU_SOURCE",   "-D_DEFAULT_SOURCE",
    } ++ mbedtls_config;
    vendorPart(b, &libraries, configuration, target, "curl", &(cryptoIncludes(b, crypto, &crypto_public_dirs) ++ [_]std.Build.LazyPath{
        mbedtls.path(b, "include"),
        cares.path(b, "include"),
        curl.path(b, "lib"),
        curl.path(b, "include"),
        config.curl,
        config.mbedtls,
    })).addCSourceFiles(.{
        .root = curl.path(b, "lib"),
        .files = &curl_sources,
        .flags = &curl_flags,
    });
    return libraries.items;
}

/// The include directories of the vendored libraries' public headers, which
/// the core's own C reads to call into them, in the order a name is looked
/// up. mbedtls's configuration header is not among them ([`core`]).
fn libraryIncludes(b: *std.Build, sources: Sources) [crypto_public_dirs.len + 9]std.Build.LazyPath {
    return [_]std.Build.LazyPath{
        sources.lua.path(b, "src"),
        sources.sqlite,
        sources.miniz,
        sources.yyjson.path(b, "src"),
        sources.bzip2,
        sources.xz.path(b, "src/liblzma/api"),
    } ++ cryptoIncludes(b, sources.mbedtls.path(b, "tf-psa-crypto"), &crypto_public_dirs) ++ [_]std.Build.LazyPath{
        sources.mbedtls.path(b, "include"),
        sources.cares.path(b, "include"),
        sources.curl.path(b, "include"),
    };
}

/// The tree's own C files a core compiles, in order, before its block
/// table: core_sources, the entry point, the startup hook -- the test
/// fixture's in a core built with `portable_startup_test_hooks` -- and
/// the test instruments, which the checked core alone carries (a failing
/// allocator, a count of the store's open statements), so no core that
/// ships has an allocator a program can make fail. (The raw namespace
/// calls those files add are in core_sources, every core's.)
fn ownCoreFiles(b: *std.Build, configuration: Configuration, portable_startup_test_hooks: bool) []const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (core_sources) |name| paths.append(b.allocator, b.fmt("core/{s}", .{name})) catch @panic("OOM");
    paths.appendSlice(b.allocator, &.{
        "core/entry.c",
        if (portable_startup_test_hooks) "test/portable/startup_hook.c" else "core/startup_hook.c",
        if (configuration.sanitize) "core/testing_checked.c" else "core/testing.c",
    }) catch @panic("OOM");
    return paths.items;
}

fn coreOptimize(configuration: Configuration) std.lang.Optimize {
    return if (configuration.sanitize) .safe else .fast;
}

fn core(
    b: *std.Build,
    target_record: Target,
    configuration: Configuration,
    target: std.Build.ResolvedTarget,
    sources: Sources,
    vendor: []const *std.Build.Step.Compile,
    portable_startup_test_hooks: bool,
    native_coverage: NativeCoverage,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = coreOptimize(configuration),
        .link_libc = true,
        // The release cores are stripped. The checked core keeps its debug
        // information; [`debug_dir`] and the map's `-g0` keep it naming no
        // path of the build, so it too is the same bytes at any path.
        // A first link keeps its debug information for the block map to
        // read; it is never installed.
        .strip = !configuration.sanitize and native_coverage != .first_link,
        .sanitize_c = if (configuration.sanitize) .full else .off,
    });
    for (libraryIncludes(b, sources)) |dir| mod.addIncludePath(dir);
    // mbedtls's headers name the library's configuration header, which is
    // not beside them. Only it: an edit to any other header of core/ is no
    // flag of this module, and moves no object it does not include.
    // TODO: give the header's directory only to the files that include
    // mbedtls's headers, in a module of their own, once zig keys a
    // compilation by the include directories of a C-only module it imports
    // (zig 0.17 keys only the root module's; see [`vendorPart`]): an edit
    // to the header compiles every file of the core again, where only
    // those read it.
    mod.addIncludePath(sources.config.mbedtls);
    // As archives, not `linkLibrary`, which would add each library's (empty)
    // tree of installed headers to the include path of every file here.
    for (vendor) |library| mod.addObjectFile(library.getEmittedBin());

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
    // COSMIC_CHECKED gives the checked core's own C its instruments:
    // core/memory.h's counted allocator and core/fault.h's fault points.
    // Every other core compiles both to the plain call they wrap.
    // Its sanitizer's reports name a file by its last two components,
    // `core/x.c`, rather than the copy it was compiled from ([`Own`]).
    const checked_flags = core_flags ++ lua_checks ++ [_][]const u8{
        "-DCOSMIC_CHECKED",
        "-fsanitize-undefined-strip-path-components=-2",
    };
    const checked_observed_flags = checked_flags ++ observed;
    const own_flags: []const []const u8 = switch (native_coverage) {
        .off => if (configuration.sanitize) &checked_flags else &core_flags,
        .first_link, .map => if (configuration.sanitize) &checked_observed_flags else &observed_flags,
    };
    sources.own.add(mod, ownCoreFiles(b, configuration, portable_startup_test_hooks), own_flags);

    mod.addCMacro("COSMIC_TARGET_ID", b.fmt("{d}", .{target_record.id}));
    mod.addCMacro("COSMIC_TARGET_NAME", b.fmt("\"{s}\"", .{target_record.name}));
    mod.addCMacro("COSMIC_CONFIGURATION_ID", b.fmt("{d}", .{configuration.id}));
    mod.addCMacro("COSMIC_CONFIGURATION_NAME", b.fmt("\"{s}\"", .{configuration.name}));

    mod.addCMacro("COSMIC_PORTABLE_REQUIRED_TARGET_MASK", b.fmt("UINT64_C({d})", .{requiredTargetMask()}));
    mod.addCMacro("COSMIC_PORTABLE_RELEASE_CONFIGURATION_ID", b.fmt("{d}", .{release_configuration.id}));
    // Last, and uninstrumented, so both links hold the same blocks in the
    // same order: the table is data and adds none.
    switch (native_coverage) {
        .off => {},
        .first_link => sources.own.add(mod, &.{"core/coverage_map_empty.c"}, &.{ "-std=c11", debug_dir }),
        // No debug information for the generated map: it is data, and its
        // file's name is its zig-cache output directory, new on every
        // relink, which would move the checked core's bytes with it.
        .map => |map| mod.addCSourceFile(.{ .file = map, .flags = &.{ "-std=c11", debug_dir, "-g0" } }),
    }

    const exe = b.addExecutable(.{
        .name = "cosmic-core",
        .root_module = mod,
    });
    // One section per function and per object, so the linker's garbage
    // collection (on by default in a release link) drops each unreachable
    // function rather than keeping a whole file's code for the one
    // function something calls: bzip2's compressor, the parts of curl,
    // mbedtls and SQLite this core never reaches. Mach-O links get the
    // same effect from subsections-via-symbols already.
    exe.link_function_sections = true;
    exe.link_data_sections = true;
    return exe;
}

fn hostName(b: *std.Build) []const u8 {
    return hostTarget(b).name;
}

/// The host's architecture, OS and ABI, with the baseline CPU and the
/// OS's and libc's default versions: nothing detected on the build machine.
/// `b.graph.host` includes CPU features detected there.
///
/// Every tool the build runs on the host is built for this target, not
/// `b.graph.host`: a tool's bytes are part of the cache key of every step
/// that runs it. Built for the detected CPU, a tool would miss a cache
/// restored from a runner on other hardware on every such step; built for
/// the detected kernel and glibc versions, it would miss after every runner
/// image update. No core is built for it: the checked core is built for the
/// host's shipped target ([`hostTarget`]).
fn baselineHostTarget(b: *std.Build) std.Build.ResolvedTarget {
    const host = b.graph.host.result;
    return baselineTarget(b, .{
        .cpu_arch = host.cpu.arch,
        .cpu_model = .baseline,
        .os_tag = host.os.tag,
        .abi = host.abi,
    });
}

/// `query` resolved, refusing a CPU other than its architecture's baseline:
/// a host tool's bytes key the build's cache, and the checked core runs on
/// runners other than the one that built it.
fn baselineTarget(b: *std.Build, query: std.Target.Query) std.Build.ResolvedTarget {
    const resolved = b.resolveTargetQuery(query);
    const expected = std.Target.Cpu.Model.baseline(
        resolved.result.cpu.arch,
        resolved.result.os,
    );
    if (resolved.result.cpu.model != expected)
        @panic("a host tool or the checked core resolved a CPU other than the baseline");
    return resolved;
}

fn hostTarget(b: *std.Build) Target {
    const host = b.graph.host.result;
    for (targets) |target| {
        // The shipped target this host runs: the one the bridge boots
        // with, and the one the checked core is built for. The host's ABI
        // is not matched: it names only the libc the build machine has
        // (gnu on a glibc runner, musl on Alpine, none on macOS), which no
        // core links, and every shipped Linux core is static musl, which
        // runs on either libc's host.
        if (target.query.os_tag == host.os.tag and
            target.query.cpu_arch == host.cpu.arch) return target;
    }
    @panic("unsupported build host");
}
