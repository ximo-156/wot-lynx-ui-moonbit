/* No shell command API: only the fixed read-only Git operations below. */
#if !defined(_WIN32) && !defined(_WIN64)
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 700
#endif
#endif

#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "moonbit.h"

#if defined(__APPLE__) || defined(__linux__)
#define MOONLINT_POSIX 1
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
#else
#define MOONLINT_POSIX 0
#endif

#ifdef __cplusplus
extern "C" {
#endif

struct moonlint_buffer {
  unsigned char *data;
  size_t len;
  size_t cap;
};

struct moonlint_result {
  int status;
  int value;
  struct moonlint_buffer out;
  struct moonlint_buffer error;
};

static void buffer_free(struct moonlint_buffer *b) {
  free(b->data);
  memset(b, 0, sizeof(*b));
}

/* MoonBit byte/string lengths are Int32. Grow dynamically, never truncate. */
static int buffer_append(struct moonlint_buffer *b, const void *data, size_t n) {
  size_t needed;
  size_t cap;
  unsigned char *next;
  if (n > (size_t)INT32_MAX - b->len) {
    errno = EOVERFLOW;
    return 0;
  }
  needed = b->len + n;
  if (needed > b->cap) {
    cap = b->cap ? b->cap : 16384;
    while (cap < needed) {
      if (cap > (size_t)INT32_MAX / 2) {
        cap = (size_t)INT32_MAX;
        break;
      }
      cap *= 2;
    }
    next = (unsigned char *)realloc(b->data, cap);
    if (!next) {
      errno = ENOMEM;
      return 0;
    }
    b->data = next;
    b->cap = cap;
  }
  if (n) memcpy(b->data + b->len, data, n);
  b->len = needed;
  return 1;
}

static void result_fail(struct moonlint_result *r, const char *format, ...) {
  va_list args;
  va_list copy;
  int n;
  char *message;
  if (r->status) return;
  r->status = 1;
  va_start(args, format);
  va_copy(copy, args);
  n = vsnprintf(NULL, 0, format, copy);
  va_end(copy);
  if (n < 0 || n == INT32_MAX) {
    va_end(args);
    return;
  }
  message = (char *)malloc((size_t)n + 1);
  if (message) {
    vsnprintf(message, (size_t)n + 1, format, args);
    (void)buffer_append(&r->error, message, (size_t)n);
    free(message);
  }
  va_end(args);
}

#if MOONLINT_POSIX

struct git_output {
  struct moonlint_buffer out;
  struct moonlint_buffer error;
};

struct git_context {
  char *root;
  char *top;
  char *prefix;
};

static void git_output_free(struct git_output *o) {
  buffer_free(&o->out);
  buffer_free(&o->error);
}

static void git_context_free(struct git_context *c) {
  free(c->root);
  free(c->top);
  free(c->prefix);
  memset(c, 0, sizeof(*c));
}

static char *copy_string(struct moonlint_result *r, const void *data, size_t n) {
  char *s;
  if (n > (size_t)INT32_MAX) {
    result_fail(r, "native path exceeds the MoonBit Int32 length limit");
    return NULL;
  }
  s = (char *)malloc(n + 1);
  if (!s) {
    result_fail(r, "native bridge: out of memory");
    return NULL;
  }
  if (n) memcpy(s, data, n);
  s[n] = '\0';
  return s;
}

static char *resolve_directory(struct moonlint_result *r, const char *path) {
  char *resolved;
  struct stat st;
  resolved = realpath(path, NULL);
  if (!resolved) {
    result_fail(r, "realpath(%s): %s", path, strerror(errno));
    return NULL;
  }
  if (stat(resolved, &st) < 0) {
    result_fail(r, "stat(%s): %s", resolved, strerror(errno));
    free(resolved);
    return NULL;
  }
  if (!S_ISDIR(st.st_mode)) {
    result_fail(r, "root is not a directory: %s", resolved);
    free(resolved);
    return NULL;
  }
  return resolved;
}

/* Move pipe descriptors above stdin/out/err, so spawn actions cannot collide. */
static int make_pipe(int p[2]) {
  int i;
  p[0] = p[1] = -1;
  if (pipe(p) < 0) return 0;
  for (i = 0; i < 2; i++) {
    if (p[i] < 3) {
      int moved = fcntl(p[i], F_DUPFD, 3);
      if (moved < 0) goto fail;
      close(p[i]);
      p[i] = moved;
    }
    if (fcntl(p[i], F_SETFD, FD_CLOEXEC) < 0) goto fail;
  }
  return 1;
fail: {
    int saved = errno;
    close(p[0]);
    close(p[1]);
    p[0] = p[1] = -1;
    errno = saved;
    return 0;
  }
}

static void close_fd(int *fd) {
  if (*fd >= 0) {
    close(*fd);
    *fd = -1;
  }
}

/* Both pipes are drained together; neither stderr nor stdout can deadlock. */
static int git_run(struct moonlint_result *r, const char *root,
                   const char *label, const char *const *arguments,
                   struct git_output *output) {
  char *argv[48];
  int argc = 0;
  int out_pipe[2] = {-1, -1};
  int err_pipe[2] = {-1, -1};
  posix_spawn_file_actions_t actions;
  int actions_ready = 0;
  int error = 0;
  int status = 0;
  pid_t pid = -1;
  size_t i;
  memset(output, 0, sizeof(*output));
  argv[argc++] = (char *)"git";
  argv[argc++] = (char *)"--no-pager";
  argv[argc++] = (char *)"--no-optional-locks";
  argv[argc++] = (char *)"--literal-pathspecs";
  argv[argc++] = (char *)"-c";
  argv[argc++] = (char *)"core.fsmonitor=false";
  argv[argc++] = (char *)"-c";
  argv[argc++] = (char *)"color.ui=false";
  argv[argc++] = (char *)"-C";
  argv[argc++] = (char *)root;
  for (i = 0; arguments[i]; i++) {
    if (argc >= (int)(sizeof(argv) / sizeof(argv[0])) - 1) {
      result_fail(r, "internal Git argv limit exceeded");
      return 0;
    }
    argv[argc++] = (char *)arguments[i];
  }
  argv[argc] = NULL;
  if (!make_pipe(out_pipe) || !make_pipe(err_pipe)) {
    error = errno;
    goto io_fail;
  }
  if (fcntl(out_pipe[0], F_SETFL, O_NONBLOCK) < 0 ||
      fcntl(err_pipe[0], F_SETFL, O_NONBLOCK) < 0) {
    error = errno;
    goto io_fail;
  }
  error = posix_spawn_file_actions_init(&actions);
  if (error) goto io_fail;
  actions_ready = 1;
#define ADD_ACTION(action) do { error = (action); if (error) goto io_fail; } while (0)
  ADD_ACTION(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO,
                                             "/dev/null", O_RDONLY, 0));
  ADD_ACTION(posix_spawn_file_actions_adddup2(&actions, out_pipe[1], STDOUT_FILENO));
  ADD_ACTION(posix_spawn_file_actions_adddup2(&actions, err_pipe[1], STDERR_FILENO));
  ADD_ACTION(posix_spawn_file_actions_addclose(&actions, out_pipe[0]));
  ADD_ACTION(posix_spawn_file_actions_addclose(&actions, out_pipe[1]));
  ADD_ACTION(posix_spawn_file_actions_addclose(&actions, err_pipe[0]));
  ADD_ACTION(posix_spawn_file_actions_addclose(&actions, err_pipe[1]));
#undef ADD_ACTION
  error = posix_spawnp(&pid, "git", &actions, NULL, argv, environ);
  posix_spawn_file_actions_destroy(&actions);
  actions_ready = 0;
  if (error) goto io_fail;
  close_fd(&out_pipe[1]);
  close_fd(&err_pipe[1]);
  while (out_pipe[0] >= 0 || err_pipe[0] >= 0) {
    struct pollfd polls[2];
    int polled;
    polls[0].fd = out_pipe[0];
    polls[0].events = POLLIN;
    polls[0].revents = 0;
    polls[1].fd = err_pipe[0];
    polls[1].events = POLLIN;
    polls[1].revents = 0;
    do { polled = poll(polls, 2, -1); } while (polled < 0 && errno == EINTR);
    if (polled < 0) {
      error = errno;
      goto io_fail;
    }
    for (i = 0; i < 2; i++) {
      int *fd = i == 0 ? &out_pipe[0] : &err_pipe[0];
      struct moonlint_buffer *buffer = i == 0 ? &output->out : &output->error;
      if (*fd < 0 || !polls[i].revents) continue;
      if (polls[i].revents & POLLNVAL) {
        error = EBADF;
        goto io_fail;
      }
      for (;;) {
        unsigned char chunk[16384];
        ssize_t n = read(*fd, chunk, sizeof(chunk));
        if (n > 0) {
          if (!buffer_append(buffer, chunk, (size_t)n)) {
            error = errno;
            goto io_fail;
          }
        } else if (n == 0) {
          close_fd(fd);
          break;
        } else if (errno == EINTR) {
          continue;
        } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
          break;
        } else {
          error = errno;
          goto io_fail;
        }
      }
    }
  }
  for (;;) {
    if (waitpid(pid, &status, 0) >= 0) break;
    if (errno != EINTR) {
      error = errno;
      goto io_fail;
    }
  }
  pid = -1;
  if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return 1;
  if (WIFEXITED(status)) {
    result_fail(r, "git %s exited with status %d", label, WEXITSTATUS(status));
  } else if (WIFSIGNALED(status)) {
    result_fail(r, "git %s terminated by signal %d", label, WTERMSIG(status));
  } else {
    result_fail(r, "git %s terminated abnormally", label);
  }
  if (output->error.len) {
    (void)buffer_append(&r->error, ": ", 2);
    (void)buffer_append(&r->error, output->error.data, output->error.len);
  }
  git_output_free(output);
  return 0;
io_fail:
  if (actions_ready) posix_spawn_file_actions_destroy(&actions);
  close_fd(&out_pipe[0]);
  close_fd(&out_pipe[1]);
  close_fd(&err_pipe[0]);
  close_fd(&err_pipe[1]);
  if (pid > 0) {
    (void)kill(pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  }
  result_fail(r, "git %s: %s", label, strerror(error ? error : EIO));
  git_output_free(output);
  return 0;
}

/* rev-parse adds exactly one LF; path contents themselves are not trimmed. */
static char *git_path_line(struct moonlint_result *r,
                          struct moonlint_buffer *b, const char *label) {
  if (!b->len || b->data[b->len - 1] != '\n' ||
      memchr(b->data, '\0', b->len)) {
    result_fail(r, "git %s returned a malformed path", label);
    return NULL;
  }
  return copy_string(r, b->data, b->len - 1);
}

static int git_context_open(struct moonlint_result *r, const char *root,
                            struct git_context *c) {
  struct git_output output;
  char *top_line = NULL;
  const char *top_args[] = {"rev-parse", "--show-toplevel", NULL};
  const char *prefix_args[] = {"rev-parse", "--show-prefix", NULL};
  memset(c, 0, sizeof(*c));
  c->root = resolve_directory(r, root);
  if (!c->root) return 0;
  if (!git_run(r, c->root, "rev-parse --show-toplevel", top_args, &output)) goto fail;
  top_line = git_path_line(r, &output.out, "--show-toplevel");
  git_output_free(&output);
  if (!top_line) goto fail;
  c->top = resolve_directory(r, top_line);
  free(top_line);
  top_line = NULL;
  if (!c->top) goto fail;
  if (!git_run(r, c->root, "rev-parse --show-prefix", prefix_args, &output)) goto fail;
  c->prefix = git_path_line(r, &output.out, "--show-prefix");
  git_output_free(&output);
  if (!c->prefix) goto fail;
  if (c->prefix[0] == '/' ||
      (c->prefix[0] && c->prefix[strlen(c->prefix) - 1] != '/')) {
    result_fail(r, "Git returned an invalid repository-relative root prefix");
    goto fail;
  }
  return 1;
fail:
  free(top_line);
  git_context_free(c);
  return 0;
}

static int oid_valid(const unsigned char *data, size_t len) {
  size_t i;
  if (len != 40 && len != 64) return 0;
  for (i = 0; i < len; i++) {
    if (!((data[i] >= '0' && data[i] <= '9') ||
          (data[i] >= 'a' && data[i] <= 'f'))) return 0;
  }
  return 1;
}

static char *git_oid_line(struct moonlint_result *r,
                         struct moonlint_buffer *b, const char *label) {
  if (!b->len || b->data[b->len - 1] != '\n' ||
      !oid_valid(b->data, b->len - 1)) {
    result_fail(r, "git %s returned a malformed object ID", label);
    return NULL;
  }
  return copy_string(r, b->data, b->len - 1);
}

static char *git_commit(struct moonlint_result *r, const struct git_context *c,
                        const char *ref) {
  struct git_output output;
  struct moonlint_buffer expression = {0};
  char *oid = NULL;
  const char *args[] = {"rev-parse", "--verify", "--end-of-options", NULL, NULL};
  if (!ref[0]) {
    result_fail(r, "Git reference must not be empty");
    return NULL;
  }
  if (!buffer_append(&expression, ref, strlen(ref)) ||
      !buffer_append(&expression, "^{commit}", 9) ||
      !buffer_append(&expression, "\0", 1)) {
    result_fail(r, "Git reference is too large or memory is exhausted");
    buffer_free(&expression);
    return NULL;
  }
  args[3] = (const char *)expression.data;
  if (git_run(r, c->top, "rev-parse commit", args, &output)) {
    oid = git_oid_line(r, &output.out, "rev-parse commit");
    git_output_free(&output);
  }
  buffer_free(&expression);
  return oid;
}

static int path_is_relative(struct moonlint_result *r, const char *path) {
  const char *p = path;
  if (!path[0] || path[0] == '/') goto invalid;
  while (*p) {
    const char *end = strchr(p, '/');
    size_t n = end ? (size_t)(end - p) : strlen(p);
    if (!n || (n == 1 && p[0] == '.') ||
        (n == 2 && p[0] == '.' && p[1] == '.')) goto invalid;
    if (!end) return 1;
    p = end + 1;
    if (!*p) goto invalid;
  }
invalid:
  result_fail(r, "Git source path must be a normalized nonempty relative path: %s", path);
  return 0;
}

static char *git_full_path(struct moonlint_result *r, const struct git_context *c,
                           const char *rel) {
  size_t a;
  size_t b;
  char *full;
  if (!path_is_relative(r, rel)) return NULL;
  a = strlen(c->prefix);
  b = strlen(rel);
  if (a > (size_t)INT32_MAX - b) {
    result_fail(r, "Git source path exceeds the MoonBit Int32 length limit");
    return NULL;
  }
  full = (char *)malloc(a + b + 1);
  if (!full) {
    result_fail(r, "native bridge: out of memory");
    return NULL;
  }
  memcpy(full, c->prefix, a);
  memcpy(full + a, rel, b + 1);
  return full;
}

static int git_filter_paths(struct moonlint_result *r,
                            const struct git_context *c,
                            const struct moonlint_buffer *input) {
  size_t start = 0;
  size_t prefix_len = strlen(c->prefix);
  while (start < input->len) {
    const unsigned char *path = input->data + start;
    const unsigned char *nul = (const unsigned char *)memchr(path, '\0', input->len - start);
    size_t n;
    if (!nul || nul == path) {
      result_fail(r, "Git returned a malformed NUL-delimited path list");
      return 0;
    }
    n = (size_t)(nul - path);
    if (n > prefix_len && (!prefix_len || !memcmp(path, c->prefix, prefix_len))) {
      if (!path_is_relative(r, (const char *)path + prefix_len)) return 0;
      if (!buffer_append(&r->out, path + prefix_len, n - prefix_len + 1)) {
        result_fail(r, "Git path output is too large or memory is exhausted");
        return 0;
      }
    }
    start += n + 1;
  }
  return 1;
}

static int git_reject_unmerged(struct moonlint_result *r, const struct git_context *c) {
  const char *args[] = {"ls-files", "--unmerged", "--full-name", "-z", NULL};
  struct git_output output;
  int ok;
  if (!git_run(r, c->top, "ls-files --unmerged", args, &output)) return 0;
  ok = output.out.len == 0;
  git_output_free(&output);
  if (!ok) result_fail(r, "Git index contains unmerged entries; resolve conflicts before scanning staged sources");
  return ok;
}

static void git_changed(struct moonlint_result *r, const char *root, const char *ref) {
  struct git_context c;
  struct git_output output;
  char *ref_oid = NULL;
  char *head_oid = NULL;
  char *base_oid = NULL;
  const char *base_args[] = {"merge-base", NULL, NULL, NULL};
  const char *diff_args[] = {"diff", "--name-only", "-z", "--diff-filter=ACMR",
                             "--find-renames", "--no-ext-diff", "--no-textconv",
                             "--no-relative", NULL, NULL, "--", NULL};
  if (!git_context_open(r, root, &c)) return;
  ref_oid = git_commit(r, &c, ref);
  if (!ref_oid) goto done;
  head_oid = git_commit(r, &c, "HEAD");
  if (!head_oid) goto done;
  base_args[1] = ref_oid;
  base_args[2] = head_oid;
  if (!git_run(r, c.top, "merge-base", base_args, &output)) goto done;
  base_oid = git_oid_line(r, &output.out, "merge-base");
  git_output_free(&output);
  if (!base_oid) goto done;
  diff_args[8] = base_oid;
  diff_args[9] = head_oid;
  if (!git_run(r, c.top, "diff merge-base..HEAD", diff_args, &output)) goto done;
  (void)git_filter_paths(r, &c, &output.out);
  git_output_free(&output);
done:
  free(ref_oid);
  free(head_oid);
  free(base_oid);
  git_context_free(&c);
}

static void git_staged(struct moonlint_result *r, const char *root) {
  struct git_context c;
  struct git_output output;
  /* Without an explicit HEAD, Git handles an unborn branch as an empty tree. */
  const char *args[] = {"diff", "--cached", "--name-only", "-z",
                        "--diff-filter=ACMR", "--find-renames", "--no-ext-diff",
                        "--no-textconv", "--no-relative", "--", NULL};
  if (!git_context_open(r, root, &c)) return;
  if (git_reject_unmerged(r, &c) &&
      git_run(r, c.top, "diff --cached", args, &output)) {
    (void)git_filter_paths(r, &c, &output.out);
    git_output_free(&output);
  }
  git_context_free(&c);
}

static int mode_kind(unsigned int mode) {
  if ((mode & 0170000) == 0100000) return 1;
  if ((mode & 0170000) == 0040000) return 2;
  return 3;
}

/* Parse machine records, splitting only header spaces/TAB and final NUL. */
static int git_entry(struct moonlint_result *r, const struct moonlint_buffer *b,
                      const char *full, int staged, char oid[65]) {
  size_t start = 0;
  size_t wanted_len = strlen(full);
  int found = 0;
  int kind = 0;
  while (start < b->len) {
    const unsigned char *record = b->data + start;
    const unsigned char *nul = (const unsigned char *)memchr(record, '\0', b->len - start);
    const unsigned char *tab;
    const unsigned char *first_space;
    const unsigned char *second_space;
    const unsigned char *object;
    size_t object_len;
    size_t path_len;
    unsigned int mode = 0;
    size_t i;
    if (!nul || nul == record) goto malformed;
    tab = (const unsigned char *)memchr(record, '\t', (size_t)(nul - record));
    if (!tab) goto malformed;
    first_space = (const unsigned char *)memchr(record, ' ', (size_t)(tab - record));
    if (!first_space || first_space - record != 6) goto malformed;
    for (i = 0; i < 6; i++) {
      if (record[i] < '0' || record[i] > '7') goto malformed;
      mode = mode * 8 + (unsigned int)(record[i] - '0');
    }
    second_space = (const unsigned char *)memchr(first_space + 1, ' ', (size_t)(tab - first_space - 1));
    if (!second_space) goto malformed;
    if (staged) {
      object = first_space + 1;
      object_len = (size_t)(second_space - object);
      if (tab - second_space != 2 || second_space[1] != '0') {
        result_fail(r, "Git index contains unmerged or malformed entries");
        return 0;
      }
    } else {
      size_t type_len = (size_t)(second_space - first_space - 1);
      object = second_space + 1;
      object_len = (size_t)(tab - object);
      if (!((type_len == 4 && !memcmp(first_space + 1, "blob", 4)) ||
            (type_len == 4 && !memcmp(first_space + 1, "tree", 4)) ||
            (type_len == 6 && !memcmp(first_space + 1, "commit", 6)))) goto malformed;
    }
    if (!oid_valid(object, object_len)) goto malformed;
    path_len = (size_t)(nul - tab - 1);
    if (path_len == wanted_len && !memcmp(tab + 1, full, wanted_len)) {
      if (found) goto malformed;
      found = 1;
      kind = mode_kind(mode);
      memcpy(oid, object, object_len);
      oid[object_len] = '\0';
    } else if (!found && path_len > wanted_len &&
               !memcmp(tab + 1, full, wanted_len) && tab[1 + wanted_len] == '/') {
      kind = 2; /* Index directories are represented by their descendants. */
    }
    start = (size_t)(nul - b->data) + 1;
  }
  return kind;
malformed:
  result_fail(r, "Git returned malformed index/tree metadata");
  return 0;
}

static void git_source(struct moonlint_result *r, const char *root, const char *rel,
                        int staged, int want_blob) {
  struct git_context c;
  struct git_output output;
  char *full = NULL;
  char *head = NULL;
  char oid[65] = {0};
  int kind;
  const char *index_args[] = {"ls-files", "--stage", "--full-name", "-z", "--", NULL, NULL};
  const char *tree_args[] = {"ls-tree", "--full-tree", "-z", NULL, "--", NULL, NULL};
  const char *blob_args[] = {"cat-file", "blob", oid, NULL};
  if (!git_context_open(r, root, &c)) return;
  full = git_full_path(r, &c, rel);
  if (!full) goto done;
  if (staged) {
    if (!git_reject_unmerged(r, &c)) goto done;
    index_args[5] = full;
    if (!git_run(r, c.top, "ls-files --stage", index_args, &output)) goto done;
  } else {
    head = git_commit(r, &c, "HEAD");
    if (!head) goto done;
    tree_args[3] = head;
    tree_args[5] = full;
    if (!git_run(r, c.top, "ls-tree HEAD", tree_args, &output)) goto done;
  }
  kind = git_entry(r, &output.out, full, staged, oid);
  git_output_free(&output);
  if (r->status) goto done;
  r->value = kind;
  if (!want_blob) goto done;
  if (kind != 1) {
    result_fail(r, "Git source is missing or not a regular file (kind %d): %s", kind, rel);
    goto done;
  }
  if (!git_run(r, c.top, "cat-file blob", blob_args, &output)) goto done;
  r->out = output.out;
  memset(&output.out, 0, sizeof(output.out));
  git_output_free(&output);
done:
  free(full);
  free(head);
  git_context_free(&c);
}

static void source_kind(struct moonlint_result *r, const char *path) {
  struct stat st;
  size_t n = strlen(path);
  char *clean;
  /* lstat("symlink/") otherwise follows the final link on POSIX systems. */
  while (n > 1 && path[n - 1] == '/') n--;
  clean = copy_string(r, path, n);
  if (!clean) return;
  if (lstat(clean, &st) < 0) {
    if (errno == ENOENT || errno == ENOTDIR) r->value = 0;
    else result_fail(r, "lstat(%s): %s", clean, strerror(errno));
  } else if (S_ISREG(st.st_mode)) r->value = 1;
  else if (S_ISDIR(st.st_mode)) r->value = 2;
  else r->value = 3;
  free(clean);
}

static void read_stdin(struct moonlint_result *r) {
  for (;;) {
    unsigned char chunk[16384];
    size_t n;
    errno = 0;
    n = fread(chunk, 1, sizeof(chunk), stdin);
    if (n && !buffer_append(&r->out, chunk, n)) {
      result_fail(r, "stdin is too large or memory is exhausted: %s", strerror(errno));
      return;
    }
    if (ferror(stdin)) {
      int saved = errno;
      if (saved == EINTR) {
        clearerr(stdin);
        continue;
      }
      result_fail(r, "read stdin: %s", strerror(saved ? saved : EIO));
      return;
    }
    if (feof(stdin)) return;
  }
}

static void atomic_write(struct moonlint_result *r, const char *path,
                          const unsigned char *data, size_t len) {
  const char *slash = strrchr(path, '/');
  const char *base = slash ? slash + 1 : path;
  char *parent = NULL;
  char *directory = NULL;
  char *target = NULL;
  char *temporary = NULL;
  struct stat st;
  int exists = 0;
  int fd = -1;
  int created = 0;
  size_t pos = 0;
  size_t n;
  if (!base[0] || !strcmp(base, ".") || !strcmp(base, "..")) {
    result_fail(r, "atomic-write path must name a file: %s", path);
    return;
  }
  parent = slash ? copy_string(r, path, slash == path ? 1 : (size_t)(slash - path))
                 : copy_string(r, ".", 1);
  if (!parent) goto done;
  directory = resolve_directory(r, parent);
  if (!directory) goto done;
  n = strlen(directory) + strlen(base) + 2;
  target = (char *)malloc(n);
  if (!target) {
    result_fail(r, "atomic write: out of memory");
    goto done;
  }
  snprintf(target, n, "%s/%s", directory, base);
  if (lstat(target, &st) == 0) {
    exists = 1;
    if (!S_ISREG(st.st_mode)) {
      result_fail(r, "atomic-write target is not a regular file: %s", target);
      goto done;
    }
  } else if (errno != ENOENT) {
    result_fail(r, "lstat atomic-write target %s: %s", target, strerror(errno));
    goto done;
  }
  n = strlen(directory) + sizeof("/.moonlint-baseline-XXXXXX");
  temporary = (char *)malloc(n);
  if (!temporary) {
    result_fail(r, "atomic write: out of memory");
    goto done;
  }
  snprintf(temporary, n, "%s/.moonlint-baseline-XXXXXX", directory);
  /* Both paths are verified absolute, and only this mkstemp-created path is
     ever unlinked. rename never follows or opens the existing target. */
  if (target[0] != '/' || temporary[0] != '/') {
    result_fail(r, "atomic write requires an absolute canonical parent");
    goto done;
  }
  fd = mkstemp(temporary);
  if (fd < 0) {
    result_fail(r, "mkstemp in %s: %s", directory, strerror(errno));
    goto done;
  }
  created = 1;
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 ||
      (exists && fchmod(fd, st.st_mode & 0777) < 0)) {
    result_fail(r, "prepare atomic-write temporary: %s", strerror(errno));
    goto done;
  }
  while (pos < len) {
    ssize_t written = write(fd, data + pos, len - pos);
    if (written > 0) pos += (size_t)written;
    else if (written < 0 && errno == EINTR) continue;
    else {
      result_fail(r, "write atomic-write temporary: %s", strerror(written < 0 ? errno : EIO));
      goto done;
    }
  }
  while (fsync(fd) < 0) {
    if (errno == EINTR) continue;
    result_fail(r, "fsync atomic-write temporary: %s", strerror(errno));
    goto done;
  }
  {
    int closed = close(fd);
    fd = -1; /* Never retry close(EINTR), which may already have closed it. */
    if (closed < 0) {
      result_fail(r, "close atomic-write temporary: %s", strerror(errno));
      goto done;
    }
  }
  if (rename(temporary, target) < 0) {
    result_fail(r, "rename atomic-write temporary to %s: %s", target, strerror(errno));
    goto done;
  }
  created = 0;
done:
  if (fd >= 0) close(fd);
  if (created) (void)unlink(temporary);
  free(parent);
  free(directory);
  free(target);
  free(temporary);
}

#endif /* MOONLINT_POSIX */

/* #external raw result handle. Inputs are borrowed for this call only. */
MOONBIT_FFI_EXPORT void *moonlint_native_request(int32_t operation,
                                                const unsigned char *first,
                                                const unsigned char *second,
                                                int32_t second_len,
                                                int32_t flag) {
  struct moonlint_result *r = (struct moonlint_result *)calloc(1, sizeof(*r));
  if (!r) return NULL;
#if MOONLINT_POSIX
  switch (operation) {
    case 0: {
      char *root = resolve_directory(r, (const char *)first);
      if (root) {
        if (!buffer_append(&r->out, root, strlen(root)))
          result_fail(r, "canonical root is too large or memory is exhausted");
        free(root);
      }
      break;
    }
    case 1: source_kind(r, (const char *)first); break;
    case 2: read_stdin(r); break;
    case 3: git_changed(r, (const char *)first, (const char *)second); break;
    case 4: git_staged(r, (const char *)first); break;
    case 5: git_source(r, (const char *)first, (const char *)second, flag != 0, 1); break;
    case 6: git_source(r, (const char *)first, (const char *)second, flag != 0, 0); break;
    case 7:
      if (second_len < 0) result_fail(r, "negative atomic-write content length");
      else atomic_write(r, (const char *)first, second, (size_t)second_len);
      break;
    default: result_fail(r, "unsupported native operation"); break;
  }
#else
  (void)operation;
  (void)first;
  (void)second;
  (void)second_len;
  (void)flag;
  result_fail(r, "native filesystem/Git bridge is unsupported: use native macOS or Linux");
#endif
  return r;
}

MOONBIT_FFI_EXPORT int32_t moonlint_native_result_is_null(void *result) {
  return result == NULL;
}

MOONBIT_FFI_EXPORT int32_t moonlint_native_result_status(void *result) {
  return ((struct moonlint_result *)result)->status;
}

MOONBIT_FFI_EXPORT int32_t moonlint_native_result_value(void *result) {
  return ((struct moonlint_result *)result)->value;
}

static moonbit_bytes_t buffer_to_bytes(const struct moonlint_buffer *buffer) {
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)buffer->len, 0);
  if (buffer->len) memcpy(bytes, buffer->data, buffer->len);
  return bytes;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonlint_native_result_bytes(void *result) {
  return buffer_to_bytes(&((struct moonlint_result *)result)->out);
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonlint_native_result_error(void *result) {
  struct moonlint_result *r = (struct moonlint_result *)result;
  if (!r->error.len) {
    const char *fallback = "native operation failed (out of memory)";
    moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)strlen(fallback), 0);
    memcpy(bytes, fallback, strlen(fallback));
    return bytes;
  }
  return buffer_to_bytes(&r->error);
}

MOONBIT_FFI_EXPORT void moonlint_native_result_free(void *result) {
  struct moonlint_result *r = (struct moonlint_result *)result;
  if (!r) return;
  buffer_free(&r->out);
  buffer_free(&r->error);
  free(r);
}

#ifdef __cplusplus
}
#endif
