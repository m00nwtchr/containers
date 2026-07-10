/*
 * scdaemon-shim: bridges gpg-agent's scdaemon protocol (stdio) to a
 * remote gnupg-pkcs11-scd daemon (unix socket).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>
#include <errno.h>
#include <glob.h>
#include <time.h>

int find_socket(char *out, size_t outsz, const char *dir, const char *name, int timeout) {
    time_t deadline = time(NULL) + timeout;
    char pattern[512];
    snprintf(pattern, sizeof pattern, "%s/gnupg-pkcs11-scd.*/%s", dir, name);
    while (time(NULL) < deadline) {
        glob_t g;
        if (glob(pattern, GLOB_NOSORT, NULL, &g) == 0 && g.gl_pathc > 0) {
            snprintf(out, outsz, "%s", g.gl_pathv[0]);
            globfree(&g);
            return 0;
        }
        globfree(&g);
        struct timespec ts = {0, 100 * 1000 * 1000};
        nanosleep(&ts, NULL);
    }
    return -1;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    const char *dir = getenv("SCD_SOCKET_DIR");
    const char *name = getenv("SCD_SOCKET_NAME");
    const char *timeout_s = getenv("SCDAEMON_TIMEOUT");
    if (!dir) dir = "/var/run/gnupg-pkcs11-scd";
    if (!name) name = "agent.S";
    int timeout = timeout_s ? atoi(timeout_s) : 10;

    char sock_path[512];
    if (find_socket(sock_path, sizeof sock_path, dir, name, timeout) != 0) {
        fprintf(stderr, "scdaemon-shim: timeout waiting for %s/gnupg-pkcs11-scd.*/%s\n", dir, name);
        return 1;
    }
    fprintf(stderr, "scdaemon-shim: connecting to %s\n", sock_path);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path, sizeof addr.sun_path - 1);
    if (connect(fd, (struct sockaddr*)&addr, sizeof addr) != 0) {
        perror("connect");
        return 1;
    }
    fprintf(stderr, "scdaemon-shim: connected\n");

    char buf[4096];
    while (1) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(0, &rfds);
        FD_SET(fd, &rfds);
        int maxfd = (fd > 0) ? fd : 0;
        if (select(maxfd + 1, &rfds, NULL, NULL, NULL) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (FD_ISSET(0, &rfds)) {
            ssize_t n = read(0, buf, sizeof buf);
            if (n <= 0) break;
            if (write(fd, buf, n) != n) break;
        }
        if (FD_ISSET(fd, &rfds)) {
            ssize_t n = read(fd, buf, sizeof buf);
            if (n <= 0) break;
            if (write(1, buf, n) != n) break;
        }
    }
    return 0;
}
