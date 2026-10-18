/*
        Unix domain sockets for the socket interface of norc (norc.UnixSocket):
   HashLink's sockets are TCP and UDP only. And the size of the terminal
   (norc.LineEditor), without starting stty.

        Compiled into the single binary (the HashLink/C build, -D norc_unix).
   Blocking calls let the garbage collector run meanwhile (hl_blocking), as
   HashLink's sockets do. All functions return -1 on errors (also on Windows:
   not supported there).
*/
#define HL_NAME(n) norc_##n
#include <hl.h>

#ifndef _WIN32
#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/un.h>
#include <unistd.h>

/* The address of `path`, 0 if it is too long */
static int address(struct sockaddr_un *addr, vbyte *path) {
  size_t len = strlen((char *)path);
  if (len >= sizeof(addr->sun_path))
    return 0;
  memset(addr, 0, sizeof(*addr));
  addr->sun_family = AF_UNIX;
  memcpy(addr->sun_path, path, len + 1);
  return 1;
}

/* Listens at `path` (removed before: a socket left by a previous run), readable
 * only by the user */
HL_PRIM int HL_NAME(unix_listen)(vbyte *path) {
  struct sockaddr_un addr;
  if (!address(&addr, path))
    return -1;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0)
    return -1;
  unlink((char *)path);
  // created with the permissions 0600: no moment where others could connect
  mode_t old = umask(0177);
  int ok = bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0;
  umask(old);
  if (!ok || listen(fd, 10) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

HL_PRIM int HL_NAME(unix_accept)(int fd) {
  hl_blocking(true);
  int c;
  do
    c = accept(fd, NULL, NULL);
  while (c < 0 && errno == EINTR);
  hl_blocking(false);
  return c;
}

HL_PRIM int HL_NAME(unix_connect)(vbyte *path) {
  struct sockaddr_un addr;
  if (!address(&addr, path))
    return -1;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0)
    return -1;
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

/* Reads at most `len` bytes into `buf` at `pos`: their number, 0 at the end, -1
 * on errors */
HL_PRIM int HL_NAME(unix_read)(int fd, vbyte *buf, int pos, int len) {
  hl_blocking(true);
  ssize_t n;
  do
    n = recv(fd, buf + pos, len, 0);
  while (n < 0 && errno == EINTR);
  hl_blocking(false);
  return (int)n;
}

/* Writes at most `len` bytes of `buf` at `pos`: their number, -1 on errors (no
 * SIGPIPE) */
HL_PRIM int HL_NAME(unix_write)(int fd, vbyte *buf, int pos, int len) {
  hl_blocking(true);
  ssize_t n;
#ifdef MSG_NOSIGNAL
  int flags = MSG_NOSIGNAL;
#else
  int flags = 0;
#endif
  do
    n = send(fd, buf + pos, len, flags);
  while (n < 0 && errno == EINTR);
  hl_blocking(false);
  return (int)n;
}

/* Reads time out after `seconds` (0: never): unix_read returns -1 then */
HL_PRIM int HL_NAME(unix_timeout)(int fd, double seconds) {
  struct timeval tv;
  tv.tv_sec = (time_t)seconds;
  tv.tv_usec = (suseconds_t)((seconds - (double)tv.tv_sec) * 1000000);
  return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}

/* Ends reading and writing: a thread blocked reading returns */
HL_PRIM void HL_NAME(unix_shutdown)(int fd) { shutdown(fd, SHUT_RDWR); }

HL_PRIM void HL_NAME(unix_close)(int fd) { close(fd); }

/* The user id of the process connected, -1 if unknown */
HL_PRIM int HL_NAME(unix_peer_uid)(int fd) {
#if defined(__linux__)
  struct ucred cred;
  socklen_t len = sizeof(cred);
  return (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) == 0)
             ? (int)cred.uid
             : -1;
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) ||    \
    defined(__NetBSD__)
  uid_t uid;
  gid_t gid;
  return (getpeereid(fd, &uid, &gid) == 0) ? (int)uid : -1;
#else
  return -1;
#endif
}

HL_PRIM int HL_NAME(unix_uid)() { return (int)getuid(); }

/* The size of the terminal of stdout (else stdin): rows << 16 | columns, -1 if
 * unknown */
HL_PRIM int HL_NAME(term_size)() {
  struct winsize ws;
  if ((ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 ||
       ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0) &&
      ws.ws_row > 0 && ws.ws_col > 0)
    return ((int)ws.ws_row << 16) | (int)ws.ws_col;
  return -1;
}

#else
HL_PRIM int HL_NAME(unix_listen)(vbyte *path) { return -1; }
HL_PRIM int HL_NAME(unix_accept)(int fd) { return -1; }
HL_PRIM int HL_NAME(unix_connect)(vbyte *path) { return -1; }
HL_PRIM int HL_NAME(unix_read)(int fd, vbyte *buf, int pos, int len) {
  return -1;
}
HL_PRIM int HL_NAME(unix_write)(int fd, vbyte *buf, int pos, int len) {
  return -1;
}
HL_PRIM int HL_NAME(unix_timeout)(int fd, double seconds) { return -1; }
HL_PRIM void HL_NAME(unix_shutdown)(int fd) {}
HL_PRIM void HL_NAME(unix_close)(int fd) {}
HL_PRIM int HL_NAME(unix_peer_uid)(int fd) { return -1; }
HL_PRIM int HL_NAME(unix_uid)() { return -1; }
HL_PRIM int HL_NAME(term_size)() { return -1; }
#endif
