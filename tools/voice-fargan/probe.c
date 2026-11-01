/* Copyright (c) 2018 Mozilla */
/*
   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions
   are met:

   - Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

   - Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
   ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
   A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
   CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
   EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
   PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

/* Research-only float-output driver for pinned Opus FARGAN. Not product code.
 * Initialization/drain follows upstream dnn/fargan_demo.c; float output avoids
 * its int16 saturation. Files only, no device capture, stdin owns lifetime. */
#include "config.h"
#include "lpcnet.h"
#include "fargan.h"
#include "cpu_support.h"
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

static void *watch_parent(void *unused) {
  (void)unused;
  for (;;) {
    char byte;
    const ssize_t n = read(STDIN_FILENO, &byte, 1);
    if (n == 0 || (n < 0 && errno != EINTR)) _Exit(72);
  }
}
static double now(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) exit(2);
  return t.tv_sec + t.tv_nsec * 1e-9;
}
static int output(FILE *file, const float *pcm, int start, int count) {
  for (int i = start; i < start + count; ++i) if (!isfinite(pcm[i])) return 0;
  return fwrite(pcm + start, sizeof(*pcm), count, file) == (size_t)count;
}
int main(int argc, char **argv) {
  pthread_t watcher;
  if (pthread_create(&watcher, NULL, watch_parent, NULL) || pthread_detach(watcher)) return 2;
  if (argc == 2 && !strcmp(argv[1], "--wait-for-eof")) for (;;) pause();
  if (argc != 4) return 2;
  FILE *in = fopen(argv[2], "rb"), *out = fopen(argv[3], "wb");
  if (!in || !out) return 2;
  const double start = now();
  double initialized;
  size_t frames = 0;
  if (!strcmp(argv[1], "features")) {
    LPCNetEncState *state = lpcnet_encoder_create();
    if (!state) return 2;
    const int arch = opus_select_arch();
    initialized = now();
    for (;;) {
      opus_int16 pcm[LPCNET_FRAME_SIZE];
      float features[NB_TOTAL_FEATURES];
      const size_t n = fread(pcm, sizeof(*pcm), LPCNET_FRAME_SIZE, in);
      if (!n && feof(in)) break;
      if (n != LPCNET_FRAME_SIZE) return 3;
      lpcnet_compute_single_frame_features(state, pcm, features, arch);
      if (!output(out, features, 0, NB_FEATURES)) return 4;
      ++frames;
    }
    lpcnet_encoder_destroy(state);
  } else if (!strcmp(argv[1], "synthesize")) {
    FARGANState state;
    float initial[5 * NB_FEATURES], last[NB_FEATURES], pcm[FARGAN_FRAME_SIZE];
    const float zeros[FARGAN_CONT_SAMPLES] = {0};
    if (fread(initial, sizeof(float), NB_FEATURES, in) != NB_FEATURES) return 3;
    for (int i = 0; i < NB_FEATURES; ++i) if (!isfinite(initial[i])) return 3;
    for (int i = 1; i < 5; ++i) memcpy(initial + i * NB_FEATURES, initial, NB_FEATURES * sizeof(float));
    memcpy(last, initial, sizeof(last));
    fargan_init(&state);
    fargan_cont(&state, zeros, initial);
    initialized = now();
    int skip = FARGAN_FRAME_SIZE / 2;
    for (;;) {
      float next[NB_FEATURES];
      const size_t n = fread(next, sizeof(float), NB_FEATURES, in);
      if (!n && feof(in)) break;
      if (n != NB_FEATURES) return 3;
      for (int i = 0; i < NB_FEATURES; ++i) if (!isfinite(next[i])) return 3;
      memcpy(last, next, sizeof(last));
      fargan_synthesize(&state, pcm, last);
      if (!output(out, pcm, skip, FARGAN_FRAME_SIZE - skip)) return 4;
      skip = 0; ++frames;
    }
    // Preserve the upstream two ending iterations and initial 80-sample crop.
    fargan_synthesize(&state, pcm, last);
    if (!output(out, pcm, skip, FARGAN_FRAME_SIZE - skip)) return 4;
    fargan_synthesize(&state, pcm, last);
    if (!output(out, pcm, 0, FARGAN_FRAME_SIZE / 2)) return 4;
    ++frames;
  } else return 2;
  if (ferror(in) || fclose(in) || fclose(out) || !frames) return 4;
  const double end = now();
  struct rusage usage;
  if (getrusage(RUSAGE_SELF, &usage)) return 2;
#ifdef __APPLE__
  const long rss_bytes = usage.ru_maxrss;
#else
  const long rss_bytes = usage.ru_maxrss * 1024;
#endif
  fprintf(stderr, "{\"frames\":%zu,\"init_ms\":%.6f,\"processing_ms\":%.6f,\"total_ms\":%.6f,\"peak_rss_bytes\":%ld}\n",
          frames, (initialized - start) * 1000, (end - initialized) * 1000,
          (end - start) * 1000, rss_bytes);
  return 0;
}
