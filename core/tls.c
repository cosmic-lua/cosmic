#include "tls.h"

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>

#include "check.h"
#include "errnos.h"
#include "lauxlib.h"
#include "mbedtls/error.h"
#include "mbedtls/pk.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"

#define CONFIG_TYPE "cosmic.tls.config"
#define SESSION_TYPE "cosmic.tls.session"

/* The most protocols a configuration offers by ALPN, and the most
 * certificate and key pairs it holds. */
enum { alpn_most = 8, pairs_most = 64, name_most = 255 };

/* A certificate chain, leaf first, and the leaf's private key. */
struct pair {
  mbedtls_x509_crt chain;
  mbedtls_pk_context key;
};

/* A server's configuration: what every session made of it shares. Its
 * pairs are each initialized when it is made, so its __gc frees all of
 * them however far filling it got. A session holds its configuration
 * as its user value, so the configuration outlives every session of
 * it. */
struct config {
  mbedtls_ssl_config conf;
  int count;
  const char *alpn[alpn_most + 1];
  char alpn_bytes[alpn_most * (name_most + 1)];
  struct pair pair[];
};

/* A session over one accepted socket, whose descriptor it does not
 * own: the connection that holds it closes the socket, after `free`. */
struct session {
  mbedtls_ssl_context ssl;
  struct config *config;
  int fd;
  /* The errno a send or a receive last failed with, 0 for none. */
  int failure;
  bool live;
  /* The name the client asked for (SNI), as it sent it. */
  size_t name_size;
  char name[name_most];
};

/* Pushes `code`'s description, as "tls: <words> (-0xNNNN)". */
static void push_code (lua_State *L, const char *what, int code) {
  char words[160];
  mbedtls_strerror(code, words, sizeof words);
  lua_pushfstring(L, "tls: %s: %s (-0x%04X)", what, words,
                  (unsigned)(code < 0 ? -code : code));
}

/* nil and why, for a configuration that cannot be made. */
static int config_failed (lua_State *L, const char *what, int index,
                          int code) {
  char where[96];
  snprintf(where, sizeof where, "pair %d's %s", index, what);
  lua_pushnil(L);
  push_code(L, where, code);
  return 2;
}

static void config_free (struct config *c, int capacity) {
  for (int i = 0; i < capacity; i++) {
    mbedtls_x509_crt_free(&c->pair[i].chain);
    mbedtls_pk_free(&c->pair[i].key);
  }
  mbedtls_ssl_config_free(&c->conf);
}

/* __gc. A configuration is freed only by the collector: a session
 * holds it for as long as it lives. */
static int config_gc (lua_State *L) {
  struct config *c = luaL_checkudata(L, 1, CONFIG_TYPE);
  int capacity = c->count;
  c->count = 0;
  config_free(c, capacity);
  return 0;
}

/* Whether the DNS name `pattern`, from a certificate, covers `host`,
 * ignoring case: the same name, or `*.rest` for a host of one label
 * more than `rest` (RFC 6125 6.4.3, a wildcard only as the whole left
 * label). */
static bool covers (const unsigned char *pattern, size_t pattern_size,
                    const unsigned char *host, size_t host_size) {
  if (pattern_size >= 2 && pattern[0] == '*' && pattern[1] == '.') {
    const unsigned char *dot = memchr(host, '.', host_size);
    if (dot == NULL || dot == host) return false;
    size_t rest = host_size - (size_t)(dot - host);
    if (rest != pattern_size - 1) return false;
    host = dot;
    host_size = rest;
    pattern++;
    pattern_size--;
  }
  if (pattern_size != host_size) return false;
  for (size_t i = 0; i < host_size; i++) {
    unsigned char a = pattern[i];
    unsigned char b = host[i];
    if (a >= 'A' && a <= 'Z') a = (unsigned char)(a - 'A' + 'a');
    if (b >= 'A' && b <= 'Z') b = (unsigned char)(b - 'A' + 'a');
    if (a != b) return false;
  }
  return true;
}

/* Whether a DNS name of `crt`'s Subject Alternative Names covers
 * `host`. */
static bool names (const mbedtls_x509_crt *crt, const unsigned char *host,
                   size_t size) {
  for (const mbedtls_x509_sequence *san = &crt->subject_alt_names;
       san != NULL && san->buf.p != NULL; san = san->next) {
    if (san->buf.tag ==
            (MBEDTLS_ASN1_CONTEXT_SPECIFIC | MBEDTLS_X509_SAN_DNS_NAME) &&
        covers(san->buf.p, san->buf.len, host, size)) {
      return true;
    }
  }
  return false;
}

/* Whether `name` is made of the letters, digits, `-`, `_`, `.` and `*`
 * a host name or a pattern of one is. */
static bool plausible (const unsigned char *name, size_t size) {
  for (size_t i = 0; i < size; i++) {
    unsigned char c = name[i];
    bool fits = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' ||
                c == '*';
    if (!fits) return false;
  }
  return true;
}

/* mbedtls's certificate callback, after the ClientHello: keeps the name
 * the client asked for, and offers the pairs whose leaves name it, in
 * their order, so a name with an ECDSA and an RSA pair is served the
 * one the client takes. A client that asks for none, or for a name no
 * pair has, is offered every pair. mbedtls serves the first offered
 * whose key signs by an algorithm the client lists. */
static int chosen (mbedtls_ssl_context *ssl) {
  struct session *s = mbedtls_ssl_get_user_data_p(ssl);
  size_t size = 0;
  const unsigned char *host = mbedtls_ssl_get_hs_sni(ssl, &size);
  if (host == NULL || size == 0) return 0;
  /* Kept only where it could be a host name, so what a handler reads
   * of it holds no byte a client chose to mislead a log with. */
  if (size <= sizeof s->name && plausible(host, size)) {
    s->name_size = size;
    memcpy(s->name, host, size);
  }
  struct config *c = s->config;
  for (int i = 0; i < c->count; i++) {
    if (names(&c->pair[i].chain, host, size)) {
      int code = mbedtls_ssl_set_hs_own_cert(ssl, &c->pair[i].chain,
                                             &c->pair[i].key);
      if (code != 0) return code;
    }
  }
  return 0;
}

/* Reads pair `index` of the table at argument 1 into `p`: its `cert`,
 * a PEM chain with the leaf first, and its `key`, the leaf's private
 * key, PEM. 0, or the library's failure, with `*what` naming which. */
static int pair_read (lua_State *L, int index, struct pair *p,
                      const char **what) {
  if (lua_geti(L, 1, index) != LUA_TTABLE) {
    luaL_error(L, "tls: pair %d is not a table", index);
  }
  lua_getfield(L, -1, "cert");
  lua_getfield(L, -2, "key");
  size_t cert_size;
  size_t key_size;
  const char *cert = lua_tolstring(L, -2, &cert_size);
  const char *key = lua_tolstring(L, -1, &key_size);
  if (cert == NULL || key == NULL || lua_type(L, -2) != LUA_TSTRING ||
      lua_type(L, -1) != LUA_TSTRING) {
    luaL_error(L, "tls: pair %d needs a cert and a key, each a string",
               index);
  }
  /* PEM is parsed with its terminating NUL, which a Lua string has. */
  *what = "certificate";
  int code = mbedtls_x509_crt_parse(&p->chain, (const unsigned char *)cert,
                                    cert_size + 1);
  if (code > 0) code = MBEDTLS_ERR_X509_INVALID_FORMAT;
  if (code == 0) {
    *what = "key";
    code = mbedtls_pk_parse_key(&p->key, (const unsigned char *)key,
                                key_size + 1, NULL, 0);
  }
  if (code == 0) {
    *what = "key, which is not the certificate's";
    code = mbedtls_pk_check_pair(&p->chain.pk, &p->key);
  }
  lua_pop(L, 3);
  return code;
}

/* config(pairs, alpn?): a server configuration of `pairs`, each a table
 * of `cert` and `key`, PEM, offering the protocols of `alpn` by ALPN;
 * or nil and why, where a pair cannot be read or its key is not its
 * certificate's. TLS 1.2 and 1.3. */
static int tls_config (lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer count = luaL_len(L, 1);
  luaL_argcheck(L, count >= 1 && count <= pairs_most, 1,
                "one pair or more, and at most 64");
  int alpn_count = 0;
  if (!lua_isnoneornil(L, 2)) {
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_Integer listed = luaL_len(L, 2);
    luaL_argcheck(L, listed >= 0 && listed <= alpn_most, 2,
                  "at most 8 protocols");
    alpn_count = (int)listed;
  }
  struct config *c = lua_newuserdatauv(
      L, sizeof *c + (size_t)count * sizeof c->pair[0], 0);
  c->count = 0;
  mbedtls_ssl_config_init(&c->conf);
  for (int i = 0; i < (int)count; i++) {
    mbedtls_x509_crt_init(&c->pair[i].chain);
    mbedtls_pk_init(&c->pair[i].key);
  }
  c->count = (int)count;
  luaL_setmetatable(L, CONFIG_TYPE);
  char *bytes = c->alpn_bytes;
  for (int i = 0; i < alpn_count; i++) {
    lua_geti(L, 2, i + 1);
    size_t size;
    const char *name = lua_tolstring(L, -1, &size);
    if (name == NULL || lua_type(L, -1) != LUA_TSTRING || size == 0 ||
        size > name_most || memchr(name, '\0', size) != NULL) {
      luaL_error(L, "tls: ALPN protocol %d must be 1 to 255 bytes, no NUL",
                 i + 1);
    }
    memcpy(bytes, name, size);
    bytes[size] = '\0';
    c->alpn[i] = bytes;
    bytes += size + 1;
    lua_pop(L, 1);
  }
  c->alpn[alpn_count] = NULL;
  int code = mbedtls_ssl_config_defaults(&c->conf, MBEDTLS_SSL_IS_SERVER,
                                         MBEDTLS_SSL_TRANSPORT_STREAM,
                                         MBEDTLS_SSL_PRESET_DEFAULT);
  if (code != 0) {
    lua_pushnil(L);
    push_code(L, "configuring", code);
    return 2;
  }
  mbedtls_ssl_conf_min_tls_version(&c->conf, MBEDTLS_SSL_VERSION_TLS1_2);
  mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_NONE);
  mbedtls_ssl_conf_cert_cb(&c->conf, chosen);
  if (alpn_count > 0) {
    code = mbedtls_ssl_conf_alpn_protocols(&c->conf, c->alpn);
    if (code != 0) {
      lua_pushnil(L);
      push_code(L, "ALPN", code);
      return 2;
    }
  }
  for (int i = 0; i < c->count; i++) {
    const char *what = "";
    code = pair_read(L, i + 1, &c->pair[i], &what);
    if (code != 0) return config_failed(L, what, i + 1, code);
    code = mbedtls_ssl_conf_own_cert(&c->conf, &c->pair[i].chain,
                                     &c->pair[i].key);
    if (code != 0) return config_failed(L, "certificate", i + 1, code);
  }
  return 1;
}

/* The days from 1970-01-01 to the proleptic Gregorian `year`-`mon`-`day`
 * (Howard Hinnant's days_from_civil). */
static int64_t days_from_civil (int64_t year, int64_t mon, int64_t day) {
  year -= mon <= 2;
  int64_t era = (year >= 0 ? year : year - 399) / 400;
  int64_t yoe = year - era * 400;
  int64_t doy = (153 * (mon + (mon > 2 ? -3 : 9)) + 2) / 5 + day - 1;
  int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

static lua_Integer unix_seconds (const mbedtls_x509_time *t) {
  return (lua_Integer)(days_from_civil(t->year, t->mon, t->day) * 86400 +
                       t->hour * 3600 + t->min * 60 + t->sec);
}

/* leaf(pem): what the first certificate of the PEM chain `pem` says of
 * itself: `names`, the DNS names of its Subject Alternative Names, and
 * `not_before` and `not_after`, seconds since the epoch; or nil and why,
 * where it cannot be read. */
static int tls_leaf (lua_State *L) {
  size_t size;
  const char *pem = luaL_checklstring(L, 1, &size);
  lua_createtable(L, 0, 3);
  lua_createtable(L, 4, 0);
  /* Parsed after the pushes, which can raise; freed before any other. */
  mbedtls_x509_crt crt;
  mbedtls_x509_crt_init(&crt);
  int code = mbedtls_x509_crt_parse(&crt, (const unsigned char *)pem,
                                    size + 1);
  if (code > 0) code = MBEDTLS_ERR_X509_INVALID_FORMAT;
  if (code != 0) {
    mbedtls_x509_crt_free(&crt);
    lua_pushnil(L);
    push_code(L, "the certificate", code);
    return 2;
  }
  lua_Integer before = unix_seconds(&crt.valid_from);
  lua_Integer after = unix_seconds(&crt.valid_to);
  /* The names are copied out before any push: each push can raise. */
  enum { listed_most = 100 };
  char listed[listed_most][name_most + 1];
  int count = 0;
  for (const mbedtls_x509_sequence *san = &crt.subject_alt_names;
       san != NULL && san->buf.p != NULL && count < listed_most;
       san = san->next) {
    if (san->buf.tag ==
            (MBEDTLS_ASN1_CONTEXT_SPECIFIC | MBEDTLS_X509_SAN_DNS_NAME) &&
        san->buf.len > 0 && san->buf.len <= name_most) {
      memcpy(listed[count], san->buf.p, san->buf.len);
      listed[count][san->buf.len] = '\0';
      count++;
    }
  }
  mbedtls_x509_crt_free(&crt);
  for (int i = 0; i < count; i++) {
    lua_pushstring(L, listed[i]);
    lua_rawseti(L, -2, i + 1);
  }
  lua_setfield(L, -2, "names");
  lua_pushinteger(L, before);
  lua_setfield(L, -2, "not_before");
  lua_pushinteger(L, after);
  lua_setfield(L, -2, "not_after");
  return 1;
}

/* mbedtls's send, over the session's nonblocking socket. */
static int bio_send (void *context, const unsigned char *data,
                     size_t size) {
  struct session *s = context;
#if defined(MSG_NOSIGNAL)
  const int flags = MSG_NOSIGNAL;
#else
  /* Every socket of core/socket.c's has SO_NOSIGPIPE where there is no
   * MSG_NOSIGNAL. */
  const int flags = 0;
#endif
  ssize_t sent;
  do {
    sent = send(s->fd, data, size, flags);
  } while (sent < 0 && errno == EINTR);
  if (sent >= 0) return (int)sent;
  if (errno == EAGAIN || errno == EWOULDBLOCK) {
    return MBEDTLS_ERR_SSL_WANT_WRITE;
  }
  s->failure = errno;
  return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
}

/* mbedtls's receive, over the session's nonblocking socket: 0 at the
 * peer's end, which mbedtls reads as the connection's end. */
static int bio_recv (void *context, unsigned char *data, size_t size) {
  struct session *s = context;
  ssize_t got;
  do {
    got = recv(s->fd, data, size, 0);
  } while (got < 0 && errno == EINTR);
  if (got >= 0) return (int)got;
  if (errno == EAGAIN || errno == EWOULDBLOCK) {
    return MBEDTLS_ERR_SSL_WANT_READ;
  }
  s->failure = errno;
  return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
}

/* The session at argument 1, its last call's errno forgotten, so a
 * failure is described by what failed in this call. */
static struct session *checked_session (lua_State *L) {
  struct session *s = luaL_checkudata(L, 1, SESSION_TYPE);
  if (!s->live) {
    luaL_error(L, "tls: the session is freed"); /* throws: a use after free
                                                   is a bug, not a runtime
                                                   failure */
  }
  s->failure = 0;
  return s;
}

/* What a call that did not finish answers in its third value. */
enum { stop_failed = 0, stop_read = 1, stop_write = 2, stop_ended = 3 };

/* `first` (nil or false), why, and what stopped the call, of the
 * session's `code`: stop_read or stop_write where it waits for the
 * socket, why "", stop_ended at the peer's end, why "", or stop_failed
 * and why. */
static int unfinished (lua_State *L, struct session *s, int code,
                       bool effect) {
  if (effect) {
    lua_pushboolean(L, 0);
  } else {
    lua_pushnil(L);
  }
  int stop = stop_failed;
  switch (code) {
    case MBEDTLS_ERR_SSL_WANT_READ:
    stop = stop_read;
    break;
    case MBEDTLS_ERR_SSL_WANT_WRITE:
    stop = stop_write;
    break;
    case MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY:
    case MBEDTLS_ERR_SSL_CONN_EOF:
    stop = stop_ended;
    break;
    default:
    break;
  }
  if (stop != stop_failed) {
    lua_pushliteral(L, "");
  } else if (s->failure != 0) {
    int failure = s->failure;
    s->failure = 0;
    lua_pushfstring(L, "tls: %s", cosmic_errno_describe(failure, NULL));
  } else {
    push_code(L, "the session", code);
  }
  lua_pushinteger(L, stop);
  return 3;
}

/* session(config, fd): a server session of `config` over the accepted
 * socket `fd`, which it does not own. Nil and why where the library
 * cannot set one up. */
static int tls_session (lua_State *L) {
  struct config *c = luaL_checkudata(L, 1, CONFIG_TYPE);
  int fd = cosmic_checkfd(L, 2);
  struct session *s = lua_newuserdatauv(L, sizeof *s, 1);
  mbedtls_ssl_init(&s->ssl);
  s->config = c;
  s->fd = fd;
  s->failure = 0;
  s->live = true;
  s->name_size = 0;
  luaL_setmetatable(L, SESSION_TYPE);
  lua_pushvalue(L, 1);
  lua_setiuservalue(L, -2, 1);
  int code = mbedtls_ssl_setup(&s->ssl, &c->conf);
  if (code != 0) {
    lua_pushnil(L);
    push_code(L, "setting up a session", code);
    return 2;
  }
  mbedtls_ssl_set_user_data_p(&s->ssl, s);
  mbedtls_ssl_set_bio(&s->ssl, s, bio_send, bio_recv, NULL);
  return 1;
}

/* handshake(): true once the handshake is done; false, why and what
 * stopped it otherwise, as `unfinished` says. */
static int session_handshake (lua_State *L) {
  struct session *s = checked_session(L);
  int code = mbedtls_ssl_handshake(&s->ssl);
  if (code != 0) return unfinished(L, s, code, true);
  lua_pushboolean(L, 1);
  return 1;
}

/* read(max): at most `max` bytes of what the peer sent, at most a
 * record's 16 KiB, handshaking first where that is not done; nil and
 * what `handshake` says otherwise. */
static int session_read (lua_State *L) {
  struct session *s = checked_session(L);
  lua_Integer max = luaL_checkinteger(L, 2);
  luaL_argcheck(L, max >= 1, 2, "must be positive");
  unsigned char data[16384];
  size_t want = max < (lua_Integer)sizeof data ? (size_t)max : sizeof data;
  int got = mbedtls_ssl_read(&s->ssl, data, want);
  if (got <= 0) return unfinished(L, s, got, false);
  lua_pushlstring(L, (const char *)data, (size_t)got);
  return 1;
}

/* write(data, from): how many bytes of `data` from `from` the session
 * took, handshaking first where that is not done; nil and what
 * `handshake` says otherwise. One that waited must be called again
 * with the same bytes. */
static int session_write (lua_State *L) {
  struct session *s = checked_session(L);
  size_t size;
  const char *data = luaL_checklstring(L, 2, &size);
  lua_Integer from = luaL_checkinteger(L, 3);
  luaL_argcheck(L, from >= 1 && (lua_Unsigned)from - 1 < size, 3,
                "out of range");
  int took = mbedtls_ssl_write(&s->ssl,
                               (const unsigned char *)data + (from - 1),
                               size - (size_t)(from - 1));
  if (took < 0) return unfinished(L, s, took, false);
  lua_pushinteger(L, took);
  return 1;
}

/* close_notify(): true once the alert that ends the session is sent;
 * false and what `handshake` says otherwise. */
static int session_close_notify (lua_State *L) {
  struct session *s = checked_session(L);
  int code = mbedtls_ssl_close_notify(&s->ssl);
  if (code != 0) return unfinished(L, s, code, true);
  lua_pushboolean(L, 1);
  return 1;
}

/* info(): the version the handshake settled on ("TLSv1.3"), the
 * protocol ALPN chose, and the name the client asked for, the last two
 * nil where there is none. */
static int session_info (lua_State *L) {
  struct session *s = checked_session(L);
  lua_createtable(L, 0, 3);
  lua_pushstring(L, mbedtls_ssl_get_version(&s->ssl));
  lua_setfield(L, -2, "version");
  const char *alpn = mbedtls_ssl_get_alpn_protocol(&s->ssl);
  if (alpn != NULL) {
    lua_pushstring(L, alpn);
    lua_setfield(L, -2, "alpn");
  }
  if (s->name_size > 0) {
    lua_pushlstring(L, s->name, s->name_size);
    lua_setfield(L, -2, "server_name");
  }
  return 1;
}

static void session_release (struct session *s) {
  if (s->live) {
    s->live = false;
    mbedtls_ssl_free(&s->ssl);
  }
}

/* free(), __close and __gc: frees the session, once. Its socket is the
 * caller's. */
static int session_free (lua_State *L) {
  session_release(luaL_checkudata(L, 1, SESSION_TYPE));
  return 0;
}

static const luaL_Reg session_methods[] = {
  {"handshake", session_handshake},
  {"read", session_read},
  {"write", session_write},
  {"close_notify", session_close_notify},
  {"info", session_info},
  {"free", session_free},
  {NULL, NULL},
};

static const luaL_Reg module[] = {
  {"config", tls_config},
  {"session", tls_session},
  {"leaf", tls_leaf},
  {NULL, NULL},
};

int cosmic_open_tls (lua_State *L) {
  luaL_newmetatable(L, CONFIG_TYPE);
  lua_pushcfunction(L, config_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  luaL_newmetatable(L, SESSION_TYPE);
  lua_pushcfunction(L, session_free);
  lua_setfield(L, -2, "__gc");
  lua_pushcfunction(L, session_free);
  lua_setfield(L, -2, "__close");
  lua_newtable(L);
  luaL_setfuncs(L, session_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newlib(L, module);
  lua_pushinteger(L, stop_failed);
  lua_setfield(L, -2, "FAILED");
  lua_pushinteger(L, stop_read);
  lua_setfield(L, -2, "READ");
  lua_pushinteger(L, stop_write);
  lua_setfield(L, -2, "WRITE");
  lua_pushinteger(L, stop_ended);
  lua_setfield(L, -2, "ENDED");
  return 1;
}
