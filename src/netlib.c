// netlib.c
// minimal networking: tcp sockets, a blocking http get, basic server listen/accept.
// this is not libuv. it will block the calling thread.
// if you want async networking, spawn a thread from threadlib and call this from there.
// linkto "netlib" — no sdl2, no game stuff, no math. just sockets.
//
// all socket handles are lpp_ptr (long) — opaque integers pointing to heap state.
// close with net_close(h) when done or you'll leak file descriptors like a broken faucet.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET lpp_sock_t;
#define LPP_INVALID_SOCK INVALID_SOCKET
#define lpp_sock_close(s) closesocket(s)
static int lpp_net_init_done = 0;
static void lpp_net_init_if_needed(void) {
    if (!lpp_net_init_done) {
        WSADATA w; WSAStartup(MAKEWORD(2,2), &w);
        lpp_net_init_done = 1;
    }
}
#else
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
typedef int lpp_sock_t;
#define LPP_INVALID_SOCK (-1)
#define lpp_sock_close(s) close(s)
static void lpp_net_init_if_needed(void) {}
#endif

#define lpp_ptr intptr_t

typedef struct {
    lpp_sock_t fd;
} lpp_conn;


// ---- connect ----
// opens a tcp connection to host:port. host can be a hostname or ip string.
// returns a handle (long) on success, 0 on failure.
// blocking — will hang until the connection succeeds or the OS times out.
lpp_ptr net_connect(const char *host, int port) {
    if (!host) return 0;
    lpp_net_init_if_needed();

    struct addrinfo hints, *res;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    if (getaddrinfo(host, portstr, &hints, &res) != 0) return 0;

    lpp_sock_t fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd == LPP_INVALID_SOCK) { freeaddrinfo(res); return 0; }

    if (connect(fd, res->ai_addr, (int)res->ai_addrlen) != 0) {
        lpp_sock_close(fd); freeaddrinfo(res); return 0;
    }
    freeaddrinfo(res);

    lpp_conn *c = malloc(sizeof(lpp_conn));
    if (!c) { lpp_sock_close(fd); return 0; }
    c->fd = fd;
    return (lpp_ptr)c;
}

// send raw bytes. s is a null-terminated string. returns bytes sent, or -1.
int net_send(lpp_ptr h, const char *s) {
    if (!h || !s) return -1;
    lpp_conn *c = (lpp_conn*)h;
    int len = (int)strlen(s);
    return (int)send(c->fd, s, len, 0);
}

// receive up to n-1 bytes into a static internal buffer and return it.
// the buffer is overwritten on every call — copy the result if you need it.
// n is capped at 4095 internally to keep the buffer sane.
const char *net_recv(lpp_ptr h, int n) {
    static char buf[4096];
    if (!h || n <= 0) { buf[0]='\0'; return buf; }
    if (n > 4095) n = 4095;
    lpp_conn *c = (lpp_conn*)h;
    int got = (int)recv(c->fd, buf, n, 0);
    if (got <= 0) got = 0;
    buf[got] = '\0';
    return buf;
}

// read exactly one byte. returns -1 on close/error.
int net_recv_byte(lpp_ptr h) {
    if (!h) return -1;
    lpp_conn *c = (lpp_conn*)h;
    unsigned char b;
    int got = (int)recv(c->fd, (char*)&b, 1, 0);
    return got == 1 ? (int)b : -1;
}

void net_close(lpp_ptr h) {
    if (!h) return;
    lpp_sock_t fd = ((lpp_conn*)h)->fd;
    lpp_sock_close(fd);
    free((void*)h);
}


// ---- server ----
// listen on a port and accept incoming tcp connections.
// net_listen returns a "server handle". net_accept blocks until a client connects
// and returns a regular conn handle you can net_send/net_recv on.

typedef struct {
    lpp_sock_t fd;
} lpp_server;

lpp_ptr net_listen(int port) {
    lpp_net_init_if_needed();
    lpp_sock_t fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd == LPP_INVALID_SOCK) return 0;

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char*)&yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons((uint16_t)port);

    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        lpp_sock_close(fd); return 0;
    }
    if (listen(fd, 8) != 0) {
        lpp_sock_close(fd); return 0;
    }

    lpp_server *s = malloc(sizeof(lpp_server));
    if (!s) { lpp_sock_close(fd); return 0; }
    s->fd = fd;
    return (lpp_ptr)s;
}

// blocks until a client connects. returns a conn handle you can send/recv on.
lpp_ptr net_accept(lpp_ptr sh) {
    if (!sh) return 0;
    lpp_server *s = (lpp_server*)sh;
    struct sockaddr_in caddr;
#ifdef _WIN32
    int clen = sizeof(caddr);
#else
    socklen_t clen = sizeof(caddr);
#endif
    lpp_sock_t cfd = accept(s->fd, (struct sockaddr*)&caddr, &clen);
    if (cfd == LPP_INVALID_SOCK) return 0;
    lpp_conn *c = malloc(sizeof(lpp_conn));
    if (!c) { lpp_sock_close(cfd); return 0; }
    c->fd = cfd;
    return (lpp_ptr)c;
}

void net_server_close(lpp_ptr sh) {
    if (!sh) return;
    lpp_sock_close(((lpp_server*)sh)->fd);
    free((void*)sh);
}


// ---- http get ----
// the most basic http/1.0 get you've ever seen.
// opens a tcp connection, sends a raw GET request, reads the response headers
// and body into a static buffer, returns a pointer to the body.
// the buffer is 65535 bytes. if the response is bigger, it gets cut off.
// https is NOT supported. you need a TLS library for that (like mbedtls).
// this is fine for local dev servers and simple apis over http.

static char lpp_http_buf[65536];

const char *net_http_get(const char *host, int port, const char *path) {
    lpp_http_buf[0] = '\0';
    lpp_ptr h = net_connect(host, port);
    if (!h) return lpp_http_buf;

    // send a minimal http/1.0 get request
    char req[1024];
    snprintf(req, sizeof(req),
        "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n",
        path, host);
    net_send(h, req);

    // read the whole response
    int total = 0;
    while (total < (int)sizeof(lpp_http_buf) - 1) {
        int got = (int)recv(((lpp_conn*)h)->fd,
                            lpp_http_buf + total,
                            sizeof(lpp_http_buf) - 1 - total, 0);
        if (got <= 0) break;
        total += got;
    }
    lpp_http_buf[total] = '\0';
    net_close(h);

    // skip past the http headers to the body (first blank line)
    char *body = strstr(lpp_http_buf, "\r\n\r\n");
    if (body) return body + 4;
    body = strstr(lpp_http_buf, "\n\n");
    if (body) return body + 2;
    return lpp_http_buf;
}

// returns the http status code from the last net_http_get call, or 0 if unparseable.
int net_http_status(void) {
    // looks for "HTTP/1.x NNN " at the start of the buffer
    int code = 0;
    sscanf(lpp_http_buf, "HTTP/%*d.%*d %d", &code);
    return code;
}
