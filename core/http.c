/* An HTTP/HTTPS client over one curl easy handle driven by one curl
 * multi handle per transfer -- see cosmic/http.tl for the typed API
 * this backs and the doc comment there for the shape callers see.
 *
 * Lua never runs inside a curl callback frame in a way that could
 * longjmp through it: the write and header callbacks only copy bytes
 * into plain C buffers and return plain integers, exactly like
 * core/sqlite.c's callbacks touch no Lua state either. `read` is the
 * only method that ever calls back into curl from Lua, and it does so
 * between bytecode instructions, not from inside a C callback -- so a
 * `luaL_error` there unwinds ordinary Lua frames only.
 *
 * `open`'s own pump loop stops driving the transfer the moment the
 * header callback marks the *final* response's headers complete --
 * "final" meaning: not a 3xx curl is about to follow itself. Nothing
 * else calls curl_multi_perform again until `read` does, so whatever
 * body bytes curl happened to hand write_cb within that same call are
 * the only ones buffered before `open` returns; write_cb bounds that
 * on its own by refusing (CURL_WRITEFUNC_PAUSE) once the buffer holds
 * above ~1 MiB, and `read` undoes that pause once the buffer drains
 * back under it. An earlier version tried pausing the transfer right
 * at the header boundary too (returning CURL_WRITEFUNC_PAUSE from the
 * header callback itself); that left the transfer's socket out of
 * curl_multi_poll's wait set after the matching curl_easy_pause in
 * `read`, so `read` polled on nothing forever. Simply not driving the
 * transfer further, rather than actively pausing it, avoids that. */

#include "http.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <curl/curl.h>

#include "cacert.h"

#define HANDLE_TYPE "cosmic.http.handle"

/* Above this many buffered, unread body bytes, the write callback
 * pauses the transfer instead of growing the buffer further. */
#define BODY_PAUSE_THRESHOLD (1024 * 1024)

struct header_pair {
  char *name; /* lowercased */
  char *value;
};

struct transfer {
  CURL *easy;
  CURLM *multi;
  struct curl_slist *request_headers;
  char errbuf[CURL_ERROR_SIZE];

  char *body;
  size_t body_len;
  size_t body_cap;

  struct header_pair *headers;
  size_t header_count;
  size_t header_cap;

  long status;         /* of the response currently being parsed */
  int headers_ready;    /* the final response's headers have arrived */
  int follow;            /* opts.follow, needed by the header callback */
  int done;               /* curl_multi says the transfer is over */
  int closed;             /* close() (or __gc) has run */
  CURLcode result;
};

/* ---- request header validation ----------------------------------- */

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

/* ---- small option helpers -------------------------------------- */

static const char *opt_string(lua_State *L, int idx, const char *key) {
  if (lua_isnil(L, idx)) return NULL;
  lua_getfield(L, idx, key);
  const char *s = lua_isnil(L, -1) ? NULL : luaL_checkstring(L, -1);
  lua_pop(L, 1);
  return s;
}

static lua_Integer opt_integer(lua_State *L, int idx, const char *key,
                               lua_Integer fallback) {
  if (lua_isnil(L, idx)) return fallback;
  lua_getfield(L, idx, key);
  lua_Integer v = lua_isnil(L, -1) ? fallback : luaL_checkinteger(L, -1);
  lua_pop(L, 1);
  return v;
}

static int opt_boolean(lua_State *L, int idx, const char *key, int fallback) {
  if (lua_isnil(L, idx)) return fallback;
  lua_getfield(L, idx, key);
  int v = lua_isnil(L, -1) ? fallback : lua_toboolean(L, -1);
  lua_pop(L, 1);
  return v;
}

/* ---- the trust store: the embedded Mozilla bundle, plus the
 * contents of $SSL_CERT_FILE when it names a readable file -- this
 * sandbox's HTTPS-proxying setup relies on exactly that addition. ---- */

static char *build_cainfo_blob(size_t *out_len) {
  const char *extra_path = getenv("SSL_CERT_FILE");
  char *extra = NULL;
  size_t extra_len = 0;

  if (extra_path != NULL && extra_path[0] != '\0') {
    FILE *f = fopen(extra_path, "rb");
    if (f != NULL) {
      if (fseek(f, 0, SEEK_END) == 0) {
        long size = ftell(f);
        if (size > 0 && fseek(f, 0, SEEK_SET) == 0) {
          extra = malloc((size_t)size);
          if (extra != NULL) {
            size_t got = fread(extra, 1, (size_t)size, f);
            if (got == (size_t)size) {
              extra_len = got;
            } else {
              free(extra);
              extra = NULL;
            }
          }
        }
      }
      fclose(f);
    }
  }

  size_t total = cosmic_cacert_pem_len + extra_len + 1 /* separating \n */;
  char *blob = malloc(total);
  if (blob == NULL) {
    free(extra);
    return NULL;
  }
  memcpy(blob, cosmic_cacert_pem, cosmic_cacert_pem_len);
  size_t at = cosmic_cacert_pem_len;
  if (extra_len > 0) {
    blob[at++] = '\n';
    memcpy(blob + at, extra, extra_len);
    at += extra_len;
  }
  free(extra);
  *out_len = at;
  return blob;
}

/* ---- curl callbacks ---------------------------------------------- */

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  struct transfer *t = userdata;
  size_t len = size * nmemb;
  if (t->body_len >= BODY_PAUSE_THRESHOLD) {
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
  return len;
}

static void headers_reset(struct transfer *t) {
  for (size_t i = 0; i < t->header_count; i++) {
    free(t->headers[i].name);
    free(t->headers[i].value);
  }
  t->header_count = 0;
}

static void header_store(struct transfer *t, const char *name, size_t name_len,
                         const char *value, size_t value_len) {
  char *lname = malloc(name_len + 1);
  if (lname == NULL) return;
  for (size_t i = 0; i < name_len; i++) {
    lname[i] = (char)tolower((unsigned char)name[i]);
  }
  lname[name_len] = '\0';

  for (size_t i = 0; i < t->header_count; i++) {
    if (strcmp(t->headers[i].name, lname) == 0) {
      char *nv = malloc(value_len + 1);
      if (nv != NULL) {
        memcpy(nv, value, value_len);
        nv[value_len] = '\0';
        free(t->headers[i].value);
        t->headers[i].value = nv;
      }
      free(lname);
      return;
    }
  }

  if (t->header_count == t->header_cap) {
    size_t want = t->header_cap == 0 ? 8 : t->header_cap * 2;
    struct header_pair *grown =
        realloc(t->headers, want * sizeof *t->headers);
    if (grown == NULL) {
      free(lname);
      return;
    }
    t->headers = grown;
    t->header_cap = want;
  }
  char *v = malloc(value_len + 1);
  if (v == NULL) {
    free(lname);
    return;
  }
  memcpy(v, value, value_len);
  v[value_len] = '\0';
  t->headers[t->header_count].name = lname;
  t->headers[t->header_count].value = v;
  t->header_count++;
}

static size_t header_cb(char *buffer, size_t size, size_t nitems,
                        void *userdata) {
  struct transfer *t = userdata;
  size_t len = size * nitems;

  if (len >= 5 && strncmp(buffer, "HTTP/", 5) == 0) {
    /* A status line starts a new response: curl either delivers this
     * once (the only response) or again after following a redirect,
     * in which case the previous block's headers belong to a response
     * that is not the one the caller gets -- drop them. */
    headers_reset(t);
    const char *sp = memchr(buffer, ' ', len);
    t->status = sp != NULL ? strtol(sp + 1, NULL, 10) : 0;
    return len;
  }

  if (len == 2 && buffer[0] == '\r' && buffer[1] == '\n') {
    if (t->status >= 100 && t->status < 200) {
      /* An informational response (100 Continue, 103 Early Hints, ...)
       * is never the final response: curl delivers its header block,
       * then the real status line and headers follow. Treat it like a
       * redirect hop -- headers_reset() on the next status line already
       * discards this block's headers, and any body bytes write_cb
       * buffered for it (there should be none per RFC 9110, but a
       * misbehaving server could send some) must not leak into the
       * final response's body. */
      t->body_len = 0;
      return len;
    }
    int is_redirect = t->follow && (t->status == 301 || t->status == 302 ||
                                    t->status == 303 || t->status == 307 ||
                                    t->status == 308);
    int has_location = 0;
    for (size_t i = 0; i < t->header_count; i++) {
      if (strcmp(t->headers[i].name, "location") == 0) {
        has_location = 1;
        break;
      }
    }
    if (!is_redirect || !has_location) {
      t->headers_ready = 1; /* open()'s pump loop stops driving the
        transfer further once it sees this; write_cb's own ~1 MiB
        pause/resume (not a pause from here) is what then bounds how
        much of the body a single further curl_multi_perform call can
        buffer before read() is actually called. Pausing right here
        instead (returning CURL_WRITEFUNC_PAUSE) looked cleaner but
        left the transfer's socket unregistered from curl_multi_poll's
        wait set after the matching curl_easy_pause(CURLPAUSE_CONT) in
        read() -- read() polled forever on nothing. */
    }
    return len;
  }

  const char *colon = memchr(buffer, ':', len);
  if (colon == NULL) {
    return len; /* a folded/odd line; nothing sane to store */
  }
  size_t name_len = (size_t)(colon - buffer);
  const char *value = colon + 1;
  size_t value_len = len - name_len - 1;
  while (value_len > 0 && (*value == ' ' || *value == '\t')) {
    value++;
    value_len--;
  }
  while (value_len > 0 &&
        (value[value_len - 1] == '\r' || value[value_len - 1] == '\n')) {
    value_len--;
  }
  header_store(t, buffer, name_len, value, value_len);
  return len;
}

/* ---- the pump: one perform-and-wait step -------------------------- */

static void pump_once(struct transfer *t) {
  int running = 0;
  curl_multi_perform(t->multi, &running);

  int msgs_left = 0;
  CURLMsg *msg;
  while ((msg = curl_multi_info_read(t->multi, &msgs_left)) != NULL) {
    if (msg->msg == CURLMSG_DONE) {
      t->done = 1;
      t->result = msg->data.result;
    }
  }

  if (!t->done) {
    int numfds = 0;
    curl_multi_poll(t->multi, NULL, 0, 1000, &numfds);
  }
}

static const char *transfer_error(struct transfer *t) {
  if (t->errbuf[0] != '\0') return t->errbuf;
  return curl_easy_strerror(t->result);
}

/* ---- teardown ------------------------------------------------------ */

static void transfer_release(struct transfer *t) {
  if (t->multi != NULL && t->easy != NULL) {
    curl_multi_remove_handle(t->multi, t->easy);
  }
  if (t->easy != NULL) {
    curl_easy_cleanup(t->easy);
    t->easy = NULL;
  }
  if (t->multi != NULL) {
    curl_multi_cleanup(t->multi);
    t->multi = NULL;
  }
  if (t->request_headers != NULL) {
    curl_slist_free_all(t->request_headers);
    t->request_headers = NULL;
  }
  headers_reset(t);
  free(t->headers);
  t->headers = NULL;
  t->header_cap = 0;
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
  lua_pushinteger(L, t->status);
  return 1;
}

static int handle_url(lua_State *L) {
  struct transfer *t = checked(L);
  const char *url = NULL;
  if (t->easy != NULL) {
    curl_easy_getinfo(t->easy, CURLINFO_EFFECTIVE_URL, &url);
  }
  lua_pushstring(L, url != NULL ? url : "");
  return 1;
}

static int handle_headers(lua_State *L) {
  struct transfer *t = checked(L);
  lua_newtable(L);
  for (size_t i = 0; i < t->header_count; i++) {
    lua_pushstring(L, t->headers[i].value);
    lua_setfield(L, -2, t->headers[i].name);
  }
  return 1;
}

static int handle_read(lua_State *L) {
  struct transfer *t = checked(L);
  lua_Integer max = luaL_optinteger(L, 2, 65536);
  luaL_argcheck(L, max > 0, 2, "must be positive");

  if (t->body_len == 0) {
    if (t->easy != NULL) {
      curl_easy_pause(t->easy, CURLPAUSE_CONT); /* undoes open()'s
        header-callback pause the first time read() is called, and any
        pause the write callback added once the buffer was last full */
    }
    while (t->body_len == 0 && !t->done) {
      pump_once(t);
    }
    if (t->body_len == 0) {
      if (t->done && t->result != CURLE_OK) {
        lua_pushnil(L);
        lua_pushstring(L, transfer_error(t));
        return 2;
      }
      lua_pushnil(L);
      lua_pushliteral(L, "");
      return 2; /* clean end of body */
    }
  }

  size_t n = (size_t)max < t->body_len ? (size_t)max : t->body_len;
  lua_pushlstring(L, t->body, n);
  memmove(t->body, t->body + n, t->body_len - n);
  t->body_len -= n;
  if (t->body_len < BODY_PAUSE_THRESHOLD && t->easy != NULL) {
    curl_easy_pause(t->easy, CURLPAUSE_CONT);
  }
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

static int http_open(lua_State *L) {
  const char *url = luaL_checkstring(L, 1);
  int has_opts = lua_gettop(L) >= 2 && !lua_isnil(L, 2);
  int opts_idx = 2;

  struct transfer *t = lua_newuserdatauv(L, sizeof *t, 0);
  memset(t, 0, sizeof *t);
  luaL_setmetatable(L, HANDLE_TYPE);

  t->easy = curl_easy_init();
  if (t->easy == NULL) {
    lua_pushnil(L);
    lua_pushliteral(L, "curl_easy_init failed");
    return 2;
  }
  t->multi = curl_multi_init();
  if (t->multi == NULL) {
    curl_easy_cleanup(t->easy);
    t->easy = NULL;
    lua_pushnil(L);
    lua_pushliteral(L, "curl_multi_init failed");
    return 2;
  }

  t->follow = has_opts ? opt_boolean(L, opts_idx, "follow", 1) : 1;
  lua_Integer max_redirects =
      has_opts ? opt_integer(L, opts_idx, "max_redirects", 10) : 10;
  const char *method = has_opts ? opt_string(L, opts_idx, "method") : NULL;
  const char *body = has_opts ? opt_string(L, opts_idx, "body") : NULL;

  curl_easy_setopt(t->easy, CURLOPT_URL, url);
  curl_easy_setopt(t->easy, CURLOPT_PROTOCOLS_STR, "http,https");
  curl_easy_setopt(t->easy, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(t->easy, CURLOPT_FOLLOWLOCATION, t->follow ? 1L : 0L);
  curl_easy_setopt(t->easy, CURLOPT_MAXREDIRS, (long)max_redirects);
  curl_easy_setopt(t->easy, CURLOPT_WRITEFUNCTION, write_cb);
  curl_easy_setopt(t->easy, CURLOPT_WRITEDATA, t);
  curl_easy_setopt(t->easy, CURLOPT_HEADERFUNCTION, header_cb);
  curl_easy_setopt(t->easy, CURLOPT_HEADERDATA, t);
  curl_easy_setopt(t->easy, CURLOPT_ERRORBUFFER, t->errbuf);
  /* Without this, an HTTPS request through an HTTP proxy delivers the
   * CONNECT tunnel's own "HTTP/1.1 200 Connection Established"
   * response to header_cb before the real TLS handshake even starts;
   * header_cb, seeing a status line followed immediately by a blank
   * line, would treat that as the final response's (empty) header
   * block and pause the transfer right there. */
  curl_easy_setopt(t->easy, CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);

  if (body != NULL) {
    size_t body_len = 0;
    lua_getfield(L, opts_idx, "body");
    luaL_checklstring(L, -1, &body_len);
    lua_pop(L, 1);
    curl_easy_setopt(t->easy, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(t->easy, CURLOPT_POSTFIELDSIZE, (long)body_len);
  }
  if (method != NULL) {
    curl_easy_setopt(t->easy, CURLOPT_CUSTOMREQUEST, method);
    if (strcasecmp(method, "HEAD") == 0) {
      /* Without this, curl still waits for a response body on the wire
       * after the headers for a HEAD request: read() then blocks until
       * the low-speed/timeout limits fire instead of seeing a clean
       * EOF. */
      curl_easy_setopt(t->easy, CURLOPT_NOBODY, 1L);
    }
  }

  if (has_opts) {
    lua_getfield(L, opts_idx, "headers");
    if (!lua_isnil(L, -1)) {
      luaL_checktype(L, -1, LUA_TTABLE);
      lua_pushnil(L);
      while (lua_next(L, -2) != 0) {
        const char *name = luaL_checkstring(L, -2);
        const char *value = luaL_checkstring(L, -1);
        const char *problem = header_problem(name, value);
        if (problem != NULL) {
          lua_pop(L, 3); /* value, key, the headers table */
          transfer_release(t);
          lua_pushnil(L);
          lua_pushfstring(L, "invalid header %s: %s", name, problem);
          return 2;
        }
        char *line = malloc(strlen(name) + strlen(value) + 3);
        if (line != NULL) {
          sprintf(line, "%s: %s", name, value);
          t->request_headers = curl_slist_append(t->request_headers, line);
          free(line);
        }
        lua_pop(L, 1);
      }
    }
    lua_pop(L, 1);
    if (t->request_headers != NULL) {
      curl_easy_setopt(t->easy, CURLOPT_HTTPHEADER, t->request_headers);
    }

    lua_Integer connect_timeout_ms =
        opt_integer(L, opts_idx, "connect_timeout_ms", 0);
    if (connect_timeout_ms > 0) {
      curl_easy_setopt(t->easy, CURLOPT_CONNECTTIMEOUT_MS,
                       (long)connect_timeout_ms);
    }
    lua_Integer timeout_ms = opt_integer(L, opts_idx, "timeout_ms", 0);
    if (timeout_ms > 0) {
      curl_easy_setopt(t->easy, CURLOPT_TIMEOUT_MS, (long)timeout_ms);
    }
    lua_Integer low_speed_bytes =
        opt_integer(L, opts_idx, "low_speed_bytes", 0);
    lua_Integer low_speed_seconds =
        opt_integer(L, opts_idx, "low_speed_seconds", 0);
    if (low_speed_bytes > 0 && low_speed_seconds > 0) {
      curl_easy_setopt(t->easy, CURLOPT_LOW_SPEED_LIMIT,
                       (long)low_speed_bytes);
      curl_easy_setopt(t->easy, CURLOPT_LOW_SPEED_TIME,
                       (long)low_speed_seconds);
    }
    if (opt_boolean(L, opts_idx, "verbose", 0)) {
      curl_easy_setopt(t->easy, CURLOPT_VERBOSE, 1L);
    }
  }

  size_t cainfo_len = 0;
  char *cainfo = build_cainfo_blob(&cainfo_len);
  if (cainfo != NULL) {
    struct curl_blob blob = {cainfo, cainfo_len, CURL_BLOB_COPY};
    curl_easy_setopt(t->easy, CURLOPT_CAINFO_BLOB, &blob);
    free(cainfo);
  }

  curl_multi_add_handle(t->multi, t->easy);

  while (!t->headers_ready && !t->done) {
    pump_once(t);
  }

  if (!t->headers_ready) {
    const char *err = transfer_error(t);
    lua_pushnil(L);
    lua_pushstring(L, err[0] != '\0' ? err : "the request failed");
    transfer_release(t);
    return 2;
  }

  return 1; /* the handle userdata lua_newuserdatauv pushed, still on top */
}

static const luaL_Reg handle_methods[] = {
    {"status", handle_status},   {"url", handle_url},
    {"headers", handle_headers}, {"read", handle_read},
    {"close", handle_close},     {NULL, NULL},
};

static const luaL_Reg module[] = {
    {"open", http_open},
    {NULL, NULL},
};

int cosmic_open_http(lua_State *L) {
  luaL_newmetatable(L, HANDLE_TYPE);
  lua_pushcfunction(L, handle_gc);
  lua_setfield(L, -2, "__gc");
  lua_pushstring(L, HANDLE_TYPE);
  lua_setfield(L, -2, "__name");
  lua_newtable(L);
  luaL_setfuncs(L, handle_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, module);
  return 1;
}
