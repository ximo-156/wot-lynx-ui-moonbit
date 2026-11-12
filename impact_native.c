/* MoonImpact's fixed-argv native operations. No shell command API. */
#if !defined(_WIN32)
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
#include <time.h>
#ifndef MOONIMPACT_STANDALONE
#include "moonbit.h"
#else
#define MOONBIT_FFI_EXPORT
#endif

#if defined(__APPLE__) || defined(__linux__)
#define IMPACT_POSIX 1
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
#else
#define IMPACT_POSIX 0
#endif

struct impact_buffer {
  unsigned char *data;
  size_t len;
  size_t cap;
};

struct impact_result {
  int status;
  int value;
  struct impact_buffer out;
  char *error;
};

static void impact_fail(struct impact_result *r, const char *format, ...) {
  va_list args, copy;
  int n;
  if (r->status) return;
  r->status = 1;
  va_start(args, format);
  va_copy(copy, args);
  n = vsnprintf(NULL, 0, format, copy);
  va_end(copy);
  if (n >= 0 && n < INT32_MAX) {
    r->error = (char *)malloc((size_t)n + 1);
    if (r->error) vsnprintf(r->error, (size_t)n + 1, format, args);
  }
  va_end(args);
}

static int impact_append(struct impact_buffer *b, const void *data, size_t n) {
  size_t wanted, cap;
  unsigned char *next;
  /* A huge Git listing must fail explicitly, never silently truncate paths. */
  const size_t limit = 64U * 1024U * 1024U;
  if (n > limit || b->len > limit - n) { errno = EOVERFLOW; return 0; }
  wanted = b->len + n;
  if (wanted > b->cap) {
    cap = b->cap ? b->cap : 4096;
    while (cap < wanted) cap *= 2;
    next = (unsigned char *)realloc(b->data, cap);
    if (!next) return 0;
    b->data = next;
    b->cap = cap;
  }
  if (n) memcpy(b->data + b->len, data, n);
  b->len = wanted;
  return 1;
}

#if IMPACT_POSIX
static int impact_write_all(int fd, const void *data, size_t length) {
  const unsigned char *p = (const unsigned char *)data;
  while (length) {
    ssize_t n = write(fd, p, length);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return 0;
    p += (size_t)n;
    length -= (size_t)n;
  }
  return 1;
}

static int impact_pipe(int p[2]) {
  int i;
  p[0] = p[1] = -1;
  if (pipe(p) < 0) return 0;
  for (i = 0; i < 2; ++i) {
    if (p[i] < 3) {
      int moved = fcntl(p[i], F_DUPFD, 3);
      if (moved < 0) goto failed;
      close(p[i]);
      p[i] = moved;
    }
    if (fcntl(p[i], F_SETFD, FD_CLOEXEC) < 0) goto failed;
  }
  return 1;
failed:
  if (p[0] >= 0) close(p[0]);
  if (p[1] >= 0) close(p[1]);
  p[0] = p[1] = -1;
  return 0;
}

static int64_t impact_millis(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t) < 0) return -1;
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static char *impact_join(const char *dir, const char *name) {
  size_t a = strlen(dir), b = strlen(name);
  char *p;
  if (a > (size_t)INT32_MAX - 2 || b > (size_t)INT32_MAX - a - 2) {
    errno = EOVERFLOW; return NULL;
  }
  p = (char *)malloc(a + b + 2);
  if (p) { memcpy(p, dir, a); p[a] = '/'; memcpy(p + a + 1, name, b + 1); }
  return p;
}

static char *impact_root(struct impact_result *r, const char *path) {
  char *root = realpath(path, NULL);
  struct stat st;
  if (!root) { impact_fail(r, "cannot resolve root: %s", strerror(errno)); return NULL; }
  if (stat(root, &st) < 0 || !S_ISDIR(st.st_mode)) {
    impact_fail(r, "root must be an existing directory"); free(root); return NULL;
  }
  return root;
}

/* Resolve PATH explicitly then execve, never execvp's ENOEXEC shell fallback. */
static char *impact_program(struct impact_result *r, const char *root, const char *name) {
  const char *path = getenv("PATH");
  const char *part, *end;
  if (!path) path = "/usr/bin:/bin";
  part = path;
  for (;;) {
    char *dir, *candidate, *absolute;
    size_t n;
    end = strchr(part, ':');
    n = end ? (size_t)(end - part) : strlen(part);
    dir = (char *)malloc(n + 1);
    if (!dir) { impact_fail(r, "out of memory resolving executable"); return NULL; }
    memcpy(dir, part, n); dir[n] = 0;
    candidate = impact_join(n ? dir : ".", name);
    free(dir);
    if (!candidate) { impact_fail(r, "out of memory resolving executable"); return NULL; }
    absolute = candidate[0] == '/' ? candidate : impact_join(root, candidate);
    if (absolute != candidate) free(candidate);
    if (!absolute) { impact_fail(r, "out of memory resolving executable"); return NULL; }
    if (access(absolute, X_OK) == 0) {
      struct stat st;
      if (stat(absolute, &st) == 0 && S_ISREG(st.st_mode)) return absolute;
    }
    free(absolute);
    if (!end) break;
    part = end + 1;
  }
  impact_fail(r, "cannot start %s: executable not found in PATH", name);
  return NULL;
}

static char **impact_git_env(struct impact_result *r) {
  size_t n = 0, used = 0, i;
  char **env;
  static const char *extra[] = {
    "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
    "GIT_CONFIG_SYSTEM=/dev/null", "GIT_ATTR_NOSYSTEM=1",
    "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0", "GIT_NO_LAZY_FETCH=1",
    "GIT_LITERAL_PATHSPECS=1", "GIT_PAGER=cat", NULL
  };
  while (environ[n]) ++n;
  env = (char **)calloc(n + 12, sizeof(char *));
  if (!env) { impact_fail(r, "out of memory constructing Git environment"); return NULL; }
  for (i = 0; i < n; ++i) {
    if (strncmp(environ[i], "GIT_", 4) != 0 && strncmp(environ[i], "PAGER=", 6) != 0)
      env[used++] = environ[i];
  }
  for (i = 0; extra[i]; ++i) env[used++] = (char *)extra[i];
  return env;
}

struct impact_child_error { int stage; int number; };

/* For Git, collect stdout and stderr separately. For --run, stream both to
 * stderr so the parent's JSON/HTML stdout remains a complete plan document. */
static int impact_process(struct impact_result *r, const char *root,
                          char *const argv[], int is_git, int stream,
                          int timeout_ms, struct impact_buffer *out,
                          struct impact_buffer *err) {
  int po[2] = {-1, -1}, pe[2] = {-1, -1}, px[2] = {-1, -1};
  int null_fd = -1, status = 0, exited = 0, open_count = 3, code = -1;
  int fds[3], index;
  int64_t started, now;
  pid_t pid = -1;
  char *program = NULL;
  char **env = NULL;
  struct impact_child_error child_error = {0, 0};
  size_t child_bytes = 0;
  program = impact_program(r, root, argv[0]);
  if (!program) goto cleanup;
  env = is_git ? impact_git_env(r) : environ;
  if (!env) goto cleanup;
  started = impact_millis();
  if (started < 0) { impact_fail(r, "monotonic clock unavailable"); goto cleanup; }
  if (!impact_pipe(po) || !impact_pipe(pe) || !impact_pipe(px)) {
    impact_fail(r, "cannot create child pipes: %s", strerror(errno)); goto cleanup;
  }
  null_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
  if (null_fd < 0) { impact_fail(r, "cannot open child stdin: %s", strerror(errno)); goto cleanup; }
  if (null_fd < 3) {
    int moved = fcntl(null_fd, F_DUPFD, 3);
    if (moved < 0) { impact_fail(r, "cannot isolate child stdin: %s", strerror(errno)); goto cleanup; }
    close(null_fd); null_fd = moved;
    if (fcntl(null_fd, F_SETFD, FD_CLOEXEC) < 0) { impact_fail(r, "cannot protect child stdin: %s", strerror(errno)); goto cleanup; }
  }
  pid = fork();
  if (pid < 0) { impact_fail(r, "cannot fork child: %s", strerror(errno)); goto cleanup; }
  if (pid == 0) {
    struct impact_child_error failure = {1, 0};
    close(po[0]); close(pe[0]); close(px[0]);
    if (setpgid(0, 0) < 0) goto child_fail;
    failure.stage = 2;
    if (chdir(root) < 0) goto child_fail;
    failure.stage = 3;
    if (dup2(null_fd, STDIN_FILENO) < 0 || dup2(po[1], STDOUT_FILENO) < 0 ||
        dup2(pe[1], STDERR_FILENO) < 0) goto child_fail;
    if (null_fd > 2) close(null_fd);
    close(po[1]); close(pe[1]);
    failure.stage = 4;
    execve(program, argv, env);
child_fail:
    failure.number = errno;
    (void)impact_write_all(px[1], &failure, sizeof(failure));
    _exit(127);
  }
  /* The child also sets its group, so it cannot launch descendants before
   * group creation; the parent call closes the usual timeout race. */
  if (setpgid(pid, pid) < 0 && errno != EACCES && errno != ESRCH) {
    impact_fail(r, "cannot isolate child process group: %s", strerror(errno));
    goto terminate;
  }
  close(po[1]); po[1] = -1; close(pe[1]); pe[1] = -1;
  close(px[1]); px[1] = -1; close(null_fd); null_fd = -1;
  fds[0] = po[0]; fds[1] = pe[0]; fds[2] = px[0];
  for (index = 0; index < 3; ++index) {
    int flags = fcntl(fds[index], F_GETFL, 0);
    if (flags < 0 || fcntl(fds[index], F_SETFL, flags | O_NONBLOCK) < 0) {
      impact_fail(r, "cannot configure child pipes: %s", strerror(errno)); goto terminate;
    }
  }
  while (!exited || open_count) {
    struct pollfd polls[3];
    int remaining, ready;
    now = impact_millis();
    if (now < 0 || now - started >= timeout_ms) {
      impact_fail(r, "%s timed out after %d ms", argv[0], timeout_ms); goto terminate;
    }
    remaining = timeout_ms - (int)(now - started);
    for (index = 0; index < 3; ++index) {
      polls[index].fd = fds[index]; polls[index].events = POLLIN; polls[index].revents = 0;
    }
    ready = poll(polls, 3, remaining < 50 ? remaining : 50);
    if (ready < 0 && errno != EINTR) {
      impact_fail(r, "cannot poll child output: %s", strerror(errno)); goto terminate;
    }
    for (index = 0; index < 3; ++index) {
      if (fds[index] < 0 || !(polls[index].revents & (POLLIN | POLLHUP | POLLERR))) continue;
      for (;;) {
        unsigned char chunk[8192];
        ssize_t got = read(fds[index], chunk, sizeof(chunk));
        if (got < 0 && errno == EINTR) continue;
        if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (got < 0) { impact_fail(r, "cannot read child output: %s", strerror(errno)); goto terminate; }
        if (got == 0) { fds[index] = -1; --open_count; break; }
        if (index == 2) {
          if ((size_t)got > sizeof(child_error) - child_bytes) {
            impact_fail(r, "invalid child startup response"); goto terminate;
          }
          memcpy((unsigned char *)&child_error + child_bytes, chunk, (size_t)got);
          child_bytes += (size_t)got;
        } else if (stream) {
          if (!impact_write_all(STDERR_FILENO, chunk, (size_t)got)) {
            impact_fail(r, "cannot forward test output: %s", strerror(errno)); goto terminate;
          }
        } else if (!impact_append(index ? err : out, chunk, (size_t)got)) {
          impact_fail(r, "child output exceeds memory/size limit"); goto terminate;
        }
        /* Bound work per poll, including a child that writes continuously. */
        break;
      }
    }
    if (!exited) {
      pid_t got = waitpid(pid, &status, WNOHANG);
      if (got == pid) exited = 1;
      else if (got < 0 && errno != EINTR) {
        impact_fail(r, "cannot wait for child: %s", strerror(errno)); goto terminate;
      }
    }
  }
  if (child_bytes) {
    if (child_bytes != sizeof(child_error)) impact_fail(r, "incomplete child startup response");
    else impact_fail(r, "cannot start %s (stage %d): %s", argv[0], child_error.stage, strerror(child_error.number));
    goto cleanup;
  }
  if (WIFEXITED(status)) code = WEXITSTATUS(status);
  else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
  else impact_fail(r, "child exited without an exit status");
  goto cleanup;
terminate:
  if (pid > 0) {
    (void)kill(-pid, SIGKILL);
    (void)kill(pid, SIGKILL);
    if (!exited) while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  }
cleanup:
  if (po[0] >= 0) close(po[0]);
  if (po[1] >= 0) close(po[1]);
  if (pe[0] >= 0) close(pe[0]);
  if (pe[1] >= 0) close(pe[1]);
  if (px[0] >= 0) close(px[0]);
  if (px[1] >= 0) close(px[1]);
  if (null_fd >= 0) close(null_fd);
  free(program);
  if (is_git) free(env);
  return code;
}

static int impact_git(struct impact_result *r, const char *root,
                      const char *const args[], struct impact_buffer *out) {
  char *argv[48];
  struct impact_buffer err = {0};
  size_t count = 0, i;
  int code;
  const char *prefix[] = {"git", "--no-pager", "--no-replace-objects",
    "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
    "-c", "diff.external=", "-c", "core.pager=cat", NULL};
  for (i = 0; prefix[i]; ++i) argv[count++] = (char *)prefix[i];
  for (i = 0; args[i]; ++i) {
    if (count + 1 >= sizeof(argv) / sizeof(argv[0])) { impact_fail(r, "too many internal Git arguments"); return 0; }
    argv[count++] = (char *)args[i];
  }
  argv[count] = NULL;
  code = impact_process(r, root, argv, 1, 0, 30000, out, &err);
  /* `config --get-regexp` returns 1 when the requested keys do not exist. */
  if (!r->status && code != 0 && !(code == 1 && !strcmp(args[0], "config"))) {
    impact_fail(r, "git %s exited %d: %.*s", args[0], code,
                (int)(err.len < 4096 ? err.len : 4096), err.data ? (char *)err.data : "");
  }
  free(err.data);
  return !r->status;
}

static void impact_changes(struct impact_result *r, const char *path, const char *base) {
  char *root = NULL, *reported = NULL, *top = NULL, *expression = NULL, *oid = NULL;
  struct impact_buffer output = {0};
  size_t n, i;
  const char *show[] = {"rev-parse", "--show-toplevel", NULL};
  const char *filters[] = {"config", "--includes", "--get-regexp", "^filter\\..*\\.(clean|process)$", NULL};
  const char *unmerged[] = {"ls-files", "--unmerged", "-z", NULL};
  const char *others[] = {"ls-files", "--others", "--exclude-standard", "-z", NULL};
  if (!base[0] || base[0] == '-') { impact_fail(r, "base must be a nonempty Git commit reference, not an option"); return; }
  root = impact_root(r, path);
  if (!root || !impact_git(r, root, show, &output)) goto done;
  n = output.len;
  if (n && output.data[n - 1] == '\n') --n;
  reported = (char *)malloc(n + 1);
  if (!reported) { impact_fail(r, "out of memory reading repository root"); goto done; }
  memcpy(reported, output.data, n); reported[n] = 0;
  top = realpath(reported, NULL);
  if (!top || strcmp(top, root) != 0) {
    impact_fail(r, "Git change input requires the repository root directory (subdirectories are not supported)"); goto done;
  }
  /* Git's clean/process filters can execute repository-configured commands
   * even for --name-only. Fail closed rather than invoking those implicitly. */
  output.len = 0;
  if (!impact_git(r, root, filters, &output)) goto done;
  if (output.len) {
    impact_fail(r, "repository Git clean/process filters are unsupported for safe change discovery; use explicit --file inputs"); goto done;
  }
  output.len = 0;
  if (!impact_git(r, root, unmerged, &output)) goto done;
  if (output.len) { impact_fail(r, "Git index has unresolved conflicts; resolve them before planning"); goto done; }
  expression = (char *)malloc(strlen(base) + 10);
  if (!expression) { impact_fail(r, "out of memory reading Git reference"); goto done; }
  snprintf(expression, strlen(base) + 10, "%s^{commit}", base);
  {
    const char *verify[] = {"rev-parse", "--verify", "--end-of-options", expression, NULL};
    output.len = 0;
    if (!impact_git(r, root, verify, &output)) goto done;
  }
  n = output.len;
  if (n && output.data[n - 1] == '\n') --n;
  if (n != 40 && n != 64) { impact_fail(r, "Git did not return a commit object id"); goto done; }
  for (i = 0; i < n; ++i) {
    if (!((output.data[i] >= '0' && output.data[i] <= '9') || (output.data[i] >= 'a' && output.data[i] <= 'f'))) {
      impact_fail(r, "invalid Git commit object id"); goto done;
    }
  }
  oid = (char *)malloc(n + 1);
  if (!oid) { impact_fail(r, "out of memory reading commit id"); goto done; }
  memcpy(oid, output.data, n); oid[n] = 0;
  {
    const char *diff[] = {"diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", "--no-renames", "--ignore-submodules=none", oid, "--", NULL};
    if (!impact_git(r, root, diff, &r->out)) goto done;
  }
  output.len = 0;
  if (impact_git(r, root, others, &output) && !impact_append(&r->out, output.data, output.len))
    impact_fail(r, "Git path listing exceeds size limit");
done:
  free(root); free(reported); free(top); free(expression); free(oid); free(output.data);
}

static int impact_safe_test(const unsigned char *path, size_t length) {
  size_t start = 0, i;
  if (!length || path[0] == '/' || path[0] == '\\' ||
      (length >= 2 && path[1] == ':')) return 0;
  for (i = 0; i <= length; ++i) {
    if (i == length || path[i] == '/' || path[i] == '\\') {
      if (i == start || (i - start == 1 && path[start] == '.') ||
          (i - start == 2 && path[start] == '.' && path[start + 1] == '.')) return 0;
      start = i + 1;
    }
  }
  return 1;
}

static void impact_vitest(struct impact_result *r, const char *path,
                          const unsigned char *paths, size_t length,
                          int full, int timeout_ms) {
  size_t count = 0, i, start = 0, slot = 4;
  char **argv = NULL, *root = NULL;
  struct impact_buffer ignored_out = {0}, ignored_err = {0};
  if (timeout_ms < 1) { impact_fail(r, "test timeout must be positive"); return; }
  if (!full) {
    for (i = 0; i < length; ++i) if (!paths[i]) ++count;
    if (!count || !length || paths[length - 1] != 0) {
      impact_fail(r, "related test execution requires a nonempty NUL-terminated test selection"); return;
    }
  }
  root = impact_root(r, path);
  if (!root) return;
  argv = (char **)calloc(count + 5, sizeof(char *));
  if (!argv) { impact_fail(r, "out of memory preparing test arguments"); goto done; }
  argv[0] = "pnpm"; argv[1] = "exec"; argv[2] = "vitest"; argv[3] = "run";
  for (i = 0; !full && i < length; ++i) {
    if (paths[i] == 0) {
      size_t n = i - start;
      if (!impact_safe_test(paths + start, n)) { impact_fail(r, "test paths must be normalized root-relative paths without .. or empty segments"); goto done; }
      argv[slot] = (char *)malloc(n + 3);
      if (!argv[slot]) { impact_fail(r, "out of memory preparing test arguments"); goto done; }
      memcpy(argv[slot], "./", 2); memcpy(argv[slot] + 2, paths + start, n); argv[slot][n + 2] = 0;
      ++slot; start = i + 1;
    }
  }
  r->value = impact_process(r, root, argv, 0, 1, timeout_ms, &ignored_out, &ignored_err);
done:
  if (argv) { for (i = 4; i < slot; ++i) free(argv[i]); free(argv); }
  free(root); free(ignored_out.data); free(ignored_err.data);
}

/* Run `moon test <package paths>` in root. Package paths are root-relative
 * directories, each passed as its own argv element, never shell text. Child
 * output goes to stderr so a JSON/HTML plan stays parseable. */
static void impact_moon_test(struct impact_result *r, const char *path,
                             const unsigned char *paths, size_t length,
                             int timeout_ms) {
  size_t count = 0, i, start = 0, slot = 2;
  char **argv = NULL, *root = NULL;
  struct impact_buffer ignored_out = {0}, ignored_err = {0};
  if (timeout_ms < 1) { impact_fail(r, "test timeout must be positive"); return; }
  for (i = 0; i < length; ++i) if (!paths[i]) ++count;
  if (!count || !length || paths[length - 1] != 0) {
    impact_fail(r, "package selection requires a nonempty NUL-terminated path list"); return;
  }
  root = impact_root(r, path);
  if (!root) return;
  argv = (char **)calloc(count + 3, sizeof(char *));
  if (!argv) { impact_fail(r, "out of memory preparing test arguments"); goto done; }
  argv[0] = "moon"; argv[1] = "test";
  for (i = 0; i < length; ++i) {
    if (paths[i] == 0) {
      size_t n = i - start;
      if (n == 0) {
        /* The module root package is addressed as the current directory. */
        argv[slot] = (char *)malloc(2);
        if (!argv[slot]) { impact_fail(r, "out of memory preparing test arguments"); goto done; }
        memcpy(argv[slot], ".", 1); argv[slot][1] = 0;
      } else {
        if (!impact_safe_test(paths + start, n)) { impact_fail(r, "package paths must be normalized root-relative paths without .. or empty segments"); goto done; }
        argv[slot] = (char *)malloc(n + 3);
        if (!argv[slot]) { impact_fail(r, "out of memory preparing test arguments"); goto done; }
        memcpy(argv[slot], "./", 2); memcpy(argv[slot] + 2, paths + start, n); argv[slot][n + 2] = 0;
      }
      ++slot; start = i + 1;
    }
  }
  r->value = impact_process(r, root, argv, 0, 1, timeout_ms, &ignored_out, &ignored_err);
done:
  if (argv) { for (i = 2; i < slot; ++i) free(argv[i]); free(argv); }
  free(root); free(ignored_out.data); free(ignored_err.data);
}

/* Atomically publish without replacing even a concurrently-created file. */
static void impact_report(struct impact_result *r, const char *path,
                          const unsigned char *content, size_t length) {
  char *copy = NULL, *directory = NULL, *target = NULL, *temporary = NULL;
  const char *name;
  char *slash;
  int fd = -1, temporary_created = 0;
  if (!path[0]) { impact_fail(r, "report path must not be empty"); return; }
  copy = strdup(path);
  if (!copy) { impact_fail(r, "out of memory preparing report path"); goto done; }
  slash = strrchr(copy, '/');
  if (slash) { *slash = 0; name = slash + 1; directory = realpath(copy[0] ? copy : "/", NULL); }
  else { name = copy; directory = realpath(".", NULL); }
  if (!directory || !name[0] || !strcmp(name, ".") || !strcmp(name, "..")) {
    impact_fail(r, "report parent must exist and report path must name a new file"); goto done;
  }
  target = impact_join(directory, name);
  temporary = impact_join(directory, ".moonimpact-report-XXXXXX");
  if (!target || !temporary) { impact_fail(r, "out of memory preparing report path"); goto done; }
  fd = mkstemp(temporary);
  if (fd < 0) { impact_fail(r, "cannot create report temporary file: %s", strerror(errno)); goto done; }
  temporary_created = 1;
  if (!impact_write_all(fd, content, length) || fsync(fd) < 0) {
    impact_fail(r, "cannot write report: %s", strerror(errno)); goto done;
  }
  if (close(fd) < 0) { fd = -1; impact_fail(r, "cannot close report: %s", strerror(errno)); goto done; }
  fd = -1;
  if (link(temporary, target) < 0) {
    if (errno == EEXIST) impact_fail(r, "report path already exists; refusing to overwrite: %s", path);
    else impact_fail(r, "cannot publish report: %s", strerror(errno));
    goto done;
  }
done:
  if (fd >= 0) close(fd);
  /* temporary is an absolute path returned by our same-directory mkstemp,
   * never an unchecked caller-controlled delete target. */
  if (temporary_created && temporary && temporary[0] == '/')
    (void)unlink(temporary);
  free(copy); free(directory); free(target); free(temporary);
}
#endif

MOONBIT_FFI_EXPORT void *moonimpact_native_request(int32_t operation,
    const unsigned char *first, const unsigned char *second, int32_t length, int32_t flag) {
  struct impact_result *r = (struct impact_result *)calloc(1, sizeof(*r));
  if (!r) return NULL;
#if IMPACT_POSIX
  if (!first || length < 0 || (!second && length)) { impact_fail(r, "invalid native request"); return r; }
  if (operation == 0) {
    if (length < 1 || second[length - 1] != 0 || memchr(second, 0, (size_t)length - 1))
      impact_fail(r, "invalid Git reference encoding");
    else impact_changes(r, (const char *)first, (const char *)second);
  } else if (operation == 1 || operation == 2) {
    impact_vitest(r, (const char *)first, second, (size_t)length, operation == 2, flag);
  } else if (operation == 3) {
    impact_report(r, (const char *)first, second, (size_t)length);
  } else if (operation == 4) {
    impact_moon_test(r, (const char *)first, second, (size_t)length, flag);
  } else impact_fail(r, "unknown MoonImpact native operation");
#else
  (void)operation; (void)first; (void)second; (void)length; (void)flag;
  impact_fail(r, "MoonImpact native operations require macOS or Linux");
#endif
  return r;
}

MOONBIT_FFI_EXPORT int32_t moonimpact_native_result_is_null(void *r) { return r == NULL; }
MOONBIT_FFI_EXPORT int32_t moonimpact_native_result_status(void *r) { return ((struct impact_result *)r)->status; }
MOONBIT_FFI_EXPORT int32_t moonimpact_native_result_value(void *r) { return ((struct impact_result *)r)->value; }
#ifndef MOONIMPACT_STANDALONE
MOONBIT_FFI_EXPORT moonbit_bytes_t moonimpact_native_result_bytes(void *value) {
  struct impact_result *r = (struct impact_result *)value;
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)r->out.len, 0);
  if (r->out.len) memcpy(out, r->out.data, r->out.len);
  return out;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moonimpact_native_result_error(void *value) {
  struct impact_result *r = (struct impact_result *)value;
  const char *text = r->error ? r->error : "MoonImpact native operation failed (out of memory)";
  size_t n = strlen(text);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  if (n) memcpy(out, text, n);
  return out;
}
#endif
MOONBIT_FFI_EXPORT void moonimpact_native_result_free(void *value) {
  struct impact_result *r = (struct impact_result *)value;
  if (!r) return;
  free(r->out.data); free(r->error); free(r);
}
