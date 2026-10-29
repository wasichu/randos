// Black-box ABI checks under fatal ASan/UBSan, including distinct owners.
#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <memory>
#include <thread>
extern "C" {
void *randos_spectral_new(double, double) noexcept;
int randos_spectral_process(void *, const float *, float *, size_t, bool) noexcept;
void randos_spectral_delete(void *) noexcept;
}
using Owner = std::unique_ptr<void, decltype(&randos_spectral_delete)>;
int main() {
  std::thread([] { std::cin.get(); std::_Exit(72); }).detach();
  if (randos_spectral_new(0, .4) || randos_spectral_new(std::numeric_limits<double>::quiet_NaN(), 1)) return 1;
  Owner a(randos_spectral_new(-1, .8), randos_spectral_delete);
  Owner b(randos_spectral_new(1, 1.25), randos_spectral_delete);
  if (!a || !b) return 2;
  std::array<float, 3840> input{};
  std::array<float, 3842> first{}, second{};
  first.fill(17); second.fill(17);
  for (size_t i = 0; i < input.size(); ++i) input[i] = .2f * std::sin(i * .0576);
  for (int i = 0; i < 12; ++i) {
    if (randos_spectral_process(a.get(), input.data(), first.data() + 1, 3840, false) != 1 ||
        randos_spectral_process(b.get(), input.data(), second.data() + 1, 3840, false) != 1) return 3;
  }
  if (first.front() != 17 || first.back() != 17 || second.front() != 17 || second.back() != 17) return 4;
  double difference = 0;
  for (size_t i = 1; i < 3841; ++i) difference += std::abs(first[i] - second[i]);
  if (difference < .1) return 5;
  a.reset(); // Dropping one owner must not invalidate the other.
  if (randos_spectral_process(b.get(), input.data(), second.data(), 1920, true) != 1) return 6;
  if (randos_spectral_process(b.get(), input.data(), second.data(), 960, false) != 0) return 7;
  Owner c(randos_spectral_new(0, .8), randos_spectral_delete);
  if (!c) return 8;
  if (randos_spectral_process(c.get(), input.data(), second.data(), 3841, false) != 0) return 9;
  if (randos_spectral_process(c.get(), input.data(), second.data(), 960, false) != 0) return 10;
  Owner d(randos_spectral_new(0, 1.25), randos_spectral_delete);
  if (!d) return 11;
  input[0] = std::numeric_limits<float>::infinity();
  if (randos_spectral_process(d.get(), input.data(), second.data(), 960, false) != 0) return 12;
  input[0] = 0;
  if (randos_spectral_process(d.get(), input.data(), second.data(), 960, false) != 0) return 13;
  Owner e(randos_spectral_new(1, 1.25), randos_spectral_delete);
  if (!e) return 14;
  for (size_t i = 0; i < input.size(); ++i)
    input[i] = std::numeric_limits<float>::max() * std::sin(i * .0576);
  for (int i = 0; i < 24; ++i) {
    if (randos_spectral_process(e.get(), input.data(), second.data(), 3840, false) == 0) break;
    for (size_t j = 0; j < 3840; ++j) if (!std::isfinite(second[j])) return 15;
  }
  return 0;
}
