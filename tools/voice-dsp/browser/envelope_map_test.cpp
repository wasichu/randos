// Exercise the actual research lookup, including both untouched boundaries.
#include "envelope_map.h"
#include <cassert>
#include <cerrno>
#include <cstdlib>
#include <initializer_list>
#include <thread>
#include <unistd.h>

int main() {
  // Match the native sanitizer harness: EOF kills the child even after SIGKILL.
  // Raw read avoids a stdio lock during normal libstdc++ exit.
  std::thread([] {
    while (true) {
      char byte;
      const auto status = ::read(STDIN_FILENO, &byte, 1);
      if (status == 0 || (status < 0 && errno != EINTR)) std::_Exit(72);
    }
  }).detach();
  constexpr double cutoff = 4000.0 / 48000;
  for (double scale : {.8, 1.25}) {
    for (double bend : {-.15, 0., .15}) {
      randosResearchBend = bend;
      double previous = -1;
      for (int i = 0; i <= 48000; ++i) {
        const double f = i / 96000.0;
        const double baseline = f / scale;
        const double mapped = randosResearchWarp(f, baseline);
        assert(std::isfinite(mapped) && mapped > previous);
        if (bend == 0 || f == 0 || f >= cutoff) assert(mapped == baseline);
        assert(std::abs(mapped - baseline) * 48000 < 63);
        previous = mapped;
      }
      for (double edge : {0., cutoff}) {
        constexpr double epsilon = 1e-8;
        const double left = randosResearchWarp(edge - epsilon, (edge - epsilon) / scale);
        const double right = randosResearchWarp(edge + epsilon, (edge + epsilon) / scale);
        assert(std::abs((right - left) / (2 * epsilon) - 1 / scale) < 1e-6);
      }
    }
  }
}
