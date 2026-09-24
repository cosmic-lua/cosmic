/*
 * The patch applier.
 *
 *   patch <vendor dir> <patch dir> <out dir>
 *
 * It writes a whole patched copy of the vendor tree into the output
 * directory, then applies every record in the patch directory to that
 * copy. The output directory is replaced, never merged into a pristine
 * tree beside it, because a quoted #include finds its neighbour first
 * and a half-applied patch would build green.
 *
 * A record is a text file:
 *
 *     file: src/luaconf.h
 *     note: why this edit exists
 *     --- find
 *     the exact bytes to replace
 *     --- replace
 *     the bytes to put there
 *     --- end
 *
 * The `---` prefix is the default fence. A record whose own bytes contain
 * a fence line declares another one with a `fence: <token>` header line.
 * Both blocks are exact bytes, and the find must match exactly once: zero
 * matches or more than one is an error naming the record.
 *
 * A missing patch directory is not an error; the copy is then pristine.
 *
 * TODO: bytes after a record's `--- end` are ignored without a word, so a
 * second find/replace pair written into one record is silently dropped.
 * Refuse trailing content, or accept several pairs per record.
 */

#define _XOPEN_SOURCE 700

#include <dirent.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static _Noreturn void fail (const char *what, const char *detail) {
  if (detail != NULL) {
    fprintf(stderr, "patch: %s: %s\n", what, detail);
  } else {
    fprintf(stderr, "patch: %s\n", what);
  }
  exit(1);
}

static _Noreturn void fail_errno (const char *what, const char *path) {
  fprintf(stderr, "patch: %s %s: %s\n", what, path, strerror(errno));
  exit(1);
}

static void *xmalloc (size_t n) {
  void *p = malloc(n == 0 ? 1 : n);
  if (p == NULL) {
    fail("out of memory", NULL);
  }
  return p;
}

static char *join (const char *dir, const char *name) {
  size_t a = strlen(dir), b = strlen(name);
  char *out = xmalloc(a + b + 2);
  memcpy(out, dir, a);
  out[a] = '/';
  memcpy(out + a + 1, name, b);
  out[a + b + 1] = '\0';
  return out;
}

/* Reads a whole file. Sets *len; the buffer gets a trailing NUL. */
static char *slurp (const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (f == NULL) {
    fail_errno("cannot read", path);
  }
  size_t cap = 1 << 16, n = 0;
  char *buf = xmalloc(cap);
  for (;;) {
    if (n == cap) {
      cap *= 2;
      char *grown = realloc(buf, cap);
      if (grown == NULL) {
        fail("out of memory", NULL);
      }
      buf = grown;
    }
    size_t want = cap - n;
    size_t got = fread(buf + n, 1, want, f);
    n += got;
    /* A short read is the end of the file or an error; ferror says
     * which, and nothing reads past it. */
    if (got < want) {
      if (ferror(f)) {
        fail_errno("cannot read", path);
      }
      break;
    }
  }
  fclose(f);
  char *grown = realloc(buf, n + 1);
  if (grown == NULL) {
    fail("out of memory", NULL);
  }
  buf = grown;
  buf[n] = '\0';
  *len = n;
  return buf;
}

static void spit (const char *path, const char *data, size_t len, mode_t mode) {
  FILE *f = fopen(path, "wb");
  if (f == NULL) {
    fail_errno("cannot write", path);
  }
  if (len > 0 && fwrite(data, 1, len, f) != len) {
    fail_errno("cannot write", path);
  }
  if (fclose(f) != 0) {
    fail_errno("cannot write", path);
  }
  if (chmod(path, mode & 0777) != 0) {
    fail_errno("cannot set mode on", path);
  }
}

static void make_dir (const char *path) {
  if (mkdir(path, 0755) != 0 && errno != EEXIST) {
    fail_errno("cannot create", path);
  }
}

static int compare_names (const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* Reads a directory into a sorted array, so a copy is reproducible. */
static char **list_dir (const char *path, size_t *count) {
  DIR *d = opendir(path);
  if (d == NULL) {
    fail_errno("cannot open", path);
  }
  size_t cap = 64, n = 0;
  char **names = xmalloc(cap * sizeof(char *));
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
      continue;
    }
    if (n == cap) {
      cap *= 2;
      char **grown = realloc(names, cap * sizeof(char *));
      if (grown == NULL) {
        fail("out of memory", NULL);
      }
      names = grown;
    }
    size_t len = strlen(e->d_name);
    names[n] = xmalloc(len + 1);
    memcpy(names[n], e->d_name, len + 1);
    n++;
  }
  closedir(d);
  qsort(names, n, sizeof(char *), compare_names);
  *count = n;
  return names;
}

static void copy_tree (const char *from, const char *to) {
  make_dir(to);
  size_t count;
  char **names = list_dir(from, &count);
  for (size_t i = 0; i < count; i++) {
    char *src = join(from, names[i]);
    char *dst = join(to, names[i]);
    struct stat st;
    if (lstat(src, &st) != 0) {
      fail_errno("cannot stat", src);
    }
    if (S_ISDIR(st.st_mode)) {
      copy_tree(src, dst);
    } else if (S_ISREG(st.st_mode)) {
      size_t len;
      char *data = slurp(src, &len);
      spit(dst, data, len, st.st_mode);
      free(data);
    }
    /* Anything else -- a symlink, a device -- is not upstream source. */
    free(src);
    free(dst);
    free(names[i]);
  }
  free(names);
}

/* Finds a line that is exactly `prefix` + ` ` + `word`. Returns its start,
 * and sets *after to the first byte of the next line. */
static char *find_fence (char *from, const char *prefix, const char *word,
                         char **after) {
  size_t plen = strlen(prefix), wlen = strlen(word);
  char *at = from;
  while (at != NULL && *at != '\0') {
    char *eol = strchr(at, '\n');
    size_t line = eol == NULL ? strlen(at) : (size_t)(eol - at);
    if (line == plen + 1 + wlen && memcmp(at, prefix, plen) == 0 &&
        at[plen] == ' ' && memcmp(at + plen + 1, word, wlen) == 0) {
      *after = eol == NULL ? at + line : eol + 1;
      return at;
    }
    if (eol == NULL) {
      break;
    }
    at = eol + 1;
  }
  return NULL;
}

/* Reads a `key: value` header line at `*at`, advancing past it. */
static char *header (char **at, const char *key, const char *record) {
  size_t klen = strlen(key);
  char *line = *at;
  char *eol = strchr(line, '\n');
  if (eol == NULL || (size_t)(eol - line) < klen + 2 ||
      memcmp(line, key, klen) != 0 || line[klen] != ':' ||
      line[klen + 1] != ' ') {
    fprintf(stderr, "patch: %s: expected a '%s: ' line\n", record, key);
    exit(1);
  }
  size_t len = (size_t)(eol - line) - klen - 2;
  char *value = xmalloc(len + 1);
  memcpy(value, line + klen + 2, len);
  value[len] = '\0';
  *at = eol + 1;
  return value;
}

static void apply_record (const char *record, const char *out_dir) {
  size_t len;
  char *text = slurp(record, &len);
  char *at = text;

  char *fence = NULL;
  if (strncmp(at, "fence: ", 7) == 0) {
    fence = header(&at, "fence", record);
  } else {
    fence = xmalloc(4);
    memcpy(fence, "---", 4);
  }
  char *file = header(&at, "file", record);
  char *note = header(&at, "note", record);
  if (note[0] == '\0') {
    fprintf(stderr, "patch: %s: the note says nothing\n", record);
    exit(1);
  }

  char *find_body, *replace_start, *replace_body, *end_start, *unused;
  char *find_start = find_fence(at, fence, "find", &find_body);
  if (find_start == NULL) {
    fprintf(stderr, "patch: %s: no '%s find' line\n", record, fence);
    exit(1);
  }
  replace_start = find_fence(find_body, fence, "replace", &replace_body);
  if (replace_start == NULL) {
    fprintf(stderr, "patch: %s: no '%s replace' line\n", record, fence);
    exit(1);
  }
  end_start = find_fence(replace_body, fence, "end", &unused);
  if (end_start == NULL) {
    fprintf(stderr, "patch: %s: no '%s end' line\n", record, fence);
    exit(1);
  }

  /* Each block runs to the newline before its closing fence, so the
   * fence's own line break belongs to the fence and not to the bytes. */
  size_t find_len = (size_t)(replace_start - find_body);
  size_t replace_len = (size_t)(end_start - replace_body);
  if (find_len == 0) {
    fprintf(stderr, "patch: %s: the find block is empty\n", record);
    exit(1);
  }
  find_len--;
  if (replace_len > 0) {
    replace_len--;
  }

  char *target = join(out_dir, file);
  size_t source_len;
  char *source = slurp(target, &source_len);

  size_t matches = 0, offset = 0;
  for (size_t i = 0; find_len <= source_len && i + find_len <= source_len; i++) {
    if (memcmp(source + i, find_body, find_len) == 0) {
      if (matches == 0) {
        offset = i;
      }
      matches++;
    }
  }
  if (matches != 1) {
    fprintf(stderr, "patch: %s: found %zu matches in %s, wanted exactly 1\n",
            record, matches, file);
    exit(1);
  }

  /* One match means find_len <= source_len, so the first difference
   * cannot wrap; the sum and its terminator are refused if they would. */
  size_t kept = source_len - find_len;
  if (replace_len >= SIZE_MAX - kept) {
    fail("the patched file is too large", file);
  }
  size_t out_len = kept + replace_len;
  char *out = xmalloc(out_len + 1);
  memcpy(out, source, offset);
  memcpy(out + offset, replace_body, replace_len);
  memcpy(out + offset + replace_len, source + offset + find_len,
         source_len - offset - find_len);

  struct stat st;
  if (stat(target, &st) != 0) {
    fail_errno("cannot stat", target);
  }
  spit(target, out, out_len, st.st_mode);

  free(out);
  free(source);
  free(target);
  free(note);
  free(file);
  free(fence);
  free(text);
}

int main (int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: patch <vendor dir> <patch dir> <out dir>\n");
    return 2;
  }
  const char *vendor = argv[1], *patches = argv[2], *out = argv[3];

  copy_tree(vendor, out);

  struct stat st;
  if (stat(patches, &st) != 0) {
    if (errno == ENOENT) {
      return 0;
    }
    fail_errno("cannot stat", patches);
  }
  if (!S_ISDIR(st.st_mode)) {
    fail("not a directory", patches);
  }

  size_t count;
  char **names = list_dir(patches, &count);
  for (size_t i = 0; i < count; i++) {
    size_t len = strlen(names[i]);
    if (len > 4 && strcmp(names[i] + len - 4, ".txt") == 0) {
      char *record = join(patches, names[i]);
      apply_record(record, out);
      free(record);
    }
    free(names[i]);
  }
  free(names);
  return 0;
}
