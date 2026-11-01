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

/* Research-only 48 kHz frame ABI around Opus FARGAN and SILK resamplers.
 * No devices, files or network; one private instance per Worker. */
#include "config.h"
#include "lpcnet.h"
#include "fargan.h"
#include "cpu_support.h"
#include "silk/SigProc_FIX.h"
#include <math.h>
#include <string.h>

static LPCNetEncState *encoder;
static FARGANState synthesis;
static silk_resampler_state_struct down, up;
static float input[960], output[2048], feature_in[20], feature_out[20];
static float last[20], basis[18][18];
static double pitch, scale;
static int initialized, ended, skip, skipped, emitted;
static const double hz[18] = {0,200,400,600,800,1000,1200,1400,1600,2000,2400,2800,3200,4000,4800,5600,6800,8000};
static const double compensation[18] = {.8,1,1,1,1,1,1,1,.666667,.5,.5,.5,.333333,.25,.25,.2,.166667,.173913};
static int fault(int code) { ended=1; memset(output,0,sizeof(output)); return code; }

float *fg_input(void) { return input; }
float *fg_output(void) { return output; }
float *fg_feature_input(void) { return feature_in; }
float *fg_feature_output(void) { return feature_out; }
int fg_skipped(void) { return skipped; }
int fg_down_delay(void) { return down.inputDelay; }
int fg_up_delay(void) { return up.inputDelay; }
void fg_close(void) {
  if (encoder) lpcnet_encoder_destroy(encoder);
  encoder = NULL;
  memset(&down,0,sizeof(down)); memset(&up,0,sizeof(up));
  memset(&synthesis,0,sizeof(synthesis));
  memset(input,0,sizeof(input)); memset(output,0,sizeof(output));
  memset(last,0,sizeof(last)); memset(feature_in,0,sizeof(feature_in)); memset(feature_out,0,sizeof(feature_out));
  initialized=0; ended=1;
}
int fg_new(double p, double s) {
  fg_close();
  if (!((p==0 && s==1)||(p==-1 && s==.8)||(p==1 && s==1.25))) return 0;
  encoder=lpcnet_encoder_create();
  if (!encoder) return 0;
  if (silk_resampler_init(&down,48000,16000,1) || silk_resampler_init(&up,16000,48000,0)) { fg_close(); return 0; }
  fargan_init(&synthesis);
  for (int i=0;i<18;++i) {
    float unit[18]={0}; unit[i]=1;
    dct(basis[i],unit);
  }
  pitch=p; scale=s; ended=0; skip=80; skipped=0;
  return 1;
}
int fg_edit(void) {
  if (!encoder || ended) return -1;
  for (int i=0;i<20;++i) if (!isfinite(feature_in[i])) return -1;
  memcpy(feature_out,feature_in,sizeof(feature_in));
  if (pitch) {
    const float proposed=feature_in[18]+(float)(pitch/12);
    const double period=floor(.5+256/exp2((double)proposed+1.5));
    if (period>=32 && period<=256) feature_out[18]=proposed; else ++skipped;
  }
  if (scale!=1) {
    double density[18], warped[18];
    for (int j=0;j<18;++j) {
      double value=0;
      for (int i=0;i<18;++i) value+=((double)feature_in[i]+(i==0?4:0))*basis[j][i];
      density[j]=value+log10(compensation[j]);
    }
    for (int j=0;j<18;++j) {
      const double f=hz[j];
      const double mapped=f<=4000?f/scale:4000/scale+(f-4000)*(8000-4000/scale)/4000;
      int lo=0; while (lo<16 && hz[lo+1]<mapped) ++lo;
      const double ratio=(mapped-hz[lo])/(hz[lo+1]-hz[lo]);
      warped[j]=density[lo]+ratio*(density[lo+1]-density[lo])-log10(compensation[j]);
    }
    for (int i=1;i<18;++i) {
      double value=0; for (int j=0;j<18;++j) value+=warped[j]*basis[j][i];
      feature_out[i]=(float)value;
    }
  }
  for (int i=0;i<20;++i) if (!isfinite(feature_out[i])) return -1;
  return 1;
}
static int write_audio(const float *pcm,int n) {
  opus_int16 quantized[160], converted[480];
  if (emitted+n*3>2048) return -3;
  for (int i=0;i<n;++i) {
    if (!isfinite(pcm[i]) || fabsf(pcm[i])>=1) return -4;
    const float q=floorf(.5f+pcm[i]*32768);
    if (q>32767 || q<-32768) return -4;
    quantized[i]=(opus_int16)q;
  }
  if (silk_resampler(&up,converted,quantized,n)) return -5;
  for (int i=0;i<n*3;++i) output[emitted++]=converted[i]/32768.f;
  return 0;
}
int fg_process(int n) {
  if (!encoder || ended || (n!=480 && n!=960)) return -1;
  emitted=0;
  for (int start=0;start<n;start+=480) {
    opus_int16 pcm[480], small[160];
    float features[NB_TOTAL_FEATURES], audio[160];
    for (int i=0;i<480;++i) {
      float v=input[start+i];
      if (!isfinite(v) || fabsf(v)>=1) return fault(-4);
      const float q=floorf(.5f+32768*v);
      if (q>32767 || q<-32768) return fault(-4);
      pcm[i]=(opus_int16)q;
    }
    if (silk_resampler(&down,small,pcm,480)) return fault(-5);
    lpcnet_compute_single_frame_features(encoder,small,features,opus_select_arch());
    memcpy(feature_in,features,sizeof(feature_in));
    if (fg_edit()!=1) return fault(-6);
    memcpy(last,feature_out,sizeof(last));
    if (!initialized) {
      float initial[100], zeros[320]={0};
      for (int i=0;i<5;++i) memcpy(initial+i*20,last,sizeof(last));
      fargan_cont(&synthesis,zeros,initial); initialized=1; continue;
    }
    fargan_synthesize(&synthesis,audio,last);
    const int result=write_audio(audio+skip,160-skip); skip=0;
    if (result) return fault(result);
  }
  return emitted;
}
int fg_finish(void) {
  if (!encoder || ended || !initialized) return -1;
  emitted=0;
  float audio[160];
  fargan_synthesize(&synthesis,audio,last);
  int result=write_audio(audio+skip,160-skip);
  if (result) return fault(result);
  fargan_synthesize(&synthesis,audio,last);
  result=write_audio(audio,80); ended=1;
  return result?fault(result):emitted;
}
