// Research-only stateful phase vocoder; deterministic seed and generic FFT.
#include <cmath>
#include <memory>
#include <vector>
#include "signalsmith-stretch.h"
namespace {
std::unique_ptr<signalsmith::stretch::SignalsmithStretch<double>> stretch;
std::vector<double> input(16384), output(16384);
}
extern "C" {
int dsp_new(double pitch, double scale) {
  if (!std::isfinite(pitch) || !std::isfinite(scale) || scale < .5 || scale > 2) return 0;
  stretch.reset(new signalsmith::stretch::SignalsmithStretch<double>(7L));
  stretch->configure(1, 3840, 960, false);
  stretch->setTransposeSemitones(pitch);
  stretch->setFormantFactor(scale, true);
  stretch->setFormantBase(0);
  return 1;
}
double *dsp_input() { return input.data(); }
double *dsp_output() { return output.data(); }
int dsp_input_latency() { return stretch ? stretch->inputLatency() : 0; }
int dsp_output_latency() { return stretch ? stretch->outputLatency() : 0; }
void dsp_close() { stretch.reset(); }
int dsp_process(int count) {
  if (!stretch || count < 1 || count > int(input.size())) return -1;
  const double *in[] = {input.data()}; double *out[] = {output.data()};
  stretch->process(in, count, out, count);
  return count;
}
int dsp_flush(int count) {
  if (!stretch || count < 0 || count > int(output.size())) return -1;
  double *out[] = {output.data()}; stretch->flush(out, count); return count;
}
}
