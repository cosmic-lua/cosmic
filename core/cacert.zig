//! The Mozilla CA bundle (vendor/cacert/cacert.pem) as the two symbols
//! `core/cacert.h` declares. build.zig hands the file to this object as
//! the import "cacert.pem", so the file is an input of the compile like
//! any source: editing or refetching it rebuilds this object and nothing
//! else.
//!
//! PEM rather than DER: the core passes these bytes, with any
//! $SSL_CERT_FILE appended, as CURLOPT_CAINFO_BLOB, and curl's mbedtls
//! backend hands that blob to mbedtls_x509_crt_parse, which reads a
//! sequence of PEM certificates but only a single DER one.

const pem = @embedFile("cacert.pem");

/// The bundle's bytes; not NUL-terminated.
export const cosmic_cacert_pem: [pem.len]u8 = pem.*;

/// Its length in bytes.
export const cosmic_cacert_pem_len: usize = pem.len;
