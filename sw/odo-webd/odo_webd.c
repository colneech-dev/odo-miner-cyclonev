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
 *   GET  /screen.json     -> /etc/odo-ui.conf (dim_timeout, dim_level)
 *   POST /screen          -> update /etc/odo-ui.conf (odo-ui polls it every ~2s)
 *                            (form fields: timeout, level)
 *
 * Plain single-threaded HTTP/1.1, no dependencies.
 *
 * SECURITY MODEL: trusted LAN by default, with OPT-IN authentication. Set
 * PASSWORD= in /etc/odo-web.conf to gate every route behind a styled login +
 * 128-bit session cookie (HttpOnly, SameSite=Lax); leave it unset for the open
 * trusted-LAN default. When open, the mutating endpoints — POST /action (incl.
 * reboot), /config, /wifi — and the expensive GET /wifiscan are reachable by any
 * client that can reach this port, so the control is network isolation: run this
 * only on a trusted home/lab LAN and NEVER expose the port to the internet (no
 * port-forward, no DMZ). The slow-loris / oversized-request / scan-hammer
 * hardening below bounds resource abuse. NOTE: even with auth enabled there is
 * no CSRF token on the form-POST endpoints (SameSite=Lax is the mitigation); to
 * live on an untrusted network, front it with an authenticating reverse proxy.
 *
 * Build: make           (cross-compile with CC=...-gcc)
 */

#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <strings.h>   /* strncasecmp */
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
#include <time.h>

#define STATUS_PATH "/run/odod/status.json"
/* Control files the miner daemon polls (same as the touch UI uses). */
#define FAN_BOOST_PATH   "/run/odod/fan_boost"
#define RESET_STATS_PATH "/run/odod/reset_stats"
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

/* ------------------------------------------------------------------ */
/* Optional auth (opt-in): set PASSWORD= in /etc/odo-web.conf to enable a    */
/* styled login page + session cookie. Empty/absent password = open (the     */
/* documented trusted-LAN default).                                          */
/* ------------------------------------------------------------------ */
static void form_get(const char *body, const char *key, char *out, size_t out_sz);
#define WEB_CONF_PATH "/etc/odo-web.conf"
#define NSESS 4
static char g_password[64] = "";
static int  g_auth = 0;
static char g_sessions[NSESS][33];
static int  g_sess_next = 0;

static void load_auth(void)
{
    /* ODO_WEB_CONF overrides the path (used by the auth test harness so it can
     * run unprivileged; production always uses /etc/odo-web.conf). */
    const char *path = getenv("ODO_WEB_CONF");
    if (!path || !*path) path = WEB_CONF_PATH;
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[160];
    while (fgets(line, sizeof(line), f)) {
        if (line[0] == '#') continue;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        char *v = eq + 1;
        v[strcspn(v, "\r\n")] = 0;
        if (strcmp(line, "PASSWORD") == 0 && v[0])
            snprintf(g_password, sizeof(g_password), "%s", v);
    }
    fclose(f);
    g_auth = (g_password[0] != 0);
}

/* Fixed-time compare over the secret length, independent of the attacker's
 * input length: pad the guess to lb with a sentinel so timing depends only on
 * the secret, then fold in the length difference. */
static int ct_eq(const char *a, const char *b)
{
    size_t la = strlen(a), lb = strlen(b), i;
    unsigned char d = (unsigned char)(la ^ lb);
    for (i = 0; i < lb; i++) {
        unsigned char ca = (i < la) ? (unsigned char)a[i] : 0;
        d |= (unsigned char)(ca ^ (unsigned char)b[i]);
    }
    return d == 0 && la == lb;
}

/* Generate a 128-bit session token as 32 hex chars. Returns 0 on success, -1 if
 * the CSPRNG is unavailable — callers MUST fail closed rather than issue a
 * guessable token (no rand() fallback). */
static int gen_token(char *out33)
{
    unsigned char b[16];
    FILE *u = fopen("/dev/urandom", "r");
    int ok = (u && fread(b, 1, sizeof(b), u) == sizeof(b));
    if (u) fclose(u);
    if (!ok) return -1;
    for (int i = 0; i < 16; i++) snprintf(out33 + i * 2, 3, "%02x", b[i]);
    out33[32] = 0;
    return 0;
}

/* case-insensitive substring (no _GNU_SOURCE strcasestr dependency) */
static const char *ci_strstr(const char *hay, const char *needle)
{
    size_t nl = strlen(needle);
    if (!nl) return hay;
    for (; *hay; hay++)
        if (strncasecmp(hay, needle, nl) == 0) return hay;
    return NULL;
}

/* Extract the odosession token from the *Cookie header only* — never the
 * request line or body (a token presented as a POST field must NOT authenticate).
 * Returns 1 with a non-empty NUL-terminated tok33, else 0. */
static int cookie_token(const char *req, char *tok33)
{
    tok33[0] = 0;
    const char *p = req;
    while (p && *p) {
        const char *nl = strchr(p, '\n');
        size_t linelen = nl ? (size_t)(nl - p) : strlen(p);
        if (linelen == 0 || (linelen == 1 && p[0] == '\r'))
            break;                           /* blank line: end of headers */
        if (strncasecmp(p, "Cookie:", 7) == 0) {
            const char *end = p + linelen;
            for (const char *c = p + 7; c < end; c++) {
                if ((size_t)(end - c) >= 11 && strncmp(c, "odosession=", 11) == 0) {
                    c += 11;
                    int i = 0;
                    while (c < end && i < 32 &&
                           *c != ';' && *c != ' ' && *c != '\t' && *c != '\r')
                        tok33[i++] = *c++;
                    tok33[i] = 0;
                    return tok33[0] != 0;     /* reject empty token */
                }
            }
        }
        if (!nl) break;
        p = nl + 1;
    }
    return 0;
}

static int request_authed(const char *req)
{
    if (!g_auth) return 1;                 /* auth disabled => everyone allowed */
    char tok[33];
    if (!cookie_token(req, tok)) return 0; /* no Cookie header / empty token */
    for (int s = 0; s < NSESS; s++)
        if (g_sessions[s][0] && strcmp(g_sessions[s], tok) == 0) return 1;
    return 0;
}

static void serve_login(int fd, int err)
{
    char body[2048];
    int n = snprintf(body, sizeof(body),
      "<!DOCTYPE html><html><head><meta charset='utf-8'>"
      "<meta name='viewport' content='width=device-width,initial-scale=1'>"
      "<title>ODO MINER &mdash; Sign in</title></head>"
      "<body style='margin:0;background:#100F0B;color:#F2EFE6;font-family:system-ui,Segoe UI,Roboto,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center'>"
      "<form method='post' action='/login' style='background:#16140E;border:1px solid #2E2A1F;border-radius:14px;padding:28px 26px;width:300px'>"
      "<div style='font-size:20px;font-weight:600;color:#F0B23C;margin-bottom:4px'>ODO MINER</div>"
      "<div style='font-size:13px;color:#888;margin-bottom:20px'>Sign in to the dashboard</div>"
      "%s"
      "<input name='password' type='password' placeholder='Password' autofocus "
      "style='width:100%%;box-sizing:border-box;background:#0C0B08;color:#F2EFE6;border:1px solid #2E2A1F;border-radius:9px;padding:11px 12px;font-size:14px;margin-bottom:16px'>"
      "<button type='submit' style='width:100%%;background:#F0B23C;color:#100F0B;border:0;border-radius:9px;padding:11px;font-size:14px;font-weight:600;cursor:pointer'>Sign in</button>"
      "</form></body></html>",
      err ? "<div style='background:#3a1a17;color:#E07B6A;border-radius:8px;padding:8px 12px;font-size:13px;margin-bottom:16px'>Incorrect password</div>" : "");
    send_response(fd, "200 OK", "text/html", body, (size_t)n);
}

static void handle_login(int fd, const char *body)
{
    char pw[64] = "";
    form_get(body, "password", pw, sizeof(pw));
    if (g_password[0] && ct_eq(pw, g_password)) {
        char tok[33];
        if (gen_token(tok) != 0) {           /* CSPRNG unavailable — fail closed */
            send_response(fd, "503 Service Unavailable", "text/plain",
                          "auth temporarily unavailable\n", 29);
            return;
        }
        snprintf(g_sessions[g_sess_next], 33, "%s", tok);
        g_sess_next = (g_sess_next + 1) % NSESS;
        char hdr[256];
        int n = snprintf(hdr, sizeof(hdr),
            "HTTP/1.1 303 See Other\r\nLocation: /\r\n"
            "Set-Cookie: odosession=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=604800\r\n"
            "Content-Length: 0\r\nConnection: close\r\n\r\n", tok);
        if (write(fd, hdr, (size_t)n) < 0) return;
    } else {
        serve_login(fd, 1);
    }
}

static void handle_logout(int fd, const char *req)
{
    /* Invalidate only the requester's own cookie token (gated behind auth in the
     * router, so this can't clear a third party's session). */
    char tok[33];
    if (cookie_token(req, tok)) {
        for (int s = 0; s < NSESS; s++)
            if (g_sessions[s][0] && strcmp(g_sessions[s], tok) == 0)
                g_sessions[s][0] = 0;
    }
    char hdr[256];
    int n = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 303 See Other\r\nLocation: /\r\n"
        "Set-Cookie: odosession=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0\r\n"
        "Content-Length: 0\r\nConnection: close\r\n\r\n");
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

/* forward declaration — form_get defined later in this file */
static void form_get(const char *body, const char *key, char *out, size_t out_sz);

/* ------------------------------------------------------------------ */
/* Screen settings (dim timeout + level)                               */
/* ------------------------------------------------------------------ */
#define UI_CONF_PATH "/etc/odo-ui.conf"

static void serve_screen(int fd)
{
    int timeout = 300, level = 0;
    FILE *f = fopen(UI_CONF_PATH, "r");
    if (f) {
        char line[128];
        while (fgets(line, sizeof(line), f)) {
            char *eq = strchr(line, '=');
            if (!eq || line[0] == '#') continue;
            *eq = 0;
            int val = atoi(eq + 1);
            if      (strcmp(line, "DIM_TIMEOUT") == 0) timeout = val;
            else if (strcmp(line, "DIM_LEVEL")   == 0) level   = val;
        }
        fclose(f);
    }
    char body[64];
    int n = snprintf(body, sizeof(body),
        "{\"dim_timeout\":%d,\"dim_level\":%d}", timeout, level);
    send_response(fd, "200 OK", "application/json", body, (size_t)n);
}

static void handle_screen(int fd, const char *body)
{
    char stimeout[16] = "300", slevel[8] = "0";
    form_get(body, "timeout", stimeout, sizeof(stimeout));
    form_get(body, "level",   slevel,   sizeof(slevel));
    int timeout = atoi(stimeout);
    int level   = atoi(slevel);
    if (timeout < 0 || timeout > 3600 || level < 0 || level > 100) {
        send_response(fd, "400 Bad Request", "text/plain",
                      "timeout 0-3600, level 0-100\n", 28);
        return;
    }
    FILE *f = fopen(UI_CONF_PATH ".tmp", "w");
    if (!f) {
        send_response(fd, "500 Internal Server Error", "text/plain",
                      "write failed\n", 13);
        return;
    }
    fprintf(f, "DIM_TIMEOUT=%d\nDIM_LEVEL=%d\n", timeout, level);
    fclose(f);
    rename(UI_CONF_PATH ".tmp", UI_CONF_PATH);
    send_redirect(fd, "/");
}

/* ------------------------------------------------------------------ */
/* Config read-back                                                    */
/* ------------------------------------------------------------------ */
static void serve_config(int fd)
{
    char host[128]="", port[16]="", worker[160]="", pass[64]="";
    char testnet[8]="0", host2[128]="", port2[16]="";

    FILE *f = fopen(CONF_PATH, "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof(line), f)) {
            line[strcspn(line, "\n")] = 0;
            char *eq = strchr(line, '=');
            if (!eq || line[0] == '#') continue;
            *eq = 0;
            const char *key = line, *val = eq + 1;
            if      (strcmp(key, "ODOD_POOL_HOST")  == 0) snprintf(host,    sizeof(host),    "%s", val);
            else if (strcmp(key, "ODOD_POOL_PORT")  == 0) snprintf(port,    sizeof(port),    "%s", val);
            else if (strcmp(key, "ODOD_WORKER")     == 0) snprintf(worker,  sizeof(worker),  "%s", val);
            else if (strcmp(key, "ODOD_PASSWORD")   == 0) snprintf(pass,    sizeof(pass),    "%s", val);
            else if (strcmp(key, "ODO_TESTNET")     == 0) snprintf(testnet, sizeof(testnet), "%s", val);
            else if (strcmp(key, "ODOD_POOL_HOST2") == 0) snprintf(host2,   sizeof(host2),   "%s", val);
            else if (strcmp(key, "ODOD_POOL_PORT2") == 0) snprintf(port2,   sizeof(port2),   "%s", val);
        }
        fclose(f);
    }

    /* All values were written through value_safe() so contain no '"' or '\' */
    char body[640];
    int n = snprintf(body, sizeof(body),
        "{\"host\":\"%s\",\"port\":\"%s\",\"worker\":\"%s\","
        "\"pass\":\"%s\",\"testnet\":%s,\"host2\":\"%s\",\"port2\":\"%s\"}",
        host, port, worker, pass,
        testnet[0] == '1' ? "true" : "false",
        host2, port2);
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

#define WIFI_STATUS_TTL 30  /* seconds — iw dev link is slow; cache it */

static void serve_wifi_status(int fd)
{
    static char   cache[512];
    static size_t cache_len = 0;
    static time_t cache_at  = 0;

    time_t now = time(NULL);
    if (cache_len > 0 && now - cache_at < WIFI_STATUS_TTL) {
        send_response(fd, "200 OK", "application/json", cache, cache_len);
        return;
    }

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
    int n = snprintf(cache, sizeof(cache),
        "{\"present\":%s,\"ssid\":\"%s\",\"ip\":\"%s\"}",
        present ? "true" : "false", essid, ip);
    cache_len = (size_t)n;
    cache_at  = now;
    send_response(fd, "200 OK", "application/json", cache, cache_len);
}

/* A full `iw scan` takes seconds and briefly interrupts the live association
 * the dashboard rides on. Since the endpoint is unauthenticated, cache the
 * result so repeated hits can't be used to hammer the radio (a cheap, no-UX
 * mitigation for the self-DoS; full auth on this endpoint is still TODO —
 * see docs/review-action-plan.md Bucket C H1). */
#define WIFI_SCAN_TTL 15   /* seconds */

static void serve_wifi_scan(int fd)
{
    static char   cache[3072];
    static size_t cache_len = 0;
    static time_t cache_at  = 0;

    time_t now = time(NULL);
    if (cache_len > 0 && now - cache_at < WIFI_SCAN_TTL) {
        send_response(fd, "200 OK", "application/json", cache, cache_len);
        return;
    }

    char body[3072];
    size_t off = 0;
    off += (size_t)snprintf(body + off, sizeof(body) - off, "{\"ssids\":[");

    /* Deliberately NOT bouncing the interface up here: on a working board it is
     * already up, and `ip link set wlan0 up` from an unauthenticated GET would
     * disrupt the active link. If wlan0 is down the scan just returns nothing. */
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

    if (off < sizeof(cache)) {            /* refresh the cache */
        memcpy(cache, body, off);
        cache_len = off;
        cache_at  = now;
    }
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
        "ctrl_interface=/tmp/wpa_supplicant\n"
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
    } else if (strcmp(action, "fan_boost") == 0) {
        FILE *f = fopen(FAN_BOOST_PATH, "w"); if (f) fclose(f);
        send_redirect(fd, "/");
    } else if (strcmp(action, "fan_auto") == 0) {
        unlink(FAN_BOOST_PATH);
        send_redirect(fd, "/");
    } else if (strcmp(action, "reset_stats") == 0) {
        FILE *f = fopen(RESET_STATS_PATH, "w"); if (f) fclose(f);
        send_redirect(fd, "/");
    } else {
        send_response(fd, "400 Bad Request", "text/plain", "unknown action\n", 15);
    }
}

/* Current control state (fan boost) for the dashboard to reflect. */
static void serve_controls(int fd)
{
    int boost = (access(FAN_BOOST_PATH, F_OK) == 0);
    char body[48];
    int n = snprintf(body, sizeof(body), "{\"fan_boost\":%d,\"auth\":%d}", boost, g_auth);
    send_response(fd, "200 OK", "application/json", body, (size_t)n);
}

/* ------------------------------------------------------------------ */
/* Main loop                                                           */
/* ------------------------------------------------------------------ */
int main(int argc, char **argv)
{
    int port = argc > 1 ? atoi(argv[1]) : 80;
    signal(SIGPIPE, SIG_IGN);
    load_auth();   /* opt-in: PASSWORD= in /etc/odo-web.conf enables login */
    fprintf(stderr, "odo-webd: auth %s\n", g_auth ? "ENABLED" : "disabled (open)");

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
        /* Short per-connection receive timeout: this server is single-threaded,
         * so a client that connects and then stalls would otherwise hold the
         * whole loop for the timeout window (slow-loris). 2 s is ample for a
         * LAN request and bounds the damage one idle peer can do. */
        struct timeval tv = { 2, 0 };
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
            const char *cl = ci_strstr(req, "Content-Length:");
            if (cl) {
                long want = strtol(cl + 15, NULL, 10);
                /* Reject bodies that can't fit the fixed buffer instead of
                 * silently truncating and then parsing a partial form. */
                long capacity = (long)(sizeof(req) - (size_t)(body - req) - 1);
                if (want > capacity) {
                    send_response(fd, "413 Payload Too Large", "text/plain",
                                  "request too large\n", 18);
                    close(fd);
                    continue;
                }
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

        /* Auth gate (no-op when PASSWORD is unset). /login is always reachable;
         * everything else requires a valid session cookie. */
        if (strncmp(req, "GET /login", 10) == 0) {
            serve_login(fd, 0); close(fd); continue;
        } else if (strncmp(req, "POST /login", 11) == 0 && body) {
            handle_login(fd, body); close(fd); continue;
        } else if (strncmp(req, "POST /logout", 12) == 0) {
            if (!request_authed(req)) { serve_login(fd, 0); close(fd); continue; }
            handle_logout(fd, req); close(fd); continue;
        } else if (!request_authed(req)) {
            serve_login(fd, 0); close(fd); continue;
        }

        if (strncmp(req, "GET / ", 6) == 0) {
            /* A customised page at /etc/odo-web/index.html wins over the
             * built-in one — restyle without recompiling. To start from the
             * built-in: curl -s localhost > /etc/odo-web/index.html */
            FILE *pf = fopen(CUSTOM_PAGE, "r");
            if (pf) {
                static char page_buf[65536];
                size_t pn = fread(page_buf, 1, sizeof(page_buf) - 1, pf);
                int truncated = !feof(pf);   /* file exceeds the buffer */
                fclose(pf);
                if (truncated)
                    fprintf(stderr, "odo-webd: %s exceeds %zu B — serving truncated\n",
                            CUSTOM_PAGE, sizeof(page_buf) - 1);
                send_response(fd, "200 OK", "text/html", page_buf, pn);
            } else {
                send_response(fd, "200 OK", "text/html", PAGE, sizeof(PAGE) - 1);
            }
        } else if (strncmp(req, "GET /screen.json", 16) == 0) {
            serve_screen(fd);
        } else if (strncmp(req, "POST /screen", 12) == 0 && body) {
            handle_screen(fd, body);
        } else if (strncmp(req, "GET /config.json", 16) == 0) {
            serve_config(fd);
        } else if (strncmp(req, "GET /status.json", 16) == 0) {
            serve_file(fd, STATUS_PATH, "application/json");
        } else if (strncmp(req, "GET /sysinfo.json", 17) == 0) {
            serve_sysinfo(fd);
        } else if (strncmp(req, "GET /controls.json", 18) == 0) {
            serve_controls(fd);
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
