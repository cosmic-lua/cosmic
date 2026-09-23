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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <curl/curl.h>

#include "cacert.h"

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

static CURLM *shared_multi;
static struct script *live_scripts;
static char *ca_blob;
static size_t ca_blob_len;

/* The trust store: the embedded Mozilla bundle, plus the contents of
 * $SSL_CERT_FILE when it names a readable file -- which is how a
 * TLS-intercepting proxy's own CA gets trusted. NUL-terminated, so
 * mbedtls can parse it in place. */
static char *build_ca_blob(size_t *out_len) {
  const char *extra_path = getenv("SSL_CERT_FILE");
  char *extra = NULL;
  size_t extra_len = 0;
  FILE *f = extra_path != NULL && extra_path[0] != '\0'
                ? fopen(extra_path, "rb")
                : NULL;
  if (f != NULL) {
    if (fseek(f, 0, SEEK_END) == 0) {
      long size = ftell(f);
      if (size > 0 && fseek(f, 0, SEEK_SET) == 0 &&
          (extra = malloc((size_t)size)) != NULL) {
        extra_len = fread(extra, 1, (size_t)size, f);
      }
    }
    fclose(f);
  }

  size_t total = cosmic_cacert_pem_len + 1 + extra_len + 1;
  char *blob = malloc(total);
  if (blob == NULL) {
    free(extra);
    return NULL;
  }
  memcpy(blob, cosmic_cacert_pem, cosmic_cacert_pem_len);
  size_t at = cosmic_cacert_pem_len;
  blob[at++] = '\n';
  if (extra_len > 0) memcpy(blob + at, extra, extra_len);
  at += extra_len;
  blob[at++] = '\0';
  free(extra);
  *out_len = at;
  return blob;
}

/* Initializes curl, the shared multi handle, and the trust store, the
 * first time any request needs them. Returns NULL, or why not. */
static const char *http_ready(void) {
  if (shared_multi != NULL) return NULL;
  if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
    return "curl_global_init failed";
  }
  ca_blob = build_ca_blob(&ca_blob_len);
  if (ca_blob == NULL) return "no memory for the CA bundle";
  shared_multi = curl_multi_init();
  if (shared_multi == NULL) return "curl_multi_init failed";
  return NULL;
}

/* ---- request validation ------------------------------------------ */

/* Refuses anything that could smuggle a second header (or a request
 * line) past curl: a name or value carrying CR or LF, a name
 * containing ':' (which would fold into the value on the wire), or an
 * empty name. Returns NULL if `name`/`value` are fine to send as-is,
 * or a static description of why not. */
static const char *header_problem(const char *name, const char *value) {
  if (name[0] == '\0') return "a header name must not be empty";
  for (const char *p = name; *p != '\0'; p++) {
    if (*p == '\r' || *p == '\n') {
      return "a header name must not contain CR or LF";
    }
    if (*p == ':') return "a header name must not contain ':'";
  }
  for (const char *p = value; *p != '\0'; p++) {
    if (*p == '\r' || *p == '\n') {
      return "a header value must not contain CR or LF";
    }
  }
  return NULL;
}

/* True when `method` is an HTTP token (RFC 9110 5.6.2), so it cannot
 * carry a space or line break into the request line. */
static int is_token(const char *method) {
  if (method[0] == '\0') return 0;
  for (const char *p = method; *p != '\0'; p++) {
    if (!isalnum((unsigned char)*p) &&
        strchr("!#$%&'*+-.^_`|~", *p) == NULL) {
      return 0;
    }
  }
  return 1;
}

/* ---- option helpers: the options table is always at index 2 ------- */

/* Pushes opts[key] and returns it, or NULL when it is nil; anything but
 * a string throws. The value stays on the stack, which is what keeps
 * the returned pointer valid for the rest of `open`. */
static const char *opt_string(lua_State *L, const char *key, size_t *len) {
  lua_getfield(L, 2, key);
  if (lua_isnil(L, -1)) return NULL;
  if (lua_type(L, -1) != LUA_TSTRING) {
    luaL_error(L, "opts.%s must be a string", key);
  }
  return lua_tolstring(L, -1, len);
}

static lua_Integer opt_integer(lua_State *L, const char *key,
                               lua_Integer fallback) {
  lua_getfield(L, 2, key);
  lua_Integer v = fallback;
  if (!lua_isnil(L, -1)) {
    int ok = 0;
    v = lua_tointegerx(L, -1, &ok);
    if (!ok) luaL_error(L, "opts.%s must be an integer", key);
  }
  lua_pop(L, 1);
  return v;
}

static int opt_boolean(lua_State *L, const char *key, int fallback) {
  lua_getfield(L, 2, key);
  int v = lua_isnil(L, -1) ? fallback : lua_toboolean(L, -1);
  lua_pop(L, 1);
  return v;
}

/* ---- the scripted transport (tests only) ------------------------- */

static void sent_append(struct script *s, const char *bytes, size_t len) {
  if (s->sent_len + len > s->sent_cap) {
    size_t want = s->sent_cap == 0 ? 4096 : s->sent_cap * 2;
    while (want < s->sent_len + len) want *= 2;
    char *grown = realloc(s->sent, want);
    if (grown == NULL) return;
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
static void script_step(struct script *s) {
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
static curl_socket_t script_socket(void *clientp, curlsocktype purpose,
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
static int script_sockopt(void *clientp, curl_socket_t fd,
                          curlsocktype purpose) {
  (void)clientp;
  (void)fd;
  (void)purpose;
  return CURL_SOCKOPT_ALREADY_CONNECTED;
}

/* Copies opts.script, a list of canned replies, off the stack top. */
static struct script *script_new(lua_State *L) {
  size_t count = (size_t)lua_rawlen(L, -1);
  struct script *s = calloc(1, sizeof *s);
  if (s == NULL) return NULL;
  s->conns = calloc(count > 0 ? count : 1, sizeof *s->conns);
  if (s->conns == NULL) {
    free(s);
    return NULL;
  }
  s->count = count;
  s->next = live_scripts;
  s->prev_next = &live_scripts;
  if (live_scripts != NULL) live_scripts->prev_next = &s->next;
  live_scripts = s;
  for (size_t i = 0; i < count; i++) {
    lua_rawgeti(L, -1, (lua_Integer)i + 1);
    size_t len = 0;
    const char *reply = lua_tolstring(L, -1, &len);
    struct scripted *c = &s->conns[i];
    c->fd = -1;
    c->reply = reply != NULL ? malloc(len > 0 ? len : 1) : NULL;
    if (c->reply != NULL) {
      memcpy(c->reply, reply, len);
      c->reply_len = len;
    }
    lua_pop(L, 1);
  }
  return s;
}

static void script_free(struct script *s) {
  *s->prev_next = s->next;
  if (s->next != NULL) s->next->prev_next = s->prev_next;
  for (size_t i = 0; i < s->count; i++) {
    if (s->conns[i].fd >= 0) close(s->conns[i].fd);
    free(s->conns[i].reply);
  }
  free(s->conns);
  free(s->sent);
  free(s);
}

/* ---- curl callbacks ---------------------------------------------- */

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  struct transfer *t = userdata;
  size_t len = size * nmemb;
  if (t->body_len >= BODY_PAUSE_THRESHOLD) {
    t->paused = 1;
    return CURL_WRITEFUNC_PAUSE;
  }
  if (t->body_len + len > t->body_cap) {
    size_t want = t->body_cap == 0 ? 16384 : t->body_cap * 2;
    while (want < t->body_len + len) want *= 2;
    char *grown = realloc(t->body, want);
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
static size_t header_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
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
 * done through its CURLINFO_PRIVATE pointer. */
static void pump_once(void) {
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
  curl_multi_poll(shared_multi, extra, extra_count, 1000, &numfds);
  for (struct script *s = live_scripts; s != NULL; s = s->next) {
    script_step(s);
  }

  int running = 0;
  curl_multi_perform(shared_multi, &running);
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
}

/* Undoes the write callback's pause. Clearing the flag first matters:
 * curl may call the write callback, which may pause again, from inside
 * curl_easy_pause. */
static void resume(struct transfer *t) {
  if (!t->paused || t->easy == NULL) return;
  t->paused = 0;
  curl_easy_pause(t->easy, CURLPAUSE_CONT);
}

/* curl's own message, without the newline it sometimes ends with. */
static const char *transfer_error(struct transfer *t) {
  if (t->errbuf[0] == '\0') return curl_easy_strerror(t->result);
  size_t end = strlen(t->errbuf);
  while (end > 0 && isspace((unsigned char)t->errbuf[end - 1])) {
    t->errbuf[--end] = '\0';
  }
  return t->errbuf;
}

/* ---- teardown ------------------------------------------------------ */

static void transfer_release(struct transfer *t) {
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
  free(t->body);
  t->body = NULL;
  t->body_cap = 0;
  t->body_len = 0;
  t->closed = 1;
}

/* ---- Lua-facing functions ------------------------------------------ */

static struct transfer *checked(lua_State *L) {
  struct transfer *t = luaL_checkudata(L, 1, HANDLE_TYPE);
  if (t->closed) {
    luaL_error(L, "the response is closed"); /* throws: use after close is
                                                a bug, as in core/sqlite.c */
  }
  return t;
}

static int handle_status(lua_State *L) {
  struct transfer *t = checked(L);
  long status = 0;
  curl_easy_getinfo(t->easy, CURLINFO_RESPONSE_CODE, &status);
  lua_pushinteger(L, status);
  return 1;
}

static int handle_url(lua_State *L) {
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
static int handle_headers(lua_State *L) {
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

static int handle_read(lua_State *L) {
  struct transfer *t = checked(L);
  lua_Integer max = luaL_optinteger(L, 2, 65536);
  luaL_argcheck(L, max > 0, 2, "must be positive");

  if (t->body_len == 0) {
    resume(t);
    while (t->body_len == 0 && !t->done) {
      pump_once();
    }
    if (t->body_len == 0) {
      lua_pushnil(L);
      if (t->result != CURLE_OK) {
        lua_pushstring(L, transfer_error(t));
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
  return 1;
}

/* What curl has written to a scripted transfer's connections so far,
 * all of them in order; "" for a transfer over the network. */
static int handle_sent(lua_State *L) {
  struct transfer *t = checked(L);
  if (t->script == NULL) {
    lua_pushliteral(L, "");
    return 1;
  }
  script_step(t->script);
  lua_pushlstring(L, t->script->sent != NULL ? t->script->sent : "",
                  t->script->sent_len);
  return 1;
}

static int handle_close(lua_State *L) {
  struct transfer *t = luaL_checkudata(L, 1, HANDLE_TYPE);
  transfer_release(t);
  lua_pushboolean(L, 1);
  return 1;
}

static int handle_gc(lua_State *L) {
  struct transfer *t = luaL_checkudata(L, 1, HANDLE_TYPE);
  transfer_release(t);
  return 0;
}

/* Sets the request's method and body. GET, HEAD and POST use curl's
 * own options for them, so a redirect curl follows changes the method
 * exactly as RFC 9110 says (a 303, or a 301/302 after POST, becomes a
 * GET); any other method is sent as a custom one, still with the body. */
static void set_method(CURL *easy, const char *method, const char *body,
                       size_t body_len) {
  if (method != NULL && strcmp(method, "HEAD") == 0) {
    curl_easy_setopt(easy, CURLOPT_NOBODY, 1L);
    return;
  }
  if (body != NULL) {
    curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_len);
    curl_easy_setopt(easy, CURLOPT_POSTFIELDS, body);
  } else if (method != NULL && strcmp(method, "POST") == 0) {
    curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)0);
    curl_easy_setopt(easy, CURLOPT_POSTFIELDS, "");
  }
  if (method != NULL && strcmp(method, "GET") != 0 &&
      strcmp(method, "POST") != 0) {
    curl_easy_setopt(easy, CURLOPT_CUSTOMREQUEST, method);
  }
}

static int http_open(lua_State *L) {
  size_t url_len;
  const char *url = luaL_checklstring(L, 1, &url_len);
  if (lua_isnoneornil(L, 2)) {
    lua_settop(L, 1);
    lua_newtable(L);
  }
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_settop(L, 2);

  size_t body_len = 0;
  const char *method = opt_string(L, "method", NULL); /* index 3 */
  const char *body = opt_string(L, "body", &body_len); /* index 4 */
  if (method != NULL && !is_token(method)) {
    lua_pushnil(L);
    lua_pushliteral(L, "invalid method: must be an HTTP token");
    return 2;
  }
  /* curl takes a C string: a NUL would silently fetch a shorter URL. */
  if (memchr(url, '\0', url_len) != NULL) {
    lua_pushnil(L);
    lua_pushliteral(L, "invalid url: contains a NUL byte");
    return 2;
  }
  const char *trouble = http_ready();
  if (trouble != NULL) {
    lua_pushnil(L);
    lua_pushstring(L, trouble);
    return 2;
  }

  /* The body's one uservalue keeps it alive for as long as curl may
   * still be sending it, which is well past `open`'s return. */
  struct transfer *t = lua_newuserdatauv(L, sizeof *t, 1); /* index 5 */
  memset(t, 0, sizeof *t);
  luaL_setmetatable(L, HANDLE_TYPE);
  if (body != NULL) {
    lua_pushvalue(L, 4);
    lua_setiuservalue(L, 5, 1);
  }

  t->easy = curl_easy_init();
  if (t->easy == NULL) {
    t->closed = 1;
    lua_pushnil(L);
    lua_pushliteral(L, "curl_easy_init failed");
    return 2;
  }
  CURL *easy = t->easy;
  curl_easy_setopt(easy, CURLOPT_PRIVATE, t);
  curl_easy_setopt(easy, CURLOPT_URL, url);
  curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "http,https");
  curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
  curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
  t->follow = opt_boolean(L, "follow", 1);
  curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION,
                   t->follow ? CURLFOLLOW_OBEYCODE : 0L);
  curl_easy_setopt(easy, CURLOPT_MAXREDIRS,
                   (long)opt_integer(L, "max_redirects", 10));
  curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, write_cb);
  curl_easy_setopt(easy, CURLOPT_WRITEDATA, t);
  curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, header_cb);
  curl_easy_setopt(easy, CURLOPT_HEADERDATA, t);
  /* A proxy's CONNECT reply is not the response: keep it from the
   * header callback, which would otherwise take it for the final one. */
  curl_easy_setopt(easy, CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
  curl_easy_setopt(easy, CURLOPT_ERRORBUFFER, t->errbuf);
  curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS,
                   (long)opt_integer(L, "connect_timeout_ms",
                                     DEFAULT_CONNECT_TIMEOUT_MS));
  curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS,
                   (long)opt_integer(L, "timeout_ms", 0));
  curl_easy_setopt(easy, CURLOPT_LOW_SPEED_LIMIT,
                   (long)opt_integer(L, "low_speed_bytes",
                                     DEFAULT_LOW_SPEED_BYTES));
  curl_easy_setopt(easy, CURLOPT_LOW_SPEED_TIME,
                   (long)opt_integer(L, "low_speed_seconds",
                                     DEFAULT_LOW_SPEED_SECONDS));
  curl_easy_setopt(easy, CURLOPT_VERBOSE,
                   opt_boolean(L, "verbose", 0) ? 1L : 0L);
  struct curl_blob ca = {ca_blob, ca_blob_len, CURL_BLOB_NOCOPY};
  curl_easy_setopt(easy, CURLOPT_CAINFO_BLOB, &ca);
  curl_easy_setopt(easy, CURLOPT_PROXY_CAINFO_BLOB, &ca);
  set_method(easy, method, body, body_len);

  lua_getfield(L, 2, "headers");
  if (!lua_isnil(L, -1)) {
    luaL_checktype(L, -1, LUA_TTABLE);
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
      if (lua_type(L, -2) != LUA_TSTRING || lua_type(L, -1) != LUA_TSTRING) {
        return luaL_error(L, "opts.headers must map strings to strings");
      }
      const char *name = lua_tostring(L, -2);
      const char *value = lua_tostring(L, -1);
      const char *problem = header_problem(name, value);
      if (problem != NULL) {
        transfer_release(t);
        lua_pushnil(L);
        lua_pushfstring(L, "invalid header %s: %s", name, problem);
        return 2;
      }
      lua_pushfstring(L, "%s: %s", name, value);
      struct curl_slist *more =
          curl_slist_append(t->request_headers, lua_tostring(L, -1));
      if (more != NULL) t->request_headers = more;
      lua_pop(L, 2); /* the line and the value */
    }
    curl_easy_setopt(easy, CURLOPT_HTTPHEADER, t->request_headers);
  }
  lua_pop(L, 1);

  lua_getfield(L, 2, "script");
  if (!lua_isnil(L, -1)) {
    luaL_checktype(L, -1, LUA_TTABLE);
    t->script = script_new(L);
    t->connect_to = curl_slist_append(NULL, "::127.0.0.1:");
    if (t->script == NULL || t->connect_to == NULL) {
      transfer_release(t);
      lua_pushnil(L);
      lua_pushliteral(L, "no memory for the script");
      return 2;
    }
    curl_easy_setopt(easy, CURLOPT_OPENSOCKETFUNCTION, script_socket);
    curl_easy_setopt(easy, CURLOPT_OPENSOCKETDATA, t->script);
    curl_easy_setopt(easy, CURLOPT_SOCKOPTFUNCTION, script_sockopt);
    curl_easy_setopt(easy, CURLOPT_CONNECT_TO, t->connect_to);
    curl_easy_setopt(easy, CURLOPT_PROXY, "");
    curl_easy_setopt(easy, CURLOPT_PROTOCOLS_STR, "http");
    curl_easy_setopt(easy, CURLOPT_REDIR_PROTOCOLS_STR, "http");
    curl_easy_setopt(easy, CURLOPT_FRESH_CONNECT, 1L);
    curl_easy_setopt(easy, CURLOPT_FORBID_REUSE, 1L);
  }
  lua_pop(L, 1);

  curl_multi_add_handle(shared_multi, easy);
  while (!t->ready) {
    pump_once();
  }
  /* A failure after the headers is the body's, for `read` to report. */
  if (t->done && t->result != CURLE_OK && !t->headed && t->body_len == 0) {
    lua_pushnil(L);
    lua_pushstring(L, transfer_error(t));
    transfer_release(t);
    return 2;
  }
  lua_settop(L, 5);
  return 1;
}

static const luaL_Reg handle_methods[] = {
    {"status", handle_status}, {"url", handle_url},
    {"headers", handle_headers}, {"read", handle_read},
    {"sent", handle_sent},     {"close", handle_close},
    {NULL, NULL},
};

static const luaL_Reg module[] = {
    {"open", http_open},
    {NULL, NULL},
};

int cosmic_open_http(lua_State *L) {
  luaL_newmetatable(L, HANDLE_TYPE);
  lua_pushcfunction(L, handle_gc);
  lua_setfield(L, -2, "__gc");
  lua_newtable(L);
  luaL_setfuncs(L, handle_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, module);
  return 1;
}
