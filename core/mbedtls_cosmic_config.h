/*
 * mbedtls's compile-time configuration -- the one configuration every
 * translation unit that includes an mbedtls or PSA header sees: the
 * crypto subtree, the TLS/X.509 layer, curl's mbedtls backend and the
 * core's own C alike. build.zig names this file as both
 * TF_PSA_CRYPTO_CONFIG_FILE and MBEDTLS_CONFIG_FILE and passes no other
 * mbedtls macro, so no file can be compiled against a different idea of
 * the library's structs than the library itself was: an option that
 * changes a struct's layout (renegotiation state, session tickets, the
 * PSA operation unions) is decided here once. tf-psa-crypto's
 * build_info.h reads it first; mbedtls's build_info.h then names it
 * again, and the include guard makes that a no-op. The library's own
 * default configuration, tf-psa-crypto/include/psa/crypto_config.h, is
 * not vendored (vendor/mbedtls/PIN drops it): three of curl's files
 * included it directly (patch/curl removes those lines), and a file
 * that tries again fails to compile rather than silently layering the
 * defaults over this configuration.
 *
 * Digests and HMAC through the PSA API, plus what a TLS 1.2/1.3 client
 * needs -- ECDHE key agreement, ECDSA and RSA (PKCS#1 v1.5 and PSS)
 * signature verification, AES-GCM and ChaCha20-Poly1305 record
 * protection, the TLS 1.2 PRF and TLS 1.3 HKDF key schedules -- with
 * randomness from the OS (crypto.c's mbedtls_psa_external_get_random)
 * rather than the library's own entropy and DRBG modules.
 *
 * Most of the classic MBEDTLS_xxx_C module flags (ECP_C, RSA_C,
 * BIGNUM_C, ASN1_PARSE_C, AES_C, GCM_C, CHACHA20_C, ...) are derived
 * from the PSA_WANT flags by crypto_adjust_config_enable_builtins.h;
 * naming them here as well would only redefine them.
 */
#ifndef COSMIC_MBEDTLS_CONFIG_H
#define COSMIC_MBEDTLS_CONFIG_H

/* PSA core, randomness from the OS. */
#define MBEDTLS_PSA_CRYPTO_C
#define MBEDTLS_PSA_CRYPTO_EXTERNAL_RNG
#define MBEDTLS_PSA_ASSUME_EXCLUSIVE_BUFFERS

/* Digests and HMAC (cosmic.hash, cosmic.crypto). */
#define PSA_WANT_ALG_MD5 1
#define PSA_WANT_ALG_SHA_1 1
#define PSA_WANT_ALG_SHA_224 1
#define PSA_WANT_ALG_SHA_256 1
#define PSA_WANT_ALG_SHA_384 1
#define PSA_WANT_ALG_SHA_512 1
#define PSA_WANT_ALG_SHA3_224 1
#define PSA_WANT_ALG_SHA3_256 1
#define PSA_WANT_ALG_SHA3_384 1
#define PSA_WANT_ALG_SHA3_512 1
#define PSA_WANT_ALG_HMAC 1
#define PSA_WANT_KEY_TYPE_HMAC 1

/* Key agreement and signature verification for the ECDHE_ECDSA and
 * ECDHE_RSA cipher suites and TLS 1.3. */
#define PSA_WANT_ALG_ECDH 1
#define PSA_WANT_ALG_ECDSA 1
#define PSA_WANT_ALG_DETERMINISTIC_ECDSA 1
#define PSA_WANT_ALG_RSA_PKCS1V15_SIGN 1
#define PSA_WANT_ALG_RSA_PSS 1
#define PSA_WANT_KEY_TYPE_ECC_KEY_PAIR_IMPORT 1
#define PSA_WANT_KEY_TYPE_ECC_KEY_PAIR_EXPORT 1
#define PSA_WANT_KEY_TYPE_ECC_KEY_PAIR_GENERATE 1
#define PSA_WANT_KEY_TYPE_ECC_KEY_PAIR_BASIC 1
#define PSA_WANT_KEY_TYPE_ECC_PUBLIC_KEY 1
#define PSA_WANT_ECC_SECP_R1_256 1
#define PSA_WANT_ECC_SECP_R1_384 1
#define PSA_WANT_ECC_SECP_R1_521 1
#define PSA_WANT_ECC_MONTGOMERY_255 1
#define PSA_WANT_KEY_TYPE_RSA_KEY_PAIR_IMPORT 1
#define PSA_WANT_KEY_TYPE_RSA_PUBLIC_KEY 1

/* Record protection: AES-GCM and ChaCha20-Poly1305. */
#define PSA_WANT_ALG_GCM 1
#define PSA_WANT_ALG_CHACHA20_POLY1305 1
#define PSA_WANT_KEY_TYPE_AES 1
#define PSA_WANT_KEY_TYPE_CHACHA20 1

/* Key schedules: TLS 1.2's PRF and TLS 1.3's HKDF. */
#define PSA_WANT_ALG_HKDF 1
#define PSA_WANT_ALG_HKDF_EXTRACT 1
#define PSA_WANT_ALG_HKDF_EXPAND 1
#define PSA_WANT_ALG_TLS12_PRF 1
#define PSA_WANT_ALG_TLS12_PSK_TO_MS 1

/* Hardware and assembly paths. AES-NI (x86_64) and the Armv8 crypto
 * extension (aarch64) are each picked at run time from what the CPU
 * reports, falling back to the portable C tables; the file for the
 * other architecture compiles to nothing. MBEDTLS_HAVE_ASM also enables
 * bignum's inline multiply-accumulate, and ECP_NIST_OPTIM the fast
 * reduction modulo the NIST primes. None of this depends on the build
 * machine, so two builds still produce the same bytes. */
#define MBEDTLS_HAVE_ASM
#define MBEDTLS_AESNI_C
#define MBEDTLS_AESCE_C
#define MBEDTLS_ECP_NIST_OPTIM

/* Wall-clock time: MBEDTLS_HAVE_TIME_DATE gates mbedtls_x509_time_gmtime()
 * and the BADCERT_EXPIRED/BADCERT_FUTURE checks in x509_crt.c -- without
 * it an expired or not-yet-valid certificate verifies as trusted. */
#define MBEDTLS_HAVE_TIME
#define MBEDTLS_HAVE_TIME_DATE

/* The TLS 1.2/1.3 client. */
#define MBEDTLS_SSL_TLS_C
#define MBEDTLS_SSL_CLI_C
#define MBEDTLS_SSL_PROTO_TLS1_2
#define MBEDTLS_SSL_PROTO_TLS1_3
#define MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECDHE_ECDSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECDHE_RSA_ENABLED
/* SNI: a plain HTTP client is always talking to a virtual-hosted
 * server. ALPN: see patch/curl -- some TLS-terminating proxies refuse a
 * ClientHello without it. */
#define MBEDTLS_SSL_SERVER_NAME_INDICATION
#define MBEDTLS_SSL_ALPN
/* RFC 7627: binds the TLS 1.2 master secret to the handshake, closing
 * the triple-handshake attack. Servers that do not offer it still
 * connect. */
#define MBEDTLS_SSL_EXTENDED_MASTER_SECRET
/* TLS 1.3's middlebox compatibility mode (RFC 8446 D.4): looks like a
 * TLS 1.2 session resumption on the wire, which some middleboxes and
 * proxies need to let the handshake through. */
#define MBEDTLS_SSL_TLS1_3_COMPATIBILITY_MODE
/* TLS 1.3 forbids rsa_pkcs1_* in CertificateVerify; an RSA leaf needs
 * rsa_pss_rsae_* offered, which mbedtls gates on this rather than on
 * PSA_WANT_ALG_RSA_PSS. Without it a TLS 1.3 handshake with any
 * RSA-keyed server fails with handshake_failure. */
#define MBEDTLS_X509_RSASSA_PSS_SUPPORT
/* Left out on purpose: renegotiation (a server's HelloRequest is
 * answered with a no_renegotiation alert), session tickets (no
 * ticket-based resumption; a TLS 1.3 NewSessionTicket is read and
 * ignored), file-system loading of CA/CRL/key files (the trust store
 * reaches curl as CURLOPT_CAINFO_BLOB), CRLs, and everything that
 * writes keys or certificates -- which also leaves out curl's
 * public-key pinning, the one reader of mbedtls_pk_write_pubkey_der.
 * curl's mbedtls backend guards each of those on the matching macro and
 * reports the option that needs one as not built in
 * (CURLE_NOT_BUILT_IN) rather than ignoring it. */

/* X.509 chain verification and the encoding layers under it. */
#define MBEDTLS_X509_USE_C
#define MBEDTLS_X509_CRT_PARSE_C
#define MBEDTLS_PK_C
#define MBEDTLS_PK_PARSE_C
#define MBEDTLS_OID_C
#define MBEDTLS_PEM_PARSE_C
#define MBEDTLS_BASE64_C
#define MBEDTLS_ERROR_C
#define MBEDTLS_VERSION_C
/* The TLS 1.3 client checks CertificateVerify against the peer
 * certificate it kept in the session; ssl_tls13_generic.c does not
 * compile without it. */
#define MBEDTLS_SSL_KEEP_PEER_CERTIFICATE

#endif /* COSMIC_MBEDTLS_CONFIG_H */
