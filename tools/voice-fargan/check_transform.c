// File-only check against upstream dct(); stdin owns this short-lived child.
#include "config.h"
#include "freq.h"
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void *watch_parent(void *unused) {
  (void)unused;
  for (;;) {
    char byte;
    const ssize_t n = read(STDIN_FILENO, &byte, 1);
    if (n == 0 || (n < 0 && errno != EINTR)) _Exit(72);
  }
}
int main(int argc, char **argv) {
  pthread_t watcher;
  if (pthread_create(&watcher, NULL, watch_parent, NULL) || pthread_detach(watcher)) return 2;
  if (argc != 3) return 2;
  FILE *in = fopen(argv[1], "rb"), *out = fopen(argv[2], "wb");
  if (!in || !out) return 2;
  for (;;) {
    float x[NB_BANDS], y[NB_BANDS];
    const size_t n = fread(x, sizeof(float), NB_BANDS, in);
    if (!n && feof(in)) break;
    if (n != NB_BANDS) return 3;
    for (int i = 0; i < NB_BANDS; ++i) if (!isfinite(x[i])) return 3;
    dct(y, x);
    for (int i = 0; i < NB_BANDS; ++i) if (!isfinite(y[i])) return 4;
    if (fwrite(y, sizeof(float), NB_BANDS, out) != NB_BANDS) return 4;
  }
  if (ferror(in) || fclose(in) || fclose(out)) return 4;
  return 0;
}
