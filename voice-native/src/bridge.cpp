// Each opaque handle owns all DSP and scratch state. No global processor.
#include <array>
#include <cmath>
#include <cstddef>
#include <limits>
#include "signalsmith-stretch.h"

namespace {
constexpr size_t BATCH = 3840;
struct Context {
  signalsmith::stretch::SignalsmithStretch<double> engine{7L};
  std::array<double, BATCH> input{}, output{};
  bool failed = false, finished = false;
  Context(double pitch, double scale) {
    engine.configure(1, 3840, 960, false);
    engine.setTransposeSemitones(pitch);
    engine.setFormantFactor(scale, true);
    engine.setFormantBase(0);
  }
};
}

extern "C" {
void *randos_spectral_new(double pitch, double scale) noexcept {
  if (!std::isfinite(pitch) || !std::isfinite(scale) || pitch < -12 ||
      pitch > 12 || scale < .5 || scale > 2) return nullptr;
  try {
    auto *context = new Context(pitch, scale);
    if (context->engine.inputLatency() != 1920 || context->engine.outputLatency() != 1920) {
      delete context;
      return nullptr;
    }
    return context;
  } catch (...) { return nullptr; }
}

int randos_spectral_process(void *handle, const float *input, float *output,
                            size_t count, bool finish) noexcept {
  auto *context = static_cast<Context *>(handle);
  if (!context || !input || !output) return 0;
  if (context->failed || context->finished || count < 1 || count > BATCH ||
      (finish && count != 1920)) {
    context->failed = true;
    return 0;
  }
  try {
    for (size_t i = 0; i < count; ++i) {
      if (!std::isfinite(input[i])) { context->failed = true; return 0; }
      context->input[i] = input[i];
    }
    const double *in[] = {context->input.data()};
    double *out[] = {context->output.data()};
    if (finish) {
      context->engine.flush(out, static_cast<int>(count));
      context->finished = true;
    } else {
      context->engine.process(in, static_cast<int>(count), out, static_cast<int>(count));
    }
    for (size_t i = 0; i < count; ++i) {
      if (!std::isfinite(context->output[i]) ||
          std::abs(context->output[i]) > std::numeric_limits<float>::max()) {
        context->failed = true;
        return 0;
      }
    }
    for (size_t i = 0; i < count; ++i) output[i] = static_cast<float>(context->output[i]);
    return 1;
  } catch (...) { context->failed = true; return 0; }
}

void randos_spectral_delete(void *handle) noexcept {
  delete static_cast<Context *>(handle);
}
}
