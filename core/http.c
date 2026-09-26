/* An HTTP/HTTPS client over curl easy handles, all driven by one curl
 * multi handle per process -- see cosmic/http.tl for the typed API this
 * backs and the doc comment there for the shape callers see. Sharing
 * the multi handle shares its connection pool, DNS cache and TLS
 * session cache, so a second request to the same host reuses the first
 * one's connection.
 *
 * Lua never runs inside a curl callback: the callbacks only copy bytes
 * into plain C buffers and return plain integers, exactly like
 * core/sqlite.c's callbacks touch no Lua state either. Every call back
 * into curl happens from `open` or `read`, between bytecode
 * instructions, so a `luaL_error` there unwinds ordinary Lua frames
 * only.
 *
 * `open` drives the transfer until the final response's headers are
 * known, and a response's headers are final once curl hands over the
 * first byte of its body or the whole transfer is over: curl delivers
 * no body for a 1xx or for a redirect it follows itself, so neither
 * ever looks final. The status and headers are then read from curl
 * (CURLINFO_RESPONSE_CODE, and the header API's last request) rather
 * than parsed here. Nothing drives the transfer further until `read`
 * does; the write callback bounds what one drive can buffer by pausing
 * the transfer once more than ~1 MiB is unread, and `read` resumes it
 * once the buffer drains below that. */

#include "http.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <curl/curl.h>

#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>

#include "fail.h"
#include "fault.h"
#include "memory.h"
#include "observed.h"
#include "store.h"

#define HANDLE_TYPE "cosmic.http.handle"

/* Above this many buffered, unread body bytes, the write callback
 * pauses the transfer instead of growing the buffer further. */
#define BODY_PAUSE_THRESHOLD (1024 * 1024)

/* The defaults `open` applies unless its options say otherwise: give up
 * on a connection not made within 30 s, and on a transfer that moves
 * less than 1 byte/s for 60 s straight. */
#define DEFAULT_CONNECT_TIMEOUT_MS 30000
#define DEFAULT_LOW_SPEED_BYTES 1
#define DEFAULT_LOW_SPEED_SECONDS 60

/* The largest values curl takes as given rather than clamps: it caps
 * CURLOPT_MAXREDIRS at 0x7fff and CURLOPT_LOW_SPEED_TIME at USHRT_MAX
 * without a word, so `open` refuses anything above them instead. */
#define MAX_REDIRECTS 0x7fff
#define MAX_LOW_SPEED_SECONDS USHRT_MAX

/* One scripted connection's far end (-1 until curl opens it, and again
 * once curl closes its own), its canned reply, and how much of that
 * is written. */
struct scripted {
  int fd;
  char *reply;
  size_t reply_len;
  size_t written;
};

/* The test-only transport `opts.script` asks for: each connection curl
 * opens is one end of a fresh socketpair, whose other end replays the
 * next canned reply and records whatever curl sends. Every live script
 * is on one list, since driving any transfer drives them all. */
struct script {
  struct script *next;
  struct script **prev_next;
  struct scripted *conns;
  size_t count;
  size_t opened;
  char *sent;
  size_t sent_len;
  size_t sent_cap;
  int sent_lost; /* recording what curl sent ran out of memory */
};

struct transfer {
  CURL *easy;
  struct curl_slist *request_headers;
  struct curl_slist *connect_to;
  struct script *script;
  char errbuf[CURL_ERROR_SIZE];

  char *body;
  size_t body_len;
  size_t body_cap;

  int ready;  /* the final response's headers are known, or it is over */
  int headed; /* the final response's header block has ended */
  int follow; /* curl follows a redirect's Location itself */
  int paused; /* the write callback paused the transfer */
  int done;   /* curl_multi says the transfer is over */
  int closed; /* close() (or __gc) has run */
  CURLcode result;
};

/* ---- once per process ------------------------------------------ */

static int curl_ready;
static CURLM *shared_multi;
static struct script *live_scripts;
/* What a failure the carried roots may cause says after it: how to
 * trust more, and how this binary, or a program built with it, gets
 * newer ones -- from a file when the stale roots cannot reach curl.se. */
#define STALE_ROOTS \
  "the CA roots this binary carries may not include this peer's: " \
  "$SSL_CERT_FILE names more to trust, and `cosmic refresh cacert " \
  "--binary <this program> -o <copy>` writes a copy with newer ones " \
  "(`--cacert <pem>` reads them from a file)"

/* The trust store: every CA root the binary's own database carries
 * (`ca_roots`, which build/roots.tl fills from Mozilla's bundle), plus
 * the certificates in $SSL_CERT_FILE when it names a readable file --
 * which is how a TLS-intercepting proxy's own CA gets trusted. Parsed
 * once and kept for the life of the process: `use_roots` hands it to
 * every TLS connection, a proxy's included. */
static mbedtls_x509_crt roots;

static int roots_ready;

/* Adds the certificates in $SSL_CERT_FILE, when it names a readable
 * file, to `roots`. A certificate there that does not parse is left
 * out, trusted no more than one missing. False only when there was no
 * memory to read the file into. */
/* TODO: open with O_CLOEXEC ("rbe", or open(2) and fdopen where a libc
 * lacks "e"), so a child started meanwhile inherits no descriptor. */
static bool add_cert_file (void) {
  const char *path = getenv("SSL_CERT_FILE");
  FILE *f = path != NULL && path[0] != '\0' ? fopen(path, "rb") : NULL;
  if (f == NULL) return true;
  bool ok = true;
  if (fseek(f, 0, SEEK_END) == 0) {
    long size = ftell(f);
    if (size > 0 && fseek(f, 0, SEEK_SET) == 0) {
      /* NUL-terminated: mbedtls reads PEM only from such a buffer, its
       * length counting the NUL. */
      unsigned char *text = cosmic_malloc((size_t)size + 1);
      if (text == NULL) {
        ok = false;
      } else {
        size_t got = fread(text, 1, (size_t)size, f);
        text[got] = '\0';
        (void)mbedtls_x509_crt_parse(&roots, text, got + 1);
        cosmic_free(text);
      }
    }
  }
  fclose(f);
  return ok;
}

/* Fills `roots` from the `ca_roots` rows of the database attached to the
 * running binary: the last one the store searches, as it trusts for the
 * standard library, so a project's database never adds a root. Returns
 * NULL, or why not, leaving `roots` empty: a binary with no roots
 * refuses every request, plain http too, rather than trusting some
 * other set -- one whose own database is missing or holds none is
 * broken, and says so at its first request. */
static const char *load_roots (lua_State *L) {
  int count = cosmic_store_count(L);
  sqlite3 *db = count > 0 ? cosmic_store_database(L, count) : NULL;
  if (db == NULL) return "no CA roots: this binary carries no database";
  sqlite3_stmt *stmt = NULL;
  if (sqlite3_prepare_v2(db, "SELECT der FROM main.ca_roots", -1, &stmt,
                         NULL) != SQLITE_OK) {
    sqlite3_finalize(stmt);
    return "no CA roots: the binary's database has no ca_roots table";
  }
  mbedtls_x509_crt_init(&roots);
  const char *trouble = NULL;
  int trusted = 0;
  int rc = SQLITE_DONE;
  while (trouble == NULL && (rc = sqlite3_step(stmt)) == SQLITE_ROW) {
    const unsigned char *der = sqlite3_column_blob(stmt, 0);
    int len = sqlite3_column_bytes(stmt, 0);
    if (der == NULL || len <= 0) continue;
    /* TODO: tell an allocation failure inside mbedtls from a certificate
     * it cannot read -- some come back as X509_INVALID_EXTENSIONS plus
     * ASN1_ALLOC_FAILED, or a PSA error -- and refuse on the first, once
     * mbedtls allocates through core/memory.h so core/allocation_test.tl
     * can walk it; today such a failure drops that one root for the life
     * of the process. add_cert_file's parse has the same gap. */
    int parsed = mbedtls_x509_crt_parse_der(&roots, der, (size_t)len);
    if (parsed == 0) {
      trusted++;
    } else if (parsed == MBEDTLS_ERR_X509_ALLOC_FAILED) {
      trouble = "no memory for the CA roots";
    }
  }
  if (trouble == NULL && rc != SQLITE_DONE) {
    trouble = "no CA roots: reading the binary's database failed";
  }
  sqlite3_finalize(stmt);
  if (trouble == NULL && trusted == 0) {
    trouble = "no CA roots: the binary's database holds none; `cosmic refresh cacert "
      "--binary <this program> -o <copy>` writes a copy that has them";
  }
  if (trouble == NULL && !add_cert_file()) {
    trouble = "no memory for $SSL_CERT_FILE";
  }
  if (trouble != NULL) {
    mbedtls_x509_crt_free(&roots);
    return trouble;
  }
  roots_ready = 1;
  return NULL;
}

/* The CURLOPT_SSL_CTX_FUNCTION of every transfer: curl's mbedtls backend
 * calls it with the configuration of each TLS connection it sets up,
 * the origin's or a proxy's, after its own set up and before the
 * handshake; the chain given here is the one the peer is verified
 * against. */
static CURLcode use_roots (CURL *easy, void *config, void *data) {
  (void)easy;
  (void)data;
  /* No CRL: curl's own is empty, as cosmic sets no CURLOPT_CRLFILE; one
   * that did would have to be passed here too. */
  mbedtls_ssl_conf_ca_chain(config, &roots, NULL);
  return CURLE_OK;
}

/* Initializes curl, the trust store and the shared multi handle, the
 * first time any request needs them. Returns NULL, or why not. Each
 * piece is made once: a later call after a failure picks up where the
 * last one stopped, so nothing made is leaked or made twice. */
static const char *http_ready (lua_State *L) {
  if (shared_multi != NULL) return NULL;
  if (!curl_ready) {
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
      return "curl_global_init failed";
    }
    curl_ready = 1;
  }
  if (!roots_ready) {
    const char *trouble = load_roots(L);
    if (trouble != NULL) return trouble;
  }
  shared_multi = COSMIC_FAULT("curl_multi_init") ? NULL : curl_multi_init();
  if (shared_multi == NULL) return "curl_multi_init failed";
  return NULL;
}

/* ---- request validation ------------------------------------------ */

/* Refuses anything that could smuggle a second header (or a request
 * line) past curl, or send other than what was given: a name or value
 * carrying CR or LF, or a NUL, which would end the C string curl reads
 * early and silently drop the rest; a name containing ':' (which would
 * fold into the value on the wire); or an empty name. Returns NULL if
 * `name`/`value` are fine to send as-is, or a static description of
 * why not. */
static const char *header_problem (const char *name, size_t name_len,
                                   const char *value, size_t value_len) {
  if (name_len == 0) return "a header name must not be empty";
  for (size_t i = 0; i < name_len; i++) {
    if (name[i] == '\r' || name[i] == '\n') {
      return "a header name must not contain CR or LF";
    }
    if (name[i] == '\0') return "a header name must not contain a NUL byte";
    if (name[i] == ':') return "a header name must not contain ':'";
  }
  for (size_t i = 0; i < value_len; i++) {
    if (value[i] == '\r' || value[i] == '\n') {
      return "a header value must not contain CR or LF";
    }
    if (value[i] == '\0') return "a header value must not contain a NUL byte";
  }
  return NULL;
}

/* True when `method` is an HTTP token (RFC 9110 5.6.2), so it cannot
 * carry a space or line break into the request line -- nor a NUL, which
 * would cut the C string curl reads short. */
static int is_token (const char *method, size_t len) {
  if (len == 0) return 0;
  for (size_t i = 0; i < len; i++) {
    char c = method[i];
    if (c == '\0' || (!isalnum((unsigned char)c) &&
                      strchr("!#$%&'*+-.^_`|~", c) == NULL)) {
      return 0;
    }
  }
  return 1;
}

/* ---- option helpers: the options table is always at index 2 ------- */

/* An option of the wrong shape -- a wrong Lua type, a non-integer, a
 * value out of range -- is a bug in the caller, so it raises, naming the
 * option; a value of the right shape that cannot be sent (a CR in a
 * header, a method that is no token, a bad URL) is data, which `open`
 * returns as `nil, err`. */
_Noreturn static void bad_option (lua_State *L, const char *key,
                                  const char *want) {
  luaL_argerror(L, 2, lua_pushfstring(L, "opts.%s must be %s", key, want));
  abort(); /* luaL_argerror never returns */
}

/* Pushes opts[key] and returns it, or NULL when it is nil; anything but
 * a string raises. The value stays on the stack, which is what keeps
 * the returned pointer valid for the rest of `open`. */
static const char *opt_string (lua_State *L, const char *key, size_t *len) {
  lua_getfield(L, 2, key);
  *len = 0;
  if (lua_isnil(L, -1)) return NULL;
  if (lua_type(L, -1) != LUA_TSTRING) bad_option(L, key, "a string");
  return lua_tolstring(L, -1, len);
}

/* Pushes opts[key], which must be nil or a table. */
static int opt_table (lua_State *L, const char *key) {
  lua_getfield(L, 2, key);
  if (lua_isnil(L, -1)) return 0;
  if (lua_type(L, -1) != LUA_TTABLE) bad_option(L, key, "a table");
  return 1;
}

/* opts[key] as a long in [0, max], or `fallback` when it is nil. Only a
 * number with an integer value will do: a string is not coerced, and a
 * negative or oversized value raises rather than reaching curl, which
 * would refuse or clamp it without a word. */
static long opt_integer (lua_State *L, const char *key, long fallback,
                         lua_Integer max) {
  lua_getfield(L, 2, key);
  lua_Integer v = fallback;
  if (!lua_isnil(L, -1)) {
    int ok = 0;
    if (lua_type(L, -1) == LUA_TNUMBER) v = lua_tointegerx(L, -1, &ok);
    if (!ok) bad_option(L, key, "an integer");
    if (v < 0 || v > max) {
      luaL_argerror(L, 2,
                    lua_pushfstring(L, "opts.%s must be between 0 and %I",
                                    key, max));
    }
  }
  lua_pop(L, 1);
  return (long)v;
}

static int opt_boolean (lua_State *L, const char *key, int fallback) {
  lua_getfield(L, 2, key);
  int v = fallback;
  if (!lua_isnil(L, -1)) {
    if (!lua_isboolean(L, -1)) bad_option(L, key, "a boolean");
    v = lua_toboolean(L, -1);
  }
  lua_pop(L, 1);
  return v;
}

/* ---- the scripted transport (tests only) ------------------------- */

/* Records bytes curl sent. Once memory runs out the record has a hole
 * in it, so it stops there and `sent` raises rather than return it. */
static void sent_append (struct script *s, const char *bytes, size_t len) {
  if (s->sent_lost) return;
  if (s->sent_len + len > s->sent_cap) {
    size_t want = s->sent_cap == 0 ? 4096 : s->sent_cap * 2;
    while (want < s->sent_len + len) want *= 2;
    char *grown = cosmic_realloc(s->sent, want);
    if (grown == NULL) {
      s->sent_lost = 1;
      return;
    }
    s->sent = grown;
    s->sent_cap = want;
  }
  memcpy(s->sent + s->sent_len, bytes, len);
  s->sent_len += len;
}

/* Moves bytes both ways on every far end without blocking: records
 * what curl sent, writes as much of the canned reply as fits, and
 * shuts the far end for writing once the whole reply is out, which is
 * how curl sees the server end the response. */
static void script_step (struct script *s) {
  for (size_t i = 0; i < s->opened; i++) {
    struct scripted *c = &s->conns[i];
    if (c->fd < 0) continue;
    char buf[65536];
    ssize_t got;
    while ((got = recv(c->fd, buf, sizeof buf, 0)) > 0) {
      sent_append(s, buf, (size_t)got);
    }
    int curl_closed = got == 0;
    while (!curl_closed && c->written < c->reply_len) {
#ifdef MSG_NOSIGNAL
      ssize_t put = send(c->fd, c->reply + c->written,
                         c->reply_len - c->written, MSG_NOSIGNAL);
#else
      ssize_t put = send(c->fd, c->reply + c->written,
                         c->reply_len - c->written, 0);
#endif
      if (put < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
      if (put < 0) {
        curl_closed = 1;
        break;
      }
      c->written += (size_t)put;
      if (c->written == c->reply_len) shutdown(c->fd, SHUT_WR);
    }
    if (curl_closed) {
      close(c->fd);
      c->fd = -1;
    }
  }
}

/* The CURLOPT_OPENSOCKETFUNCTION of a scripted transfer: hands curl one
 * end of a new socketpair and keeps the other as the next connection's
 * far end, or fails the connection once every canned reply is used. */
static curl_socket_t script_socket (void *clientp, curlsocktype purpose,
                                    struct curl_sockaddr *address) {
  (void)purpose;
  (void)address;
  struct script *s = clientp;
  int fds[2];
  if (s->opened == s->count ||
      socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
    return CURL_SOCKET_BAD;
  }
  fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK);
  fcntl(fds[0], F_SETFD, FD_CLOEXEC);
  fcntl(fds[1], F_SETFD, FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
  int on = 1;
  setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#endif
  struct scripted *c = &s->conns[s->opened++];
  c->fd = fds[1];
  if (c->reply_len == 0) shutdown(c->fd, SHUT_WR);
  return fds[0];
}

/* A socketpair is born connected; this tells curl not to connect it. */
static int script_sockopt (void *clientp, curl_socket_t fd,
                           curlsocktype purpose) {
  (void)clientp;
  (void)fd;
  (void)purpose;
  return CURL_SOCKOPT_ALREADY_CONNECTED;
}

static void script_free (struct script *s);

/* Raises unless opts.script, on the stack top, is a list of strings. */
static void script_check (lua_State *L) {
  lua_Unsigned count = lua_rawlen(L, -1);
  for (lua_Unsigned i = 1; i <= count; i++) {
    int type = lua_rawgeti(L, -1, (lua_Integer)i);
    lua_pop(L, 1);
    if (type != LUA_TSTRING) bad_option(L, "script", "a list of strings");
  }
}

/* Copies opts.script, a list of canned replies script_check passed, off
 * the stack top. Returns NULL when memory runs out. */
static struct script *script_new (lua_State *L) {
  size_t count = (size_t)lua_rawlen(L, -1);
  struct script *s = cosmic_calloc(1, sizeof *s);
  if (s == NULL) return NULL;
  s->conns = cosmic_calloc(count > 0 ? count : 1, sizeof *s->conns);
  if (s->conns == NULL) {
    cosmic_free(s);
    return NULL;
  }
  s->count = count;
  for (size_t i = 0; i < count; i++) s->conns[i].fd = -1;
  s->next = live_scripts;
  s->prev_next = &live_scripts;
  if (live_scripts != NULL) live_scripts->prev_next = &s->next;
  live_scripts = s;
  for (size_t i = 0; i < count; i++) {
    lua_rawgeti(L, -1, (lua_Integer)i + 1);
    size_t len = 0;
    const char *reply = lua_tolstring(L, -1, &len);
    struct scripted *c = &s->conns[i];
    c->reply = cosmic_malloc(len > 0 ? len : 1);
    if (c->reply != NULL) {
      memcpy(c->reply, reply, len);
      c->reply_len = len;
    }
    lua_pop(L, 1);
    if (c->reply == NULL) {
      script_free(s);
      return NULL;
    }
  }
  return s;
}

static void script_free (struct script *s) {
  *s->prev_next = s->next;
  if (s->next != NULL) s->next->prev_next = s->prev_next;
  for (size_t i = 0; i < s->count; i++) {
    if (s->conns[i].fd >= 0) close(s->conns[i].fd);
    cosmic_free(s->conns[i].reply);
  }
  cosmic_free(s->conns);
  cosmic_free(s->sent);
  cosmic_free(s);
}

/* ---- curl callbacks ---------------------------------------------- */

static size_t write_cb (char *ptr, size_t size, size_t nmemb, void *userdata) {
  struct transfer *t = userdata;
  size_t len = size * nmemb;
  if (t->body_len >= BODY_PAUSE_THRESHOLD) {
    t->paused = 1;
    return CURL_WRITEFUNC_PAUSE;
  }
  if (t->body_len + len > t->body_cap) {
    size_t want = t->body_cap == 0 ? 16384 : t->body_cap * 2;
    while (want < t->body_len + len) want *= 2;
    char *grown = cosmic_realloc(t->body, want);
    if (grown == NULL) return 0; /* signals an error to curl */
    t->body = grown;
    t->body_cap = want;
  }
  memcpy(t->body + t->body_len, ptr, len);
  t->body_len += len;
  t->ready = 1;
  return len;
}

/* Marks the transfer ready at the blank line ending the final
 * response's header block: not an interim 1xx one, and not a redirect
 * curl is about to follow (a 3xx carrying a Location, with follow on).
 * `open` returns there, so a body that is slow to start, or never
 * comes, is the business of `read`, not of `open`. */
static size_t header_cb (char *ptr, size_t size, size_t nmemb, void *userdata) {
  struct transfer *t = userdata;
  size_t len = size * nmemb;
  int blank = (len == 2 && ptr[0] == '\r' && ptr[1] == '\n') ||
              (len == 1 && ptr[0] == '\n');
  if (t->ready || !blank) {
    return len;
  }
  long status = 0;
  curl_easy_getinfo(t->easy, CURLINFO_RESPONSE_CODE, &status);
  if (status >= 100 && status < 200) return len;
  if (t->follow && status >= 300 && status < 400) {
    struct curl_header *location = NULL;
    if (curl_easy_header(t->easy, "Location", 0, CURLH_HEADER, -1,
                         &location) == CURLHE_OK &&
        location->value[0] != '\0') {
      return len;
    }
  }
  t->headed = 1;
  t->ready = 1;
  return len;
}

/* ---- the pump: one wait-and-perform step ------------------------- */

/* Waits (at most a second) for any transfer on the shared multi handle
 * to have something to do, then does it. Since every transfer shares
 * the handle, driving one drives them all; whichever finishes is marked
 * done through its CURLINFO_PRIVATE pointer. Returns CURLM_OK, or the
 * multi handle's own failure, which no amount of waiting would mend,
 * with the call that failed in `*which`. */
static CURLMcode pump_once (const char **which) {
  struct curl_waitfd extra[16];
  unsigned extra_count = 0;
  for (struct script *s = live_scripts; s != NULL; s = s->next) {
    for (size_t i = 0; i < s->opened && extra_count < 16; i++) {
      struct scripted *c = &s->conns[i];
      if (c->fd < 0) continue;
      extra[extra_count].fd = c->fd;
      extra[extra_count].events =
          CURL_WAIT_POLLIN |
          (c->written < c->reply_len ? CURL_WAIT_POLLOUT : 0);
      extra[extra_count].revents = 0;
      extra_count++;
    }
  }
  int numfds = 0;
  CURLMcode mc = COSMIC_FAULT("curl_multi_poll")
                      ? CURLM_UNRECOVERABLE_POLL
                      : curl_multi_poll(shared_multi, extra, extra_count, 1000,
                                        &numfds);
  if (mc != CURLM_OK) {
    *which = "curl_multi_poll";
    return mc;
  }
  for (struct script *s = live_scripts; s != NULL; s = s->next) {
    script_step(s);
  }

  int running = 0;
  mc = COSMIC_FAULT("curl_multi_perform")
           ? CURLM_OUT_OF_MEMORY
           : curl_multi_perform(shared_multi, &running);
  if (mc != CURLM_OK) {
    *which = "curl_multi_perform";
    return mc;
  }
  int msgs_left = 0;
  CURLMsg *msg;
  while ((msg = curl_multi_info_read(shared_multi, &msgs_left)) != NULL) {
    if (msg->msg != CURLMSG_DONE) continue;
    struct transfer *finished = NULL;
    curl_easy_getinfo(msg->easy_handle, CURLINFO_PRIVATE, &finished);
    if (finished != NULL) {
      finished->done = 1;
      finished->ready = 1;
      finished->result = msg->data.result;
    }
  }
  return CURLM_OK;
}

/* Undoes the write callback's pause. Clearing the flag first matters:
 * curl may call the write callback, which may pause again, from inside
 * curl_easy_pause. */
static void resume (struct transfer *t) {
  if (!t->paused || t->easy == NULL) return;
  t->paused = 0;
  curl_easy_pause(t->easy, CURLPAUSE_CONT);
}

/* curl's own message, without the newline it sometimes ends with.
 * TODO: a transport failure's message still carries libc's words for
 * its errno -- curl's "Recv failure: %s" and the like format it with
 * strerror_r (vendor/curl/lib/curlx/strerr.c) -- so it differs between
 * Linux and macOS; route curlx_strerror through core/errnos.h with a
 * patch record under patch/curl/ to make it the same on both. */
static const char *transfer_error (struct transfer *t) {
  if (t->errbuf[0] == '\0') return curl_easy_strerror(t->result);
  size_t end = strlen(t->errbuf);
  while (end > 0 && isspace((unsigned char)t->errbuf[end - 1])) {
    t->errbuf[--end] = '\0';
  }
  return t->errbuf;
}

/* Pushes `t`'s failure: curl's message, and for a peer whose chain
 * leads to no root this binary carries, how to get newer ones. Only
 * that flag is the roots' doing -- a name that does not match, or an
 * expired certificate, is the peer's -- and curl's mbedtls backend
 * says which flags were set only in its message, as mbedtls's
 * `mbedtls_x509_crt_verify_info` words them.
 * TODO: read the verify flags rather than their wording, once a record
 * under patch/curl/ has vendor/curl/lib/vtls/mbedtls.c's mbed_verify_cb
 * keep them where CURLINFO_SSL_VERIFYRESULT answers: that callback words
 * them into 128 bytes, so a chain that is also expired and misnamed
 * cuts the untrusted line short, and no hint is given. */
static void push_transfer_error (lua_State *L, struct transfer *t) {
  const char *message = transfer_error(t);
  if (t->result == CURLE_PEER_FAILED_VERIFICATION &&
      strstr(message, "certificate is not correctly signed by the trusted CA") != NULL) {
    lua_pushfstring(L, "%s; %s", message, STALE_ROOTS);
  } else {
    lua_pushstring(L, message);
  }
}

/* ---- teardown ------------------------------------------------------ */

#ifdef COSMIC_CHECKED
lua_Integer cosmic_http_live_transfers;
#endif

/* Releases everything `t` holds, once; `open` counts a transfer live
 * from the moment its userdata is made, so each is counted out here. */
static void transfer_release (struct transfer *t) {
#ifdef COSMIC_CHECKED
  if (!t->closed) cosmic_http_live_transfers--;
#endif
  if (t->easy != NULL) {
    curl_multi_remove_handle(shared_multi, t->easy);
    curl_easy_cleanup(t->easy);
    t->easy = NULL;
  }
  curl_slist_free_all(t->request_headers);
  t->request_headers = NULL;
  curl_slist_free_all(t->connect_to);
  t->connect_to = NULL;
  if (t->script != NULL) {
    script_free(t->script);
    t->script = NULL;
  }
  cosmic_free(t->body);
  t->body = NULL;
  t->body_cap = 0;
  t->body_len = 0;
  t->closed = 1;
}

/* ---- Lua-facing functions ------------------------------------------ */

static struct transfer *checked (lua_State *L) {
  struct transfer *t = luaL_checkudata(L, 1, HANDLE_TYPE);
  if (t->closed) {
    luaL_error(L, "the response is closed"); /* throws: use after close is
                                                a bug, as in core/sqlite.c */
  }
  return t;
}

static int handle_status (lua_State *L) {
  struct transfer *t = checked(L);
  long status = 0;
  curl_easy_getinfo(t->easy, CURLINFO_RESPONSE_CODE, &status);
  lua_pushinteger(L, status);
  return 1;
}

static int handle_url (lua_State *L) {
  struct transfer *t = checked(L);
  const char *url = NULL;
  curl_easy_getinfo(t->easy, CURLINFO_EFFECTIVE_URL, &url);
  lua_pushstring(L, url != NULL ? url : "");
  return 1;
}

/* The final response's headers, by lowercased name. A name the response
 * repeats gets its values joined with ", ", as RFC 9110 5.3 allows --
 * except Set-Cookie, whose values may themselves hold commas, which are
 * joined with "\n" instead, a byte no header value can contain. */
static int handle_headers (lua_State *L) {
  struct transfer *t = checked(L);
  lua_newtable(L);
  struct curl_header *h = NULL;
  while ((h = curl_easy_nextheader(t->easy, CURLH_HEADER, -1, h)) != NULL) {
    luaL_Buffer name;
    luaL_buffinit(L, &name);
    for (const char *p = h->name; *p != '\0'; p++) {
      luaL_addchar(&name, (char)tolower((unsigned char)*p));
    }
    luaL_pushresult(&name);
    lua_pushvalue(L, -1);
    if (lua_rawget(L, -3) == LUA_TNIL) {
      lua_pop(L, 1);
      lua_pushstring(L, h->value);
    } else {
      lua_pushstring(L, strcmp(lua_tostring(L, -2), "set-cookie") == 0
                            ? "\n" : ", ");
      lua_pushstring(L, h->value);
      lua_concat(L, 3);
    }
    lua_rawset(L, -3);
  }
  return 1;
}

static int failed (lua_State *L, const char *why) {
  lua_pushnil(L);
  lua_pushstring(L, why);
  return 2;
}

/* `nil, err` for the multi handle's refusal, naming the call. A macro
 * rather than a function: nothing a test does on a release core makes
 * a multi call fail, and every function of a core is one a test must
 * enter (build/c_functions.tl). */
#define MULTI_FAILED(L, which, mc) \
  failed((L), lua_pushfstring((L), "%s: %s", (which), curl_multi_strerror(mc)))

static int handle_read (lua_State *L) {
  struct transfer *t = checked(L);
  lua_Integer max = luaL_optinteger(L, 2, 65536);
  luaL_argcheck(L, max > 0, 2, "must be positive");

  if (t->body_len == 0) {
    resume(t);
    while (t->body_len == 0 && !t->done) {
      const char *which = NULL;
      CURLMcode mc = pump_once(&which);
      if (mc != CURLM_OK) return MULTI_FAILED(L, which, mc);
    }
    if (t->body_len == 0) {
      lua_pushnil(L);
      if (t->result != CURLE_OK) {
        push_transfer_error(L, t);
      } else {
        lua_pushliteral(L, ""); /* clean end of body */
      }
      return 2;
    }
  }

  size_t n = (size_t)max < t->body_len ? (size_t)max : t->body_len;
  lua_pushlstring(L, t->body, n);
  memmove(t->body, t->body + n, t->body_len - n);
  t->body_len -= n;
  if (t->body_len < BODY_PAUSE_THRESHOLD) resume(t);
  return cosmic_succeeded(L);
}

/* What curl has written to a scripted transfer's connections so far,
 * all of them in order; "" for a transfer over the network. */
static int handle_sent (lua_State *L) {
  struct transfer *t = checked(L);
  if (t->script == NULL) {
    lua_pushliteral(L, "");
    return 1;
  }
  script_step(t->script);
  if (t->script->sent_lost) {
    luaL_error(L, "no memory to record what curl sent");
  }
  lua_pushlstring(L, t->script->sent != NULL ? t->script->sent : "",
                  t->script->sent_len);
  return 1;
}

/* `close`, and both __gc and __close: a handle closed any way, even one
 * a finalizer elsewhere revives, is `closed`, and its methods raise. */
static int handle_close (lua_State *L) {
  struct transfer *t = luaL_checkudata(L, 1, HANDLE_TYPE);
  transfer_release(t);
  return 0;
}

/* One `open`'s settings, read and checked before anything is made. */
struct request {
  const char *url;
  const char *method; /* NULL: GET, or POST when there is a body */
  const char *body;   /* NULL: none */
  size_t body_len;
  int follow;
  int verbose;
  long max_redirects;
  long connect_timeout_ms;
  long timeout_ms;
  long low_speed_bytes;
  long low_speed_seconds;
};

/* Sets one option on `easy`, or returns curl's refusal from the
 * enclosing function with the option's name in `*which`. */
#define SET(option, value)                                           \
  do {                                                               \
    CURLcode set_rc_ = COSMIC_FAULT("curl_easy_setopt(" #option ")") \
                           ? CURLE_OUT_OF_MEMORY                     \
                           : curl_easy_setopt(easy, option, value);  \
    if (set_rc_ != CURLE_OK) {                                       \
      *which = #option;                                              \
      return set_rc_;                                                \
    }                                                                \
  } while (0)

/* Sets the request's method and body. GET, HEAD and POST use curl's
 * own options for them, so a redirect curl follows changes the method
 * exactly as RFC 9110 says (a 303, or a 301/302 after POST, becomes a
 * GET); any other method is sent as a custom one, still with the body. */
static CURLcode set_method (CURL *easy, const struct request *r,
                            const char **which) {
  const char *method = r->method;
  if (method != NULL && strcmp(method, "HEAD") == 0) {
    SET(CURLOPT_NOBODY, 1L);
    return CURLE_OK;
  }
  if (r->body != NULL) {
    SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)r->body_len);
    SET(CURLOPT_POSTFIELDS, r->body);
  } else if (method != NULL && strcmp(method, "POST") == 0) {
    SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)0);
    SET(CURLOPT_POSTFIELDS, "");
  }
  if (method != NULL && strcmp(method, "GET") != 0 &&
      strcmp(method, "POST") != 0) {
    SET(CURLOPT_CUSTOMREQUEST, method);
  }
  return CURLE_OK;
}

/* Every option but the headers and the script. */
static CURLcode configure (struct transfer *t, const struct request *r,
                           const char **which) {
  CURL *easy = t->easy;
  SET(CURLOPT_PRIVATE, (void *)t);
  SET(CURLOPT_URL, r->url);
  SET(CURLOPT_PROTOCOLS_STR, "http,https");
  SET(CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
  SET(CURLOPT_NOSIGNAL, 1L);
  SET(CURLOPT_FOLLOWLOCATION, r->follow ? CURLFOLLOW_OBEYCODE : 0L);
  SET(CURLOPT_MAXREDIRS, r->max_redirects);
  SET(CURLOPT_WRITEFUNCTION, write_cb);
  SET(CURLOPT_WRITEDATA, (void *)t);
  SET(CURLOPT_HEADERFUNCTION, header_cb);
  SET(CURLOPT_HEADERDATA, (void *)t);
  /* A proxy's CONNECT reply is not the response: keep it from the
   * header callback, which would otherwise take it for the final one. */
  SET(CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
  SET(CURLOPT_ERRORBUFFER, t->errbuf);
  SET(CURLOPT_CONNECTTIMEOUT_MS, r->connect_timeout_ms);
  SET(CURLOPT_TIMEOUT_MS, r->timeout_ms);
  SET(CURLOPT_LOW_SPEED_LIMIT, r->low_speed_bytes);
  SET(CURLOPT_LOW_SPEED_TIME, r->low_speed_seconds);
  SET(CURLOPT_VERBOSE, r->verbose ? 1L : 0L);
  SET(CURLOPT_SSL_CTX_FUNCTION, use_roots);
  return set_method(easy, r, which);
}

/* Routes every connection through the script instead of the network. */
static CURLcode configure_script (struct transfer *t, const char **which) {
  CURL *easy = t->easy;
  SET(CURLOPT_OPENSOCKETFUNCTION, script_socket);
  SET(CURLOPT_OPENSOCKETDATA, (void *)t->script);
  SET(CURLOPT_SOCKOPTFUNCTION, script_sockopt);
  SET(CURLOPT_CONNECT_TO, t->connect_to);
  SET(CURLOPT_PROXY, "");
  /* https too: the reply is then the server's side of the handshake,
   * which is how a test sees a certificate verified by `use_roots`. */
  SET(CURLOPT_PROTOCOLS_STR, "http,https");
  SET(CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
  SET(CURLOPT_FRESH_CONNECT, 1L);
  SET(CURLOPT_FORBID_REUSE, 1L);
  return CURLE_OK;
}

#undef SET

/* Releases `t` and returns `nil, err` for an option curl refused. Never
 * inlined, so the test that has curl refuse an option enters this one
 * copy. */
__attribute__((noinline)) static int setopt_failed (lua_State *L, struct transfer *t, const char *which,
                          CURLcode rc) {
  transfer_release(t);
  lua_pushnil(L);
  lua_pushfstring(L, "curl_easy_setopt(%s): %s", which,
                  curl_easy_strerror(rc));
  return 2;
}

/* Raises unless the headers table on the stack top maps strings to
 * strings: the shape check, which comes before any data check. */
static void headers_check (lua_State *L) {
  lua_pushnil(L);
  while (lua_next(L, -2) != 0) {
    if (lua_type(L, -2) != LUA_TSTRING || lua_type(L, -1) != LUA_TSTRING) {
      bad_option(L, "headers", "a table mapping strings to strings");
    }
    lua_pop(L, 1);
  }
}

/* Pushes why a header in the table on the stack top cannot be sent and
 * returns 1, or returns 0 when every one can. */
static int headers_problem (lua_State *L) {
  lua_pushnil(L);
  while (lua_next(L, -2) != 0) {
    size_t name_len, value_len;
    const char *name = lua_tolstring(L, -2, &name_len);
    const char *value = lua_tolstring(L, -1, &value_len);
    const char *problem = header_problem(name, name_len, value, value_len);
    lua_pop(L, 1);
    if (problem != NULL) {
      /* the key, NULs and all, goes into the message */
      lua_pushliteral(L, "invalid header ");
      lua_insert(L, -2);
      lua_pushliteral(L, ": ");
      lua_pushstring(L, problem);
      lua_concat(L, 4);
      return 1;
    }
  }
  return 0;
}

/* Appends each header in the table on the stack top to the request's
 * list as a "Name: value" line. Returns NULL, or why not when memory
 * runs out. */
static const char *headers_build (lua_State *L, struct transfer *t) {
  lua_pushnil(L);
  while (lua_next(L, -2) != 0) {
    size_t name_len, value_len;
    const char *name = lua_tolstring(L, -2, &name_len);
    const char *value = lua_tolstring(L, -1, &value_len);
    char *line = cosmic_malloc(name_len + 2 + value_len + 1);
    struct curl_slist *more = NULL;
    const char *why = "no memory for the request headers";
    if (line != NULL) {
      memcpy(line, name, name_len);
      memcpy(line + name_len, ": ", 2);
      memcpy(line + name_len + 2, value, value_len);
      line[name_len + 2 + value_len] = '\0';
      more = COSMIC_FAULT("curl_slist_append")
                 ? NULL
                 : curl_slist_append(t->request_headers, line);
      why = "curl_slist_append failed for the request headers";
      cosmic_free(line);
    }
    lua_pop(L, 1);
    if (more == NULL) {
      lua_pop(L, 1);
      return why;
    }
    t->request_headers = more;
  }
  return NULL;
}

static int http_open (lua_State *L) {
  struct request r;
  memset(&r, 0, sizeof r);
  size_t url_len;
  r.url = luaL_checklstring(L, 1, &url_len);
  if (lua_isnoneornil(L, 2)) {
    lua_settop(L, 1);
    lua_newtable(L);
  }
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_settop(L, 2);

  /* Every option's shape first: each of these raises. */
  size_t method_len = 0;
  r.method = opt_string(L, "method", &method_len); /* index 3 */
  r.body = opt_string(L, "body", &r.body_len);     /* index 4 */
  int has_headers = opt_table(L, "headers");       /* index 5 */
  if (has_headers) headers_check(L);
  int has_script = opt_table(L, "script");         /* index 6 */
  if (has_script) script_check(L);
  r.follow = opt_boolean(L, "follow", 1);
  r.verbose = opt_boolean(L, "verbose", 0);
  r.max_redirects = opt_integer(L, "max_redirects", 10, MAX_REDIRECTS);
  r.connect_timeout_ms = opt_integer(L, "connect_timeout_ms",
                                     DEFAULT_CONNECT_TIMEOUT_MS, LONG_MAX);
  r.timeout_ms = opt_integer(L, "timeout_ms", 0, LONG_MAX);
  r.low_speed_bytes = opt_integer(L, "low_speed_bytes",
                                  DEFAULT_LOW_SPEED_BYTES, LONG_MAX);
  r.low_speed_seconds = opt_integer(L, "low_speed_seconds",
                                    DEFAULT_LOW_SPEED_SECONDS,
                                    MAX_LOW_SPEED_SECONDS);

  /* Then what they say: a value curl could not send as given is
   * `nil, err`. curl takes C strings, so a NUL anywhere would silently
   * send something shorter. */
  if (r.method != NULL && !is_token(r.method, method_len)) {
    return failed(L, "invalid method: must be an HTTP token");
  }
  if (memchr(r.url, '\0', url_len) != NULL) {
    return failed(L, "invalid url: contains a NUL byte");
  }
  /* A request that could reach past the process is noted before it
   * connects (core/observed.h); a scripted one connects nowhere. */
  if (cosmic_observing && !has_script &&
      !cosmic_observed_note(COSMIC_OBSERVED_HTTP, r.url, url_len)) {
    return failed(L, "not enough memory to observe the request");
  }
  if (has_headers) {
    lua_pushvalue(L, 5);
    if (headers_problem(L)) {
      lua_pushnil(L);
      lua_insert(L, -2);
      return 2;
    }
    lua_pop(L, 1);
  }
  const char *trouble = http_ready(L);
  if (trouble != NULL) return failed(L, trouble);

  /* The body's one uservalue keeps it alive for as long as curl may
   * still be sending it, which is well past `open`'s return. */
  struct transfer *t = lua_newuserdatauv(L, sizeof *t, 1); /* index 7 */
  memset(t, 0, sizeof *t);
#ifdef COSMIC_CHECKED
  cosmic_http_live_transfers++;
#endif
  luaL_setmetatable(L, HANDLE_TYPE);
  if (r.body != NULL) {
    lua_pushvalue(L, 4);
    lua_setiuservalue(L, 7, 1);
  }

  t->easy = COSMIC_FAULT("curl_easy_init") ? NULL : curl_easy_init();
  if (t->easy == NULL) {
    transfer_release(t);
    return failed(L, "curl_easy_init failed");
  }
  t->follow = r.follow;
  const char *which = NULL;
  CURLcode rc = configure(t, &r, &which);
  if (rc != CURLE_OK) return setopt_failed(L, t, which, rc);

  if (has_headers) {
    lua_pushvalue(L, 5);
    const char *unbuilt = headers_build(L, t);
    lua_pop(L, 1);
    if (unbuilt != NULL) {
      transfer_release(t);
      return failed(L, unbuilt);
    }
    rc = COSMIC_FAULT("curl_easy_setopt(CURLOPT_HTTPHEADER)")
             ? CURLE_OUT_OF_MEMORY
             : curl_easy_setopt(t->easy, CURLOPT_HTTPHEADER,
                                t->request_headers);
    if (rc != CURLE_OK) {
      return setopt_failed(L, t, "CURLOPT_HTTPHEADER", rc);
    }
  }

  if (has_script) {
    lua_pushvalue(L, 6);
    t->script = script_new(L);
    lua_pop(L, 1);
    if (t->script == NULL) {
      transfer_release(t);
      return failed(L, "no memory for the script");
    }
    t->connect_to = COSMIC_FAULT("curl_slist_append")
                        ? NULL
                        : curl_slist_append(NULL, "::127.0.0.1:");
    if (t->connect_to == NULL) {
      transfer_release(t);
      return failed(L, "curl_slist_append failed for the script");
    }
    rc = configure_script(t, &which);
    if (rc != CURLE_OK) return setopt_failed(L, t, which, rc);
  }

  CURLMcode mc = COSMIC_FAULT("curl_multi_add_handle")
                    ? CURLM_OUT_OF_MEMORY
                    : curl_multi_add_handle(shared_multi, t->easy);
  if (mc != CURLM_OK) {
    transfer_release(t);
    return MULTI_FAILED(L, "curl_multi_add_handle", mc);
  }
  while (!t->ready) {
    mc = pump_once(&which);
    if (mc != CURLM_OK) {
      transfer_release(t);
      return MULTI_FAILED(L, which, mc);
    }
  }
  /* A failure after the headers is the body's, for `read` to report. */
  if (t->done && t->result != CURLE_OK && !t->headed && t->body_len == 0) {
    lua_pushnil(L);
    push_transfer_error(L, t);
    transfer_release(t);
    return 2;
  }
  lua_settop(L, 7);
  return cosmic_succeeded(L);
}

static const luaL_Reg handle_methods[] = {
  {"status", handle_status}, {"url", handle_url},
  {"headers", handle_headers}, {"read", handle_read},
  {"sent", handle_sent},     {"close", handle_close},
  {NULL, NULL},
};

/* check_certificate(der): true, "" when mbedtls reads `der` as one
 * X.509 certificate, as `load_roots` reads each of `ca_roots`; false
 * and why when it does not. What `cosmic refresh` holds a
 * new bundle to, so a root the binary would drop is refused before it
 * is written. Raises when mbedtls had no memory to read it. */
/* TODO: tell an allocation failure from a certificate mbedtls cannot
 * read here too, as load_roots's TODO says: one that comes back as
 * another code with ASN1_ALLOC_FAILED in it is reported unreadable, and
 * the root left out, rather than raised. */
static int http_check_certificate (lua_State *L) {
  size_t len;
  const char *der = luaL_checklstring(L, 1, &len);
  mbedtls_x509_crt crt;
  mbedtls_x509_crt_init(&crt);
  int parsed = mbedtls_x509_crt_parse_der(&crt, (const unsigned char *)der, len);
  mbedtls_x509_crt_free(&crt);
  if (parsed == MBEDTLS_ERR_X509_ALLOC_FAILED) {
    return luaL_error(L, "no memory to read a certificate");
  }
  if (parsed != 0) {
    /* mbedtls_strerror names none of X509's codes in this build. */
    char why[64];
    snprintf(why, sizeof why, "not an X.509 certificate mbedtls can read (-0x%04X)",
             (unsigned)-parsed);
    lua_pushboolean(L, 0);
    lua_pushstring(L, why);
    return 2;
  }
  lua_pushboolean(L, 1);
  return cosmic_succeeded(L);
}

static const luaL_Reg module[] = {
  {"open", http_open},
  {"check_certificate", http_check_certificate},
  {NULL, NULL},
};

int cosmic_open_http (lua_State *L) {
  luaL_newmetatable(L, HANDLE_TYPE);
  lua_pushcfunction(L, handle_close);
  lua_setfield(L, -2, "__gc");
  lua_pushcfunction(L, handle_close);
  lua_setfield(L, -2, "__close");
  lua_newtable(L);
  luaL_setfuncs(L, handle_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, module);
  return 1;
}
