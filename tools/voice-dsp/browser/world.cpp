// Research-only C ABI. Same WORLD sources/options as PyWORLD 0.3.5.
#include <algorithm>
#include <cmath>
#include <vector>
#include "world/harvest.h"
#include "world/cheaptrick.h"
#include "world/d4c.h"
#include "world/synthesis.h"

namespace {
constexpr int capacity = 16384;
std::vector<double> input(capacity), output(capacity + 240);
double pitch = 1, scale = 1;
}
extern "C" {
int dsp_new(double semitones, double formants) {
  if (!std::isfinite(semitones) || !std::isfinite(formants) || formants < .5 || formants > 2) return 0;
  pitch = std::pow(2., semitones / 12.); scale = formants; return 1;
}
double *dsp_input() { return input.data(); }
double *dsp_output() { return output.data(); }
int dsp_input_latency() { return 0; }
int dsp_output_latency() { return 0; }
int dsp_flush(int) { return 0; }
void dsp_close() {}
int dsp_process(int length) {
  if (length < 240 || length > capacity) return -1;
  try {
    HarvestOption harvest; InitializeHarvestOption(&harvest);
    harvest.f0_floor = 50; harvest.f0_ceil = 800; harvest.frame_period = 5;
    int frames = GetSamplesForHarvest(48000, length, 5);
    std::vector<double> f0(frames), positions(frames);
    Harvest(input.data(), length, 48000, &harvest, positions.data(), f0.data());
    CheapTrickOption cheap; InitializeCheapTrickOption(48000, &cheap);
    cheap.f0_floor = 50; cheap.fft_size = GetFFTSizeForCheapTrick(48000, &cheap);
    int bins = cheap.fft_size / 2 + 1;
    std::vector<std::vector<double>> spectrum(frames, std::vector<double>(bins)), noise = spectrum;
    std::vector<double*> sp(frames), ap(frames);
    for (int i = 0; i < frames; ++i) { sp[i] = spectrum[i].data(); ap[i] = noise[i].data(); }
    CheapTrick(input.data(), length, 48000, positions.data(), f0.data(), frames, &cheap, sp.data());
    D4COption d4c; InitializeD4COption(&d4c);
    D4C(input.data(), length, 48000, positions.data(), f0.data(), frames, cheap.fft_size, &d4c, ap.data());
    std::vector<double> logPower(bins);
    for (int i = 0; i < frames; ++i) {
      for (int b = 0; b < bins; ++b) logPower[b] = std::log(std::max(spectrum[i][b], 1e-12));
      for (int b = 0; b < bins; ++b) {
        double position = std::min(b / scale, double(bins - 1));
        int left = int(position), right = std::min(left + 1, bins - 1);
        spectrum[i][b] = std::exp(logPower[left] + (position - left) * (logPower[right] - logPower[left]));
      }
      f0[i] *= pitch;
    }
    int count = frames * 240;
    if (count > int(output.size())) return -1;
    Synthesis(f0.data(), frames, sp.data(), ap.data(), cheap.fft_size, 5, 48000, count, output.data());
    return count;
  } catch (...) { return -1; }
}
}
