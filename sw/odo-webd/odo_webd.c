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
#define MINER_RESTART_CMD "/etc/init.d/S90odod restart >/dev/null 2>&1 &"
#define WIFI_RESTART_CMD  "/etc/init.d/S45wifi restart >/dev/null 2>&1 &"

/* ------------------------------------------------------------------ */
/* Embedded dashboard page                                             */
/* ------------------------------------------------------------------ */
static const char PAGE[] =
"<!DOCTYPE html><html><head><meta charset='utf-8'>"
"<meta name='viewport' content='width=device-width,initial-scale=1'>"
"<title>odo-miner</title><style>"
"body{font-family:system-ui,sans-serif;background:#0d1020;color:#dde2f0;"
"margin:0;padding:16px;max-width:560px;margin-inline:auto}"
"h1{font-size:20px;color:#6aa8ff;margin:8px 0 16px}"
"h1 small{color:#7c8499;font-weight:400;font-size:13px;margin-left:8px}"
".card{background:#181e34;border-radius:10px;padding:14px 16px;margin-bottom:14px}"
".big{font-size:34px;font-weight:600;margin:2px 0 8px}"
".row{display:flex;justify-content:space-between;padding:3px 0;font-size:14px}"
".row span:first-child{color:#7c8499}"
".chip{padding:2px 10px;border-radius:10px;font-size:12px;font-weight:600}"
".ok{background:#15402a;color:#52d68a}.warn{background:#4a3a12;color:#f0b43c}"
".bad{background:#491b1b;color:#f07878}"
"label{display:block;color:#7c8499;font-size:12px;margin:10px 0 2px}"
"input[type=text],input[type=password]{width:100%;box-sizing:border-box;"
"background:#0d1020;color:#dde2f0;border:1px solid #2c3550;border-radius:6px;"
"padding:8px;font-size:14px}"
"button{background:#2a4d8f;color:#fff;border:0;border-radius:6px;padding:10px 16px;"
"font-size:14px;margin:12px 8px 0 0;cursor:pointer}"
"button.danger{background:#8f2a2a}"
"#bar{height:6px;border-radius:3px;background:#2c3550;margin-top:6px}"
"#barfill{height:6px;border-radius:3px;background:#6aa8ff;width:0%}"
"</style></head><body>"
"<h1>odo-miner<small id='host'></small></h1>"
"<div class='card'>"
"<div class='row'><span>Pool connection</span><span class='chip warn' id='conn'>...</span></div>"
"<div class='big' id='rate'>-</div>"
"<div class='row'><span>Pool</span><span id='pool'>-</span></div>"
"<div class='row'><span>Job</span><span id='job'>-</span></div>"
"<div class='row'><span>Shares found / sent</span><span id='shares'>-</span></div>"
"<div class='row'><span>Last share</span><span id='last'>-</span></div>"
"<div class='row'><span>Miner uptime</span><span id='up'>-</span></div>"
"</div>"
"<div class='card'>"
"<div class='row'><span>OdoCrypt epoch key</span><span id='epoch'>-</span></div>"
"<div class='row'><span>Next shapechange</span><span id='roll'>-</span></div>"
"<div id='bar'><div id='barfill'></div></div>"
"</div>"
"<div class='card'>"
"<div class='row'><span>Board IP</span><span id='ip'>-</span></div>"
"<div class='row'><span>CPU load (1m)</span><span id='load'>-</span></div>"
"<div class='row'><span>Memory free</span><span id='mem'>-</span></div>"
"<div class='row'><span>System uptime</span><span id='sysup'>-</span></div>"
"</div>"
"<div class='card'>"
"<b style='font-size:14px'>WiFi</b>"
"<div class='row'><span>Adapter</span><span id='w_if'>-</span></div>"
"<div class='row'><span>Network</span><span id='w_ssid'>-</span></div>"
"<div class='row'><span>WiFi IP</span><span id='w_ip'>-</span></div>"
"<form method='POST' action='/wifi'>"
"<label>SSID</label><input type='text' name='ssid' id='w_in' list='ssids'>"
"<datalist id='ssids'></datalist>"
"<label>Password (empty for open network)</label><input type='password' name='psk'>"
"<button type='submit' onclick='return confirm(\"Save WiFi settings and reconnect?\")'>Save &amp; connect</button>"
"<button type='button' id='scanbtn' onclick='scanWifi()'>Scan networks</button>"
"</form></div>"
"<div class='card'><form method='POST' action='/config'>"
"<b style='font-size:14px'>Pool configuration</b>"
"<label>Host</label><input type='text' name='host' id='c_host'>"
"<label>Port</label><input type='text' name='port' id='c_port'>"
"<label>Worker / payout address</label><input type='text' name='worker' id='c_worker'>"
"<label>Password</label><input type='password' name='pass' value='x'>"
"<label><input type='checkbox' name='testnet' value='1' style='width:auto'> testnet (1-day epochs)</label>"
"<button type='submit' onclick='return confirm(\"Save config and restart the miner?\")'>Save &amp; restart miner</button>"
"</form>"
"<form method='POST' action='/action' style='display:inline'>"
"<input type='hidden' name='action' value='restart'>"
"<button onclick='return confirm(\"Restart the miner?\")'>Restart miner</button></form>"
"<form method='POST' action='/action' style='display:inline'>"
"<input type='hidden' name='action' value='reboot'>"
"<button class='danger' onclick='return confirm(\"Reboot the whole board?\")'>Reboot board</button></form>"
"</div>"
"<script>"
"function fmtRate(h){if(h>=1e6)return (h/1e6).toFixed(2)+' MH/s';"
"if(h>=1e3)return (h/1e3).toFixed(1)+' kH/s';return h.toFixed(0)+' H/s';}"
"function fmtDur(s){if(s<0)return '-';var d=Math.floor(s/86400),h=Math.floor(s%86400/3600),"
"m=Math.floor(s%3600/60);return (d?d+'d ':'')+(h?h+'h ':'')+m+'m';}"
"function tick(){fetch('/status.json').then(r=>r.json()).then(s=>{"
"var now=Math.floor(Date.now()/1000);"
"document.getElementById('rate').textContent=fmtRate(s.hashrate||0);"
"document.getElementById('pool').textContent=s.pool||'-';"
"document.getElementById('job').textContent=s.job_id||'-';"
"document.getElementById('shares').textContent=(s.shares_found||0)+' / '+(s.shares_submitted||0);"
"document.getElementById('last').textContent=s.last_share?fmtDur(now-s.last_share)+' ago':'never';"
"document.getElementById('up').textContent=fmtDur(s.uptime||0);"
"document.getElementById('epoch').textContent=s.epoch||'-';"
"var c=document.getElementById('conn');"
"var stale=!s.updated||now-s.updated>120;"
"c.textContent=stale?'MINER DOWN':(s.connected?'CONNECTED':'OFFLINE');"
"c.className='chip '+(stale?'bad':(s.connected?'ok':'warn'));"
"if(s.epoch&&s.epoch_interval&&s.epoch_next){"
"var left=s.epoch_next-now,frac=1-left/s.epoch_interval;"
"document.getElementById('roll').textContent="
"left<=0?'ROLLING NOW — new tables load with the next job':fmtDur(left)+' from now';"
"document.getElementById('barfill').style.width=Math.max(0,Math.min(100,frac*100))+'%';}"
"if(!document.getElementById('c_host').value&&s.pool){"
"var p=s.pool.split(':');document.getElementById('c_host').value=p[0]||'';"
"document.getElementById('c_port').value=p[1]||'';}"
"}).catch(()=>{});"
"fetch('/sysinfo.json').then(r=>r.json()).then(i=>{"
"document.getElementById('ip').textContent=i.ip||'-';"
"document.getElementById('host').textContent=i.ip?('http://'+i.ip):'';"
"document.getElementById('load').textContent=i.load1!==undefined?i.load1.toFixed(2):'-';"
"document.getElementById('mem').textContent=i.mem_free_mb!==undefined?i.mem_free_mb+' MB':'-';"
"document.getElementById('sysup').textContent=fmtDur(i.sys_uptime||0);"
"}).catch(()=>{});"
"fetch('/wifi.json').then(r=>r.json()).then(w=>{"
"document.getElementById('w_if').textContent=w.present?'wlan0':'not detected';"
"document.getElementById('w_ssid').textContent=w.ssid||'not connected';"
"document.getElementById('w_ip').textContent=w.ip||'-';"
"}).catch(()=>{});}"
"function scanWifi(){var b=document.getElementById('scanbtn');"
"b.disabled=true;b.textContent='Scanning...';"
"fetch('/wifiscan.json').then(r=>r.json()).then(j=>{"
"var d=document.getElementById('ssids');d.innerHTML='';"
"(j.ssids||[]).forEach(s=>{var o=document.createElement('option');o.value=s;d.appendChild(o);});"
"b.textContent=(j.ssids&&j.ssids.length)?'Scan again ('+j.ssids.length+' found)':'Scan networks';"
"b.disabled=false;}).catch(()=>{b.textContent='Scan failed';b.disabled=false;});}"
"tick();setInterval(tick,3000);"
"</script></body></html>";

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
    form_get(body, "host", host, sizeof(host));
    form_get(body, "port", port, sizeof(port));
    form_get(body, "worker", worker, sizeof(worker));
    form_get(body, "pass", pass, sizeof(pass));
    form_get(body, "testnet", testnet, sizeof(testnet));

    if (!host[0] || !port[0] || !worker[0] ||
        !value_safe(host) || !value_safe(port) ||
        !value_safe(worker) || !value_safe(pass)) {
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
        "ODOD_WORKER=%s\nODOD_PASSWORD=%s\nODO_TESTNET=%s\n",
        host, port, worker, pass[0] ? pass : "x",
        testnet[0] == '1' ? "1" : "0");
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

        /* For POSTs, make sure we have the whole body (Content-Length) */
        char *body = strstr(req, "\r\n\r\n");
        if (body) {
            body += 4;
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
            send_response(fd, "200 OK", "text/html", PAGE, sizeof(PAGE) - 1);
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
