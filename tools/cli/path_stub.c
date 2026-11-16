/* UTF-8 directory bridge for MoonLSM's narrow-path CRT IO on Windows.
 * Only entered during synchronous engine operations; restored before awaits.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#else
#include <unistd.h>
#include <time.h>
#endif
int32_t orderkey_chdir(const uint8_t *bytes, int32_t length) {
#ifdef _WIN32
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char*)bytes, length, NULL, 0);
  if (!n) return -1;
  wchar_t *path = (wchar_t*)calloc((size_t)n + 1, sizeof(wchar_t));
  if (!path) return -1;
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char*)bytes, length, path, n);
  int rc = _wchdir(path);
#else
  char *path = (char*)calloc((size_t)length + 1, 1);
  if (!path) return -1;
  memcpy(path, bytes, (size_t)length);
  int rc = chdir(path);
#endif
  free(path);
  return rc;
}

void orderkey_pause(int32_t ms) {
#ifdef _WIN32
  Sleep((DWORD)ms);
#else
  struct timespec delay = { ms / 1000, (ms % 1000) * 1000000L };
  nanosleep(&delay, NULL);
#endif
}
