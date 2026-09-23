/*
 * A minimal stand-in for the SystemConfiguration framework header zig's
 * macOS sysroot does not ship (it has no framework headers at all, only
 * the libc/libSystem ones AvailabilityMacros.h needs). This is the
 * carve-out AGENTS.md's build.zig comment on "dynamic loading is never
 * wanted" now names: c-ares's ares_sysconfig_mac.c dlopens libSystem
 * itself to reach configd's DNS configuration, the same way it would if
 * linked against the real framework, and only needs two flag constants
 * out of the whole header to do it.
 *
 * Values are ABI, not API: both are long-stable bits of
 * SCNetworkReachabilityFlags from Apple's public
 * SCNetworkReachability.h, unchanged since Mac OS X 10.3.
 */
#ifndef COSMIC_DARWIN_COMPAT_SCNETWORKCONFIGURATION_H
#define COSMIC_DARWIN_COMPAT_SCNETWORKCONFIGURATION_H

typedef unsigned int SCNetworkReachabilityFlags;

/* kSCNetworkReachabilityFlagsReachable, aliased under its older name. */
#define kSCNetworkFlagsReachable ((SCNetworkReachabilityFlags)1 << 1)
/* kSCNetworkReachabilityFlagsConnectionOnTraffic */
#define kSCNetworkReachabilityFlagsConnectionOnTraffic \
  ((SCNetworkReachabilityFlags)1 << 3)

#endif /* COSMIC_DARWIN_COMPAT_SCNETWORKCONFIGURATION_H */
