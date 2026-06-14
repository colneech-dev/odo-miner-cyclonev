/*
 * odo_webd.c — tiny web dashboard + configuration server for odo-miner.
 *
 * Serves on port 80 (override: odo-webd <port>):
 *   GET  /                -> embedded single-page dashboard (auto-refreshing)
 *   GET  /status.json     -> /run/odod/status.json (written by odo-miner)
 *   GET  /sysinfo.json    -> load average, memory, IP address, kernel uptime
 *   POST /config          -> update /etc/odod.conf and restart the miner
 *                            (form fields: host, port, worker, pass, testnet)
 *   POST /action          -> body "action=restart" | "action=reboot"
 *   GET  /wifi.json       -> wlan0 presence, connected SSID, IP
 *   GET  /wifiscan.json   -> nearby SSIDs (runs `iw scan`, takes a few seconds)
 *   POST /wifi            -> write /etc/wpa_supplicant.conf and reconnect
 *                            (form fields: ssid, psk — empty psk = open network)
 *
 * Plain single-threaded HTTP/1.1, no dependencies. Intended for a trusted
 * LAN: there is NO authentication — do not expose this port to the internet.
 *
 * Build: make           (cross-compile with CC=...-gcc)
 */

#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <ctype.h>
#include <sys/socket.h>
#include <sys/sysinfo.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <ifaddrs.h>

#define STATUS_PATH "/run/odod/status.json"
#define CONF_PATH   "/etc/odod.conf"
#define WPA_CONF    "/etc/wpa_supplicant.conf"
#define CUSTOM_PAGE "/etc/odo-web/index.html"   /* overrides the built-in page */
#define MINER_RESTART_CMD "/etc/init.d/S90odod restart >/dev/null 2>&1 &"
#define WIFI_RESTART_CMD  "/etc/init.d/S45wifi restart >/dev/null 2>&1 &"

/* ------------------------------------------------------------------ */
/* Embedded dashboard page                                             */
/* ------------------------------------------------------------------ */
static const char PAGE[] =
    "<!DOCTYPE html><html><head><meta charset='utf-8'><title>ODO MINER</title></head>"
    "<body style='background:#100F0B;color:#F2EFE6;font-family:monospace;padding:2em'>"
    "<p>Install /etc/odo-web/index.html on the board to enable the dashboard.</p>"
    "</body></html>";


/* ------------------------------------------------------------------ */
/* HTTP plumbing                                                       */
/* ------------------------------------------------------------------ */
static void send_response(int fd, const char *status, const char *ctype,
                          const char *body, size_t body_len)
{
    char hdr[256];
    int n = snprintf(hdr, sizeof(hdr),
                     "HTTP/1.1 %s\r\nContent-Type: %s\r\n"
                     "Content-Length: %zu\r\nCache-Control: no-store\r\n"
                     "Connection: close\r\n\r\n",
                     status, ctype, body_len);
    if (write(fd, hdr, (size_t)n) < 0) return;
    if (body_len && write(fd, body, body_len) < 0) return;
}

static void send_redirect(int fd, const char *loc)
{
    char hdr[256];
    int n = snprintf(hdr, sizeof(hdr),
                     "HTTP/1.1 303 See Other\r\nLocation: %s\r\n"
                     "Content-Length: 0\r\nConnection: close\r\n\r\n", loc);
    if (write(fd, hdr, (size_t)n) < 0) return;
}

static void serve_file(int fd, const char *path, const char *ctype)
{
    char buf[4096];
    FILE *f = fopen(path, "r");
    if (!f) {
        send_response(fd, "404 Not Found", "application/json", "{}", 2);
        return;
    }
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;
    send_response(fd, "200 OK", ctype, buf, n);
}

static void serve_sysinfo(int fd)
{
    double load1 = 0;
    long mem_free_mb = 0, sys_up = 0;
    char ip[64] = "";

    FILE *f = fopen("/proc/loadavg", "r");
    if (f) { if (fscanf(f, "%lf", &load1) != 1) load1 = 0; fclose(f); }

    struct sysinfo si;
    if (sysinfo(&si) == 0) {
        mem_free_mb = (long)((uint64_t)si.freeram * si.mem_unit / (1024 * 1024));
        sys_up = si.uptime;
    }

    struct ifaddrs *ifa0 = NULL;
    if (getifaddrs(&ifa0) == 0) {
        for (struct ifaddrs *ifa = ifa0; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
                continue;
            if (strcmp(ifa->ifa_name, "lo") == 0)
                continue;
            inet_ntop(AF_INET,
                      &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr,
                      ip, sizeof(ip));
            break;
        }
        freeifaddrs(ifa0);
    }

    char body[256];
    int n = snprintf(body, sizeof(body),
        "{\"ip\":\"%s\",\"load1\":%.2f,\"mem_free_mb\":%ld,\"sys_uptime\":%ld}",
        ip, load1, mem_free_mb, sys_up);
    send_response(fd, "200 OK", "application/json", body, (size_t)n);
}

/* ------------------------------------------------------------------ */
/* Config read-back                                                    */
/* ------------------------------------------------------------------ */
static void serve_config(int fd)
{
    char host[128]="", port[16]="", worker[160]="", pass[64]="";
    char testnet[8]="0";

    FILE *f = fopen(CONF_PATH, "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof(line), f)) {
            line[strcspn(line, "\n")] = 0;
            char *eq = strchr(line, '=');
            if (!eq || line[0] == '#') continue;
            *eq = 0;
            const char *key = line, *val = eq + 1;
            if      (strcmp(key, "ODOD_POOL_HOST") == 0) snprintf(host,    sizeof(host),    "%s", val);
            else if (strcmp(key, "ODOD_POOL_PORT") == 0) snprintf(port,    sizeof(port),    "%s", val);
            else if (strcmp(key, "ODOD_WORKER")    == 0) snprintf(worker,  sizeof(worker),  "%s", val);
            else if (strcmp(key, "ODOD_PASSWORD")  == 0) snprintf(pass,    sizeof(pass),    "%s", val);
            else if (strcmp(key, "ODO_TESTNET")    == 0) snprintf(testnet, sizeof(testnet), "%s", val);
        }
        fclose(f);
    }

    /* All values were written through value_safe() so contain no '"' or '\' */
    char body[512];
    int n = snprintf(body, sizeof(body),
        "{\"host\":\"%s\",\"port\":\"%s\",\"worker\":\"%s\","
        "\"pass\":\"%s\",\"testnet\":%s}",
        host, port, worker, pass,
        testnet[0] == '1' ? "true" : "false");
    send_response(fd, "200 OK", "application/json", body, (size_t)n);
}

/* ------------------------------------------------------------------ */
/* WiFi                                                                */
/* ------------------------------------------------------------------ */
static void json_escape(const char *in, char *out, size_t out_sz)
{
    size_t o = 0;
    for (; *in && o + 2 < out_sz; in++) {
        if (*in == '"' || *in == '\\')
            out[o++] = '\\';
        if ((unsigned char)*in < 0x20)
            continue;
        out[o++] = *in;
    }
    out[o] = 0;
}

static void wlan_ip(char *ip, size_t ip_sz)
{
    ip[0] = 0;
    struct ifaddrs *ifa0 = NULL;
    if (getifaddrs(&ifa0) != 0)
        return;
    for (struct ifaddrs *ifa = ifa0; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
            continue;
        if (strncmp(ifa->ifa_name, "wlan", 4) != 0)
            continue;
        inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr,
                  ip, ip_sz);
        break;
    }
    freeifaddrs(ifa0);
}

static void serve_wifi_status(int fd)
{
    int present = access("/sys/class/net/wlan0", F_OK) == 0;
    char ssid[128] = "", ip[64] = "";

    if (present) {
        FILE *p = popen("iw dev wlan0 link 2>/dev/null", "r");
        if (p) {
            char line[256];
            while (fgets(line, sizeof(line), p)) {
                char *s = strstr(line, "SSID: ");
                if (s) {
                    s += 6;
                    s[strcspn(s, "\n")] = 0;
                    snprintf(ssid, sizeof(ssid), "%s", s);
                }
            }
            pclose(p);
        }
        wlan_ip(ip, sizeof(ip));
    }

    char essid[256];
    json_escape(ssid, essid, sizeof(essid));
    char body[512];
    int n = snprintf(body, sizeof(body),
        "{\"present\":%s,\"ssid\":\"%s\",\"ip\":\"%s\"}",
        present ? "true" : "false", essid, ip);
    send_response(fd, "200 OK", "application/json", body, (size_t)n);
}

static void serve_wifi_scan(int fd)
{
    char body[3072];
    size_t off = 0;
    off += (size_t)snprintf(body + off, sizeof(body) - off, "{\"ssids\":[");

    /* Interface must be up to scan; `ip link set up` is harmless if it is */
    if (system("ip link set wlan0 up 2>/dev/null") != 0) { }
    FILE *p = popen("iw dev wlan0 scan 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p' | sort -u",
                    "r");
    int first = 1;
    if (p) {
        char line[128], esc[256];
        while (fgets(line, sizeof(line), p)) {
            line[strcspn(line, "\n")] = 0;
            if (!line[0])
                continue;
            json_escape(line, esc, sizeof(esc));
            if (off + strlen(esc) + 8 >= sizeof(body))
                break;
            off += (size_t)snprintf(body + off, sizeof(body) - off,
                                    "%s\"%s\"", first ? "" : ",", esc);
            first = 0;
        }
        pclose(p);
    }
    off += (size_t)snprintf(body + off, sizeof(body) - off, "]}");
    send_response(fd, "200 OK", "application/json", body, off);
}

/* ------------------------------------------------------------------ */
/* Form decoding                                                       */
/* ------------------------------------------------------------------ */
static void url_decode(char *s)
{
    char *o = s;
    while (*s) {
        if (*s == '+') { *o++ = ' '; s++; }
        else if (*s == '%' && isxdigit((unsigned char)s[1]) && isxdigit((unsigned char)s[2])) {
            char hex[3] = { s[1], s[2], 0 };
            *o++ = (char)strtol(hex, NULL, 16);
            s += 3;
        } else *o++ = *s++;
    }
    *o = 0;
}

static void form_get(const char *body, const char *key, char *out, size_t out_sz)
{
    out[0] = 0;
    size_t klen = strlen(key);
    const char *p = body;
    while (p && *p) {
        if (strncmp(p, key, klen) == 0 && p[klen] == '=') {
            p += klen + 1;
            size_t i = 0;
            while (*p && *p != '&' && i + 1 < out_sz)
                out[i++] = *p++;
            out[i] = 0;
            url_decode(out);
            return;
        }
        p = strchr(p, '&');
        if (p) p++;
    }
}

/* Reject values that could break the shell-sourced conf file */
static int value_safe(const char *s)
{
    for (; *s; s++)
        if (!isalnum((unsigned char)*s) && !strchr(".-_:@/", *s))
            return 0;
    return 1;
}

static void handle_config(int fd, const char *body)
{
    char host[128], port[16], worker[160], pass[64], testnet[8];
    char host2[128], port2[16];
    form_get(body, "host", host, sizeof(host));
    form_get(body, "port", port, sizeof(port));
    form_get(body, "worker", worker, sizeof(worker));
    form_get(body, "pass", pass, sizeof(pass));
    form_get(body, "testnet", testnet, sizeof(testnet));
    form_get(body, "host2", host2, sizeof(host2));
    form_get(body, "port2", port2, sizeof(port2));

    if (!host[0] || !port[0] || !worker[0] ||
        !value_safe(host) || !value_safe(port) ||
        !value_safe(worker) || !value_safe(pass) ||
        !value_safe(host2) || !value_safe(port2)) {
        send_response(fd, "400 Bad Request", "text/plain",
                      "invalid characters in form values\n", 33);
        return;
    }

    FILE *f = fopen(CONF_PATH ".tmp", "w");
    if (!f) {
        send_response(fd, "500 Internal Server Error", "text/plain", "conf write failed\n", 18);
        return;
    }
    fprintf(f,
        "# written by odo-webd\n"
        "ODOD_POOL_HOST=%s\nODOD_POOL_PORT=%s\n"
        "ODOD_WORKER=%s\nODOD_PASSWORD=%s\nODO_TESTNET=%s\n"
        "ODOD_POOL_HOST2=%s\nODOD_POOL_PORT2=%s\n",
        host, port, worker, pass[0] ? pass : "x",
        testnet[0] == '1' ? "1" : "0",
        host2, port2);
    fclose(f);
    rename(CONF_PATH ".tmp", CONF_PATH);

    if (system(MINER_RESTART_CMD) != 0) { /* best effort */ }
    send_redirect(fd, "/");
}

/* WPA config values: printable ASCII, no quote/backslash (keeps the
 * wpa_supplicant.conf quoting trivially safe). Covers virtually all
 * real-world SSIDs and passphrases. */
static int wpa_value_safe(const char *s, size_t min_len, size_t max_len)
{
    size_t len = strlen(s);
    if (len < min_len || len > max_len)
        return 0;
    for (; *s; s++)
        if ((unsigned char)*s < 0x20 || (unsigned char)*s > 0x7E ||
            *s == '"' || *s == '\\')
            return 0;
    return 1;
}

static void handle_wifi(int fd, const char *body)
{
    char ssid[64], psk[80];
    form_get(body, "ssid", ssid, sizeof(ssid));
    form_get(body, "psk", psk, sizeof(psk));

    if (!wpa_value_safe(ssid, 1, 32) ||
        (psk[0] && !wpa_value_safe(psk, 8, 63))) {
        send_response(fd, "400 Bad Request", "text/plain",
                      "SSID must be 1-32 chars; password 8-63 chars "
                      "(or empty for an open network); no quotes/backslashes\n",
                      110);
        return;
    }

    FILE *f = fopen(WPA_CONF ".tmp", "w");
    if (!f) {
        send_response(fd, "500 Internal Server Error", "text/plain",
                      "wpa conf write failed\n", 22);
        return;
    }
    fprintf(f,
        "# written by odo-webd\n"
        "ctrl_interface=/var/run/wpa_supplicant\n"
        "update_config=0\n"
        "network={\n"
        "    ssid=\"%s\"\n", ssid);
    if (psk[0])
        fprintf(f, "    psk=\"%s\"\n", psk);
    else
        fprintf(f, "    key_mgmt=NONE\n");
    fprintf(f, "}\n");
    fclose(f);
    rename(WPA_CONF ".tmp", WPA_CONF);

    if (system(WIFI_RESTART_CMD) != 0) { /* best effort */ }
    send_redirect(fd, "/");
}

static void handle_action(int fd, const char *body)
{
    char action[32];
    form_get(body, "action", action, sizeof(action));

    if (strcmp(action, "restart") == 0) {
        if (system(MINER_RESTART_CMD) != 0) { }
        send_redirect(fd, "/");
    } else if (strcmp(action, "reboot") == 0) {
        send_redirect(fd, "/");
        sync();
        if (system("(sleep 1; reboot) >/dev/null 2>&1 &") != 0) { }
    } else {
        send_response(fd, "400 Bad Request", "text/plain", "unknown action\n", 15);
    }
}

/* ------------------------------------------------------------------ */
/* Main loop                                                           */
/* ------------------------------------------------------------------ */
int main(int argc, char **argv)
{
    int port = argc > 1 ? atoi(argv[1]) : 80;
    signal(SIGPIPE, SIG_IGN);

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return 1; }
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    if (listen(srv, 8) < 0) { perror("listen"); return 1; }
    fprintf(stderr, "odo-webd: listening on port %d\n", port);

    for (;;) {
        int fd = accept(srv, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            break;
        }
        struct timeval tv = { 5, 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        char req[8192];
        ssize_t n = read(fd, req, sizeof(req) - 1);
        if (n <= 0) { close(fd); continue; }
        req[n] = 0;

        /* For POSTs, make sure we have the whole body (Content-Length).
         * Accept both CRLF (RFC) and LF-only (Busybox wget, some clients). */
        char *body = strstr(req, "\r\n\r\n");
        int body_skip = 4;
        if (!body) { body = strstr(req, "\n\n"); body_skip = 2; }
        if (body) {
            body += body_skip;
            const char *cl = strstr(req, "Content-Length:");
            if (cl) {
                long want = strtol(cl + 15, NULL, 10);
                long have = n - (body - req);
                while (have < want && have < (long)(sizeof(req) - (body - req) - 1)) {
                    ssize_t m = read(fd, req + n, sizeof(req) - 1 - (size_t)n);
                    if (m <= 0) break;
                    n += m;
                    req[n] = 0;
                    have = n - (body - req);
                }
            }
        }

        if (strncmp(req, "GET / ", 6) == 0) {
            /* A customised page at /etc/odo-web/index.html wins over the
             * built-in one — restyle without recompiling. To start from the
             * built-in: curl -s localhost > /etc/odo-web/index.html */
            FILE *pf = fopen(CUSTOM_PAGE, "r");
            if (pf) {
                static char page_buf[65536];
                size_t pn = fread(page_buf, 1, sizeof(page_buf) - 1, pf);
                fclose(pf);
                send_response(fd, "200 OK", "text/html", page_buf, pn);
            } else {
                send_response(fd, "200 OK", "text/html", PAGE, sizeof(PAGE) - 1);
            }
        } else if (strncmp(req, "GET /config.json", 16) == 0) {
            serve_config(fd);
        } else if (strncmp(req, "GET /status.json", 16) == 0) {
            serve_file(fd, STATUS_PATH, "application/json");
        } else if (strncmp(req, "GET /sysinfo.json", 17) == 0) {
            serve_sysinfo(fd);
        } else if (strncmp(req, "GET /wifi.json", 14) == 0) {
            serve_wifi_status(fd);
        } else if (strncmp(req, "GET /wifiscan.json", 18) == 0) {
            serve_wifi_scan(fd);
        } else if (strncmp(req, "POST /wifi", 10) == 0 && body) {
            handle_wifi(fd, body);
        } else if (strncmp(req, "POST /config", 12) == 0 && body) {
            handle_config(fd, body);
        } else if (strncmp(req, "POST /action", 12) == 0 && body) {
            handle_action(fd, body);
        } else {
            send_response(fd, "404 Not Found", "text/plain", "not found\n", 10);
        }
        close(fd);
    }
    return 0;
}
