#include "toylink.h"

#include <SD.h>
#include <WiFi.h>
#include <esp_http_server.h>

#include "audio.h"
#include "config.h"
#include "library.h"
#include "log.h"
#include "sdfs.h"

namespace toylink {
namespace {

httpd_handle_t g_server = nullptr;
bool g_active = false;
bool g_stopWanted = false;
char g_ssid[24] = {0};
uint32_t g_lastRequestAt = 0;
uint32_t g_wrote = 0;

// One request is served at a time, so one buffer is enough. 4 KB on the heap
// rather than the httpd task's stack, which has the SD driver on it too.
uint8_t *g_buffer = nullptr;

void touch() { g_lastRequestAt = millis(); }

// ------------------------------------------------------------------ paths

int hexValue(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

void urlDecode(const char *in, char *out, size_t len) {
  size_t o = 0;
  for (size_t i = 0; in[i] && o + 1 < len; i++) {
    if (in[i] == '%' && hexValue(in[i + 1]) >= 0 && hexValue(in[i + 2]) >= 0) {
      out[o++] = (char)(hexValue(in[i + 1]) * 16 + hexValue(in[i + 2]));
      i += 2;
    } else if (in[i] == '+') {
      out[o++] = ' ';
    } else {
      out[o++] = in[i];
    }
  }
  out[o] = '\0';
}

// An absolute path on the card and nothing else. ".." is the whole reason this
// function exists: the AP is open to whoever knows the password, and a path
// that can climb out of the card is a path to the rest of the flash.
bool safe(const char *path) {
  if (!path || path[0] != '/' || strlen(path) >= LINK_PATH_MAX) {
    return false;
  }
  if (strstr(path, "..") || strchr(path, '\\')) {
    return false;
  }
  return true;
}

// The `path` query parameter, decoded and vetted. Answers the request itself
// when it is missing or unsafe, so callers just return ESP_OK.
bool wantedPath(httpd_req_t *req, char *out, size_t len) {
  char query[LINK_PATH_MAX * 3];
  char raw[LINK_PATH_MAX * 3];

  if (httpd_req_get_url_query_str(req, query, sizeof(query)) != ESP_OK ||
      httpd_query_key_value(query, "path", raw, sizeof(raw)) != ESP_OK) {
    httpd_resp_set_status(req, "400 Bad Request");
    httpd_resp_sendstr(req, "{\"error\":\"no path\"}");
    return false;
  }
  urlDecode(raw, out, len);
  if (!safe(out)) {
    LOGE("link: refused path '%s'", out);
    httpd_resp_set_status(req, "400 Bad Request");
    httpd_resp_sendstr(req, "{\"error\":\"bad path\"}");
    return false;
  }
  return true;
}

// Every directory above `path`, created if it is not there yet. The app writes
// /audio/en/bear.wav to a blank card and expects both folders to appear.
bool ensureParents(const char *path) {
  char work[LINK_PATH_MAX];
  strncpy(work, path, sizeof(work) - 1);
  work[sizeof(work) - 1] = '\0';

  for (char *slash = strchr(work + 1, '/'); slash; slash = strchr(slash + 1, '/')) {
    *slash = '\0';
    if (!SD.exists(work) && !SD.mkdir(work)) {
      LOGE("link: could not create %s", work);
      return false;
    }
    *slash = '/';
  }
  return true;
}

void appendEscaped(String &out, const char *text) {
  for (const char *c = text; *c; c++) {
    if (*c == '"' || *c == '\\') {
      out += '\\';
      out += *c;
    } else if ((unsigned char)*c < 0x20) {
      out += ' ';
    } else {
      out += *c;
    }
  }
}

// SD.open().name() gives the whole path on some core versions and the last
// segment on others; library.cpp takes the same precaution.
const char *baseName(const char *path) {
  const char *slash = strrchr(path, '/');
  return slash ? slash + 1 : path;
}

esp_err_t fail(httpd_req_t *req, const char *status, const char *message) {
  httpd_resp_set_status(req, status);
  httpd_resp_set_type(req, "application/json");
  String body = "{\"error\":\"";
  appendEscaped(body, message);
  body += "\"}";
  httpd_resp_sendstr(req, body.c_str());
  return ESP_OK;
}

// --------------------------------------------------------------- handlers

esp_err_t handleInfo(httpd_req_t *req) {
  touch();
  if (!sdfs::mounted()) {
    return fail(req, "503 Service Unavailable", "no card in the toy");
  }

  // f_getfree walks the whole FAT the first time it is asked, which on a 32 GB
  // card over SPI is a few seconds. It is cached afterwards, and the app only
  // asks once per connection, so this is the right place to pay for it.
  uint64_t total = 0;
  uint64_t used = 0;
  {
    sdfs::Guard guard;
    total = SD.totalBytes();
    used = SD.usedBytes();
  }

  String body = "{\"name\":\"";
  appendEscaped(body, g_ssid);
  body += "\",\"freeBytes\":";
  body += String((unsigned long long)(total > used ? total - used : 0));
  body += ",\"totalBytes\":";
  body += String((unsigned long long)total);
  body += ",\"languages\":";
  body += String((unsigned)library::languages().size());
  body += "}";

  httpd_resp_set_type(req, "application/json");
  httpd_resp_sendstr(req, body.c_str());
  return ESP_OK;
}

esp_err_t handleList(httpd_req_t *req) {
  touch();
  char path[LINK_PATH_MAX];
  if (!wantedPath(req, path, sizeof(path))) {
    return ESP_OK;
  }

  sdfs::Guard guard;
  File dir = SD.exists(path) ? SD.open(path) : File();
  if (!dir || !dir.isDirectory()) {
    if (dir) dir.close();
    // A folder that is not there yet is not an error: the app asks about
    // /system on cards that have never had one.
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "[]");
    return ESP_OK;
  }

  httpd_resp_set_type(req, "application/json");
  httpd_resp_send_chunk(req, "[", 1);

  bool first = true;
  for (File entry = dir.openNextFile(); entry; entry = dir.openNextFile()) {
    String item = first ? "" : ",";
    first = false;
    item += "{\"name\":\"";
    appendEscaped(item, baseName(entry.name()));
    item += "\",\"isDirectory\":";
    item += entry.isDirectory() ? "true" : "false";
    item += ",\"size\":";
    item += String((unsigned long)entry.size());
    item += "}";
    entry.close();
    httpd_resp_send_chunk(req, item.c_str(), item.length());
  }
  dir.close();

  httpd_resp_send_chunk(req, "]", 1);
  httpd_resp_send_chunk(req, nullptr, 0);
  return ESP_OK;
}

esp_err_t handleRead(httpd_req_t *req) {
  touch();
  char path[LINK_PATH_MAX];
  if (!wantedPath(req, path, sizeof(path))) {
    return ESP_OK;
  }

  sdfs::Guard guard;
  File file = SD.exists(path) ? SD.open(path, FILE_READ) : File();
  if (!file || file.isDirectory()) {
    if (file) file.close();
    return fail(req, "404 Not Found", "no such file on the card");
  }

  httpd_resp_set_type(req, "application/octet-stream");
  while (true) {
    const int n = file.read(g_buffer, LINK_CHUNK_BYTES);
    if (n <= 0) {
      break;
    }
    if (httpd_resp_send_chunk(req, (const char *)g_buffer, n) != ESP_OK) {
      file.close();
      LOGE("link: %s cut short, the phone went away", path);
      return ESP_FAIL;
    }
  }
  file.close();
  httpd_resp_send_chunk(req, nullptr, 0);
  return ESP_OK;
}

esp_err_t handleWrite(httpd_req_t *req) {
  touch();
  char path[LINK_PATH_MAX];
  if (!wantedPath(req, path, sizeof(path))) {
    return ESP_OK;
  }
  if (!sdfs::mounted()) {
    return fail(req, "503 Service Unavailable", "no card in the toy");
  }

  sdfs::Guard guard;
  if (!ensureParents(path)) {
    return fail(req, "500 Internal Server Error", "could not create the folder");
  }

  // FILE_WRITE truncates, but a replaced clip is usually shorter than the one
  // it replaces and a stale tail would play as noise. Removing first is the one
  // way to be sure of what is on the card afterwards — and only when there is
  // something to remove, or the VFS layer logs an error for every new file.
  if (SD.exists(path)) {
    SD.remove(path);
  }
  File file = SD.open(path, FILE_WRITE);
  if (!file) {
    return fail(req, "500 Internal Server Error", "could not open the file for writing");
  }

  uint32_t written = 0;
  int remaining = req->content_len;
  while (remaining > 0) {
    const int wanted = remaining < (int)LINK_CHUNK_BYTES ? remaining : (int)LINK_CHUNK_BYTES;
    const int received = httpd_req_recv(req, (char *)g_buffer, wanted);
    if (received == HTTPD_SOCK_ERR_TIMEOUT) {
      continue;  // slow phone, not a broken one
    }
    if (received <= 0) {
      file.close();
      SD.remove(path);  // half a clip is worse than none: the toy would play static
      LOGE("link: %s failed mid-write", path);
      return ESP_FAIL;
    }
    if ((int)file.write(g_buffer, received) != received) {
      file.close();
      SD.remove(path);
      return fail(req, "507 Insufficient Storage", "the card would not take it");
    }
    remaining -= received;
    written += received;
    touch();
  }
  // Count what came through rather than asking the file: size() stats the path,
  // and nothing is on the card to stat until close() flushes.
  file.close();
  g_wrote++;

  LOGI("link: wrote %s (%u B)", path, (unsigned)written);
  httpd_resp_set_type(req, "application/json");
  String body = "{\"bytes\":";
  body += String((unsigned long)written);
  body += "}";
  httpd_resp_sendstr(req, body.c_str());
  return ESP_OK;
}

esp_err_t handleDelete(httpd_req_t *req) {
  touch();
  char path[LINK_PATH_MAX];
  if (!wantedPath(req, path, sizeof(path))) {
    return ESP_OK;
  }

  sdfs::Guard guard;
  const bool gone = SD.exists(path) && SD.remove(path);
  if (gone) {
    LOGI("link: removed %s", path);
  }
  httpd_resp_set_type(req, "application/json");
  httpd_resp_sendstr(req, gone ? "{\"deleted\":true}" : "{\"deleted\":false}");
  return ESP_OK;
}

esp_err_t handleDone(httpd_req_t *req) {
  touch();
  httpd_resp_set_type(req, "application/json");
  httpd_resp_sendstr(req, "{\"bye\":true}");
  // Never stop the server from inside its own task — loop() does it.
  g_stopWanted = true;
  return ESP_OK;
}

const httpd_uri_t kRoutes[] = {
    {"/info", HTTP_GET, handleInfo, nullptr},
    {"/list", HTTP_GET, handleList, nullptr},
    {"/read", HTTP_GET, handleRead, nullptr},
    {"/write", HTTP_PUT, handleWrite, nullptr},
    {"/delete", HTTP_DELETE, handleDelete, nullptr},
    {"/done", HTTP_POST, handleDone, nullptr},
};

}  // namespace

// ------------------------------------------------------------------- api

bool active() { return g_active; }

const char *ssid() { return g_ssid; }

bool start() {
  if (g_active) {
    return true;
  }
  // The card is mounted once at boot; one pushed in since, or reseated after a
  // failed boot, only shows up if someone asks again.
  if (!sdfs::mounted() && !sdfs::begin()) {
    LOGE("link: no card mounted, nothing to write to");
    return false;
  }

  // The radio wants a good 40 kB of heap, and a story playing into a stopped
  // decoder is not what anyone wants mid-transfer.
  audio::stop();

  if (!g_buffer) {
    g_buffer = (uint8_t *)malloc(LINK_CHUNK_BYTES);
    if (!g_buffer) {
      LOGE("link: no room for the transfer buffer");
      return false;
    }
  }

  uint8_t mac[6] = {0};
  WiFi.macAddress(mac);
  snprintf(g_ssid, sizeof(g_ssid), "%s%02X%02X", LINK_AP_PREFIX, mac[4], mac[5]);

  WiFi.mode(WIFI_AP);
  if (!WiFi.softAP(g_ssid, LINK_AP_PASSWORD, LINK_AP_CHANNEL, false, 1)) {
    LOGE("link: could not start the access point");
    WiFi.mode(WIFI_OFF);
    return false;
  }

  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.stack_size = 8192;  // the SD driver runs on this task's stack
  config.max_uri_handlers = sizeof(kRoutes) / sizeof(kRoutes[0]);
  config.max_open_sockets = 3;
  config.lru_purge_enable = true;
  config.recv_wait_timeout = 15;
  config.send_wait_timeout = 15;

  if (httpd_start(&g_server, &config) != ESP_OK) {
    LOGE("link: could not start the server");
    WiFi.softAPdisconnect(true);
    WiFi.mode(WIFI_OFF);
    g_server = nullptr;
    return false;
  }
  for (const httpd_uri_t &route : kRoutes) {
    httpd_register_uri_handler(g_server, &route);
  }

  g_active = true;
  g_stopWanted = false;
  g_wrote = 0;
  touch();

  LOGI("link: '%s' up, password '%s'", g_ssid, LINK_AP_PASSWORD);
  LOGI("link: open Bookie Studio and connect, or browse http://%s/info",
       WiFi.softAPIP().toString().c_str());
  LOGI("link: any button stops it, and so does %u minutes of quiet",
       (unsigned)(LINK_IDLE_MS / 60000));
  return true;
}

void stop() {
  if (!g_active) {
    return;
  }
  if (g_server) {
    httpd_stop(g_server);
    g_server = nullptr;
  }
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_OFF);
  g_active = false;
  g_stopWanted = false;

  free(g_buffer);
  g_buffer = nullptr;

  LOGI("link: down, %u file%s written", (unsigned)g_wrote, g_wrote == 1 ? "" : "s");

  // Whatever arrived is on the card but not in the index yet: languages,
  // tag names and clip paths all come from a scan done at boot.
  library::begin();
}

void poll() {
  if (!g_active) {
    return;
  }
  if (g_stopWanted) {
    LOGI("link: the app said it is finished");
    stop();
    return;
  }
  if (LINK_IDLE_MS && millis() - g_lastRequestAt > LINK_IDLE_MS) {
    LOGI("link: nothing asked for anything in %u minutes", (unsigned)(LINK_IDLE_MS / 60000));
    stop();
  }
}

}  // namespace toylink
