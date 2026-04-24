// vm_exec_daemon.c — Lightweight exec bridge for NullClaw VM (RLM)
//
// Listens on a vsock port, executes commands via fork/exec,
// returns structured {stdout, stderr, exit_code} over the same connection.
//
// Protocol: length-prefixed JSON
//   Request:  [4 bytes big-endian length] [JSON payload]
//   Response: [4 bytes big-endian length] [JSON payload]
//
// Request JSON:  {"command":"...","cwd":"...","timeout":30}
// Response JSON: {"stdout":"...","stderr":"...","exit_code":0}
//
// Build (static, no deps): gcc -static -O2 -o vm-exec-daemon vm_exec_daemon.c

#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <linux/vm_sockets.h>
#include <sys/wait.h>
#include <sys/poll.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>

#define VSOCK_PORT 1234
#define MAX_REQUEST (256 * 1024)   // 256KB
#define MAX_OUTPUT  (512 * 1024)   // 512KB per stream

static volatile sig_atomic_t running = 1;

static void sigterm_handler(int sig) { (void)sig; running = 0; }

// ── I/O helpers ──────────────────────────────────────────────

static int read_exact(int fd, void *buf, size_t n) {
    size_t done = 0;
    while (done < n) {
        ssize_t r = read(fd, (char *)buf + done, n - done);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1;
        done += (size_t)r;
    }
    return 0;
}

static int write_all(int fd, const void *buf, size_t n) {
    size_t done = 0;
    while (done < n) {
        ssize_t w = write(fd, (const char *)buf + done, n - done);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        if (w == 0) return -1;
        done += (size_t)w;
    }
    return 0;
}

static int read_u32be(int fd, uint32_t *val) {
    uint8_t b[4];
    if (read_exact(fd, b, 4) < 0) return -1;
    *val = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
           ((uint32_t)b[2] << 8)  |  (uint32_t)b[3];
    return 0;
}

static int write_u32be(int fd, uint32_t val) {
    uint8_t b[4] = { val >> 24, val >> 16, val >> 8, val & 0xFF };
    return write_all(fd, b, 4);
}

// ── Minimal JSON helpers ─────────────────────────────────────

// Extract a JSON string value for key. Returns malloc'd unescaped string or NULL.
static char *json_get_string(const char *json, const char *key) {
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\"", key);

    const char *p = strstr(json, needle);
    if (!p) return NULL;
    p += strlen(needle);
    while (*p == ' ' || *p == '\t' || *p == ':') p++;
    if (*p != '"') return NULL;
    p++; // skip opening quote

    // Walk string, handling escapes
    size_t cap = 256;
    char *out = malloc(cap);
    if (!out) return NULL;
    size_t len = 0;

    while (*p && *p != '"') {
        if (len + 8 > cap) { cap *= 2; out = realloc(out, cap); if (!out) return NULL; }
        if (*p == '\\' && p[1]) {
            p++;
            switch (*p) {
                case 'n':  out[len++] = '\n'; break;
                case 't':  out[len++] = '\t'; break;
                case 'r':  out[len++] = '\r'; break;
                case '\\': out[len++] = '\\'; break;
                case '"':  out[len++] = '"';  break;
                case '/':  out[len++] = '/';  break;
                default:   out[len++] = *p;   break;
            }
        } else {
            out[len++] = *p;
        }
        p++;
    }
    out[len] = '\0';
    return out;
}

// Extract a JSON integer value for key. Returns default if not found.
static int json_get_int(const char *json, const char *key, int def) {
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return def;
    p += strlen(needle);
    while (*p == ' ' || *p == '\t' || *p == ':') p++;
    if (*p == '"') return def; // string, not int
    char *end;
    long v = strtol(p, &end, 10);
    return (end == p) ? def : (int)v;
}

// Escape a byte buffer for JSON string. Returns malloc'd string.
static char *json_escape(const char *src, size_t src_len) {
    // Worst case: every byte becomes \uXXXX (6 chars)
    char *out = malloc(src_len * 6 + 1);
    if (!out) return strdup("");
    size_t j = 0;
    for (size_t i = 0; i < src_len && j < src_len * 6; i++) {
        unsigned char c = (unsigned char)src[i];
        switch (c) {
            case '"':  out[j++] = '\\'; out[j++] = '"';  break;
            case '\\': out[j++] = '\\'; out[j++] = '\\'; break;
            case '\n': out[j++] = '\\'; out[j++] = 'n';  break;
            case '\r': out[j++] = '\\'; out[j++] = 'r';  break;
            case '\t': out[j++] = '\\'; out[j++] = 't';  break;
            case '\b': out[j++] = '\\'; out[j++] = 'b';  break;
            case '\f': out[j++] = '\\'; out[j++] = 'f';  break;
            default:
                if (c < 0x20) {
                    j += (size_t)snprintf(out + j, 7, "\\u%04x", c);
                } else {
                    out[j++] = c;
                }
                break;
        }
    }
    out[j] = '\0';
    return out;
}

// ── Command execution ────────────────────────────────────────

static int run_command(const char *command, const char *cwd, int timeout_sec,
                       char *out_buf, size_t *out_len,
                       char *err_buf, size_t *err_len) {
    int pout[2] = {-1, -1}, perr[2] = {-1, -1};

    if (pipe(pout) < 0 || pipe(perr) < 0) {
        *out_len = 0;
        *err_len = (size_t)snprintf(err_buf, MAX_OUTPUT, "pipe: %s", strerror(errno));
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(pout[0]); close(pout[1]); close(perr[0]); close(perr[1]);
        *out_len = 0;
        *err_len = (size_t)snprintf(err_buf, MAX_OUTPUT, "fork: %s", strerror(errno));
        return -1;
    }

    if (pid == 0) {
        // Child
        close(pout[0]); close(perr[0]);
        dup2(pout[1], STDOUT_FILENO);
        dup2(perr[1], STDERR_FILENO);
        close(pout[1]); close(perr[1]);

        if (cwd && cwd[0]) chdir(cwd);

        setenv("PATH", "/mnt/root/usr/bin:/mnt/root/sbin:/usr/sbin:/sbin:/bin:/usr/bin", 1);
        setenv("LD_LIBRARY_PATH", "/mnt/root/usr/lib:/mnt/root/lib", 1);
        setenv("HOME", "/root", 1);
        setenv("TERM", "dumb", 1);

        execl("/bin/sh", "sh", "-c", command, (char *)NULL);
        _exit(127);
    }

    // Parent
    close(pout[1]); close(perr[1]);
    fcntl(pout[0], F_SETFL, O_NONBLOCK);
    fcntl(perr[0], F_SETFL, O_NONBLOCK);

    *out_len = 0;
    *err_len = 0;
    time_t deadline = (timeout_sec > 0) ? time(NULL) + timeout_sec : 0;

    struct pollfd pfds[2] = {
        { .fd = pout[0], .events = POLLIN },
        { .fd = perr[0], .events = POLLIN },
    };

    for (;;) {
        int poll_ms = 500;
        if (deadline > 0) {
            int rem = (int)(deadline - time(NULL));
            if (rem <= 0) { kill(pid, SIGKILL); break; }
            poll_ms = rem * 1000;
        }

        int n = poll(pfds, 2, poll_ms);
        if (n < 0) { if (errno == EINTR) continue; break; }

        if (pfds[0].revents & POLLIN) {
            ssize_t r = read(pout[0], out_buf + *out_len, MAX_OUTPUT - *out_len - 1);
            if (r > 0) *out_len += (size_t)r; else pfds[0].fd = -1;
        }
        if (pfds[1].revents & POLLIN) {
            ssize_t r = read(perr[0], err_buf + *err_len, MAX_OUTPUT - *err_len - 1);
            if (r > 0) *err_len += (size_t)r; else pfds[1].fd = -1;
        }

        if (pfds[0].fd < 0 && pfds[1].fd < 0) break;
        if ((pfds[0].revents | pfds[1].revents) & (POLLHUP | POLLERR)) {
            // Drain remaining
            if (pfds[0].fd >= 0) {
                ssize_t r;
                while ((r = read(pout[0], out_buf + *out_len, MAX_OUTPUT - *out_len - 1)) > 0)
                    *out_len += (size_t)r;
            }
            if (pfds[1].fd >= 0) {
                ssize_t r;
                while ((r = read(perr[0], err_buf + *err_len, MAX_OUTPUT - *err_len - 1)) > 0)
                    *err_len += (size_t)r;
            }
            break;
        }
    }

    out_buf[*out_len] = '\0';
    err_buf[*err_len] = '\0';
    close(pout[0]);
    close(perr[0]);

    int status = 0;
    for (;;) {
        pid_t w = waitpid(pid, &status, 0);
        if (w == pid || (w < 0 && errno == ECHILD)) break;
        if (w < 0 && errno != EINTR) break;
    }

    return WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? -1 : -2);
}

// ── Client connection handler ────────────────────────────────

static void handle_client(int fd) {
    for (;;) {
        uint32_t req_len;
        if (read_u32be(fd, &req_len) < 0) break;
        if (req_len == 0 || req_len > MAX_REQUEST) break;

        char *req = malloc(req_len + 1);
        if (!req) break;
        if (read_exact(fd, req, req_len) < 0) { free(req); break; }
        req[req_len] = '\0';

        char *command = json_get_string(req, "command");
        char *cwd     = json_get_string(req, "cwd");
        int timeout   = json_get_int(req, "timeout", 30);

        if (!command || !*command) {
            const char *err = "{\"stdout\":\"\",\"stderr\":\"missing command\",\"exit_code\":-1}";
            uint32_t elen = (uint32_t)strlen(err);
            write_u32be(fd, elen);
            write_all(fd, err, elen);
            free(command); free(cwd); free(req);
            continue;
        }

        char out[MAX_OUTPUT], err[MAX_OUTPUT];
        size_t out_len = 0, err_len = 0;
        int code = run_command(command, cwd, timeout, out, &out_len, err, &err_len);

        char *esc_out = json_escape(out, out_len);
        char *esc_err = json_escape(err, err_len);

        // Build response JSON
        size_t rlen = (size_t)snprintf(NULL, 0,
            "{\"stdout\":\"%s\",\"stderr\":\"%s\",\"exit_code\":%d}",
            esc_out, esc_err, code);
        char *resp = malloc(rlen + 1);
        snprintf(resp, rlen + 1,
            "{\"stdout\":\"%s\",\"stderr\":\"%s\",\"exit_code\":%d}",
            esc_out, esc_err, code);

        write_u32be(fd, (uint32_t)rlen);
        write_all(fd, resp, rlen);

        free(esc_out); free(esc_err); free(resp);
        free(command); free(cwd); free(req);
    }
    close(fd);
}

// ── Main ─────────────────────────────────────────────────────

int main(int argc, char *argv[]) {
    int port = VSOCK_PORT;
    if (argc > 1) port = atoi(argv[1]);

    signal(SIGTERM, sigterm_handler);
    signal(SIGINT, sigterm_handler);
    signal(SIGCHLD, SIG_DFL);

    int s = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (s < 0) {
        fprintf(stderr, "vm-exec-daemon: socket(AF_VSOCK) failed: %s "
                        "(load vsock modules first)\n", strerror(errno));
        return 1;
    }

    int opt = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_vm addr = {
        .svm_family = AF_VSOCK,
        .svm_cid    = VMADDR_CID_ANY,
        .svm_port   = (unsigned int)port,
    };

    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "vm-exec-daemon: bind(port=%d) failed: %s\n",
                port, strerror(errno));
        close(s);
        return 1;
    }

    if (listen(s, 1) < 0) {
        fprintf(stderr, "vm-exec-daemon: listen failed: %s\n", strerror(errno));
        close(s);
        return 1;
    }

    // Signal ready — host waits for this on serial
    fprintf(stderr, "vm-exec-daemon: ready on vsock:%d\n", port);
    fflush(stderr);

    while (running) {
        struct pollfd pfd = { .fd = s, .events = POLLIN };
        int n = poll(&pfd, 1, 1000);
        if (n <= 0) continue;
        if (!running) break;

        int client = accept(s, NULL, NULL);
        if (client < 0) { if (errno == EINTR) continue; continue; }

        handle_client(client);
    }

    close(s);
    return 0;
}
