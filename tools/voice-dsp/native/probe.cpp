// Experiment only: TUI-sized frames around the unchanged browser DSP core.
// No audio devices, Rust FFI, helper protocol, or production integration.
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <sys/resource.h>

extern "C" {
int dsp_new(double, double);
double *dsp_input();
double *dsp_output();
int dsp_process(int);
int dsp_flush(int);
int dsp_input_latency();
int dsp_output_latency();
void dsp_close();
}

namespace {
using Clock = std::chrono::steady_clock;
constexpr size_t FRAME = 960, BATCH = 3840, CAPACITY = BATCH * 4;
constexpr size_t PREFILL = 7680;
double ms(Clock::duration elapsed) {
  return std::chrono::duration<double, std::milli>(elapsed).count();
}
long rss_peak() {
  rusage usage{};
  if (getrusage(RUSAGE_SELF, &usage) != 0) throw std::runtime_error("getrusage failed");
#ifdef __APPLE__
  return usage.ru_maxrss;
#else
  return usage.ru_maxrss * 1024;
#endif
}
double percentile(std::vector<double> values, double p) {
  if (values.empty()) return 0;
  std::sort(values.begin(), values.end());
  return values.at(static_cast<size_t>((values.size() - 1) * p));
}

// One core instance per process, matching spectral.cpp's global state. Fixed
// queues; construction/process stay off real-time device callbacks in any future
// integration. This single-thread probe does not establish callback safety.
class Stream {
  std::array<double, BATCH> pending{};
  std::array<float, CAPACITY> queue{};
  size_t fill = 0, head = 0, length = 0;
  int64_t position;
  uint64_t accepted = 0;
  size_t max_input = 0, max_output = 0;
  double peak = 0;
  void accept(int count, uint64_t limit) {
    if (count < 0) throw std::runtime_error("DSP failed");
    const auto *output = dsp_output();
    for (int i = 0; i < count; ++i, ++position) {
      if (position < 0 || static_cast<uint64_t>(position) >= limit) continue;
      const auto value = static_cast<float>(output[i]);
      if (!std::isfinite(value)) throw std::runtime_error("Non-finite DSP output");
      if (length == CAPACITY) throw std::runtime_error("Output overflow");
      queue[(head + length) % CAPACITY] = value;
      ++length;
      ++accepted;
      peak = std::max(peak, std::abs(static_cast<double>(value)));
    }
    max_output = std::max(max_output, length);
  }
  void process(size_t count, uint64_t limit) {
    std::copy_n(pending.data(), count, dsp_input());
    accept(dsp_process(static_cast<int>(count)), limit);
    fill = 0;
  }
public:
  const int core_delay;
  Stream(double pitch, double scale) : position(0), core_delay(initialize(pitch, scale)) {
    position = -core_delay;
  }
  static int initialize(double pitch, double scale) {
    if (dsp_new(pitch, scale) != 1) throw std::runtime_error("DSP initialization failed");
    return dsp_input_latency() + dsp_output_latency();
  }
  ~Stream() { dsp_close(); }
  Stream(const Stream &) = delete;
  Stream &operator=(const Stream &) = delete;
  void push(const float *data, size_t count, uint64_t limit = UINT64_MAX) {
    if (count == 0 || count > FRAME || fill + count > BATCH)
      throw std::runtime_error("Invalid ingress frame");
    for (size_t i = 0; i < count; ++i) {
      if (!std::isfinite(data[i])) throw std::runtime_error("Non-finite input");
      pending[fill++] = data[i];
    }
    max_input = std::max(max_input, fill);
    if (fill == BATCH) process(fill, limit);
  }
  void finish(uint64_t limit) {
    if (fill) process(fill, limit);
    const int input_delay = dsp_input_latency();
    std::fill_n(dsp_input(), input_delay, 0);
    accept(dsp_process(input_delay), limit);
    accept(dsp_flush(dsp_output_latency()), limit);
    if (accepted != limit) throw std::runtime_error("Incomplete drain");
  }
  size_t available() const { return length; }
  void pop(float *output, size_t count) {
    if (count > length) throw std::runtime_error("Output starvation");
    for (size_t i = 0; i < count; ++i) {
      output[i] = queue[head];
      head = (head + 1) % CAPACITY;
      --length;
    }
  }
  void bounds() const {
    std::cout << ",\"max_input_samples\":" << max_input
              << ",\"max_output_samples\":" << max_output
              << ",\"queue_capacity_samples\":" << CAPACITY
              << ",\"output_peak\":" << peak;
  }
};

std::vector<float> read_input(const std::string &path) {
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  const auto size = file.tellg();
  if (!file || size <= 0 || size > 4000000 || size % sizeof(float))
    throw std::runtime_error("Invalid bounded f32 input");
  std::vector<float> input(static_cast<size_t>(size) / sizeof(float));
  file.seekg(0);
  file.read(reinterpret_cast<char *>(input.data()), size);
  if (!file || !std::all_of(input.begin(), input.end(), [](float x) { return std::isfinite(x); }))
    throw std::runtime_error("Invalid input bytes");
  return input;
}
void finite(Stream &stream, const std::vector<float> &input, const std::string &path) {
  std::ofstream file(path, std::ios::binary);
  if (!file) throw std::runtime_error("Output unavailable");
  std::array<float, FRAME> frame{};
  uint64_t written = 0;
  auto drain = [&] {
    while (stream.available()) {
      const auto count = std::min(FRAME, stream.available());
      stream.pop(frame.data(), count);
      file.write(reinterpret_cast<const char *>(frame.data()), count * sizeof(float));
      if (!file) throw std::runtime_error("Output write failed");
      written += count;
    }
  };
  for (size_t at = 0; at < input.size(); at += FRAME) {
    stream.push(input.data() + at, std::min(FRAME, input.size() - at), input.size());
    drain();
  }
  stream.finish(input.size());
  drain();
  if (written != input.size()) throw std::runtime_error("Truncated output");
  std::cout << "\"mode\":\"finite\",\"samples\":" << written;
}

void paced(Stream &stream, const std::vector<float> &input, int seconds) {
  std::array<float, FRAME> frame{}, output{};
  // Bounded scalar metrics, no full-minute PCM retention. Reserve before timing.
  std::vector<double> compute, lateness, delivery;
  compute.reserve(seconds * 50);
  lateness.reserve(seconds * 50);
  delivery.reserve(seconds * 50);
  bool playing = false;
  size_t cursor = 0, min_output = CAPACITY;
  uint64_t played = 0, delay = 0;
  const auto start = Clock::now();
  for (int tick = 0; tick < seconds * 50; ++tick) {
    const auto due = start + std::chrono::milliseconds((tick + 1) * 20);
    // Absolute clock never moves to accommodate slow processing. A slow batch
    // causes visible late releases/deliveries, not a slower synthetic source.
    std::this_thread::sleep_until(due);
    lateness.push_back(std::max(0.0, ms(Clock::now() - due)));
    for (auto &value : frame) {
      value = input[cursor];
      cursor = (cursor + 1) % input.size();
    }
    const auto before = Clock::now();
    stream.push(frame.data(), FRAME);
    compute.push_back(ms(Clock::now() - before));
    if (!playing && stream.available() >= PREFILL) {
      playing = true;
      delay = static_cast<uint64_t>(tick + 1) * FRAME;
    }
    if (playing) {
      if (static_cast<uint64_t>(tick + 1) * FRAME - played != delay)
        throw std::runtime_error("Non-contiguous output timeline");
      stream.pop(output.data(), FRAME);
      played += FRAME;
      min_output = std::min(min_output, stream.available());
      delivery.push_back(std::max(0.0, ms(Clock::now() - due)));
    }
  }
  if (!playing) throw std::runtime_error("Never produced playable output");
  const auto late = [](const std::vector<double> &values) {
    return std::count_if(values.begin(), values.end(), [](double x) { return x >= 20; });
  };
  std::cout << "\"mode\":\"paced\",\"seconds\":" << seconds
            << ",\"elapsed_ms\":" << ms(Clock::now() - start)
            << ",\"input_samples\":" << seconds * 48000
            << ",\"delivered_samples\":" << played
            << ",\"buffer_delay_ms\":" << delay / 48.0
            << ",\"remaining_output_samples\":" << stream.available()
            << ",\"min_output_samples\":" << min_output
            << ",\"prefill_samples\":" << PREFILL
            << ",\"compute_p50_ms\":" << percentile(compute, .5)
            << ",\"compute_p95_ms\":" << percentile(compute, .95)
            << ",\"compute_max_ms\":" << percentile(compute, 1)
            << ",\"release_lateness_p95_ms\":" << percentile(lateness, .95)
            << ",\"release_lateness_max_ms\":" << percentile(lateness, 1)
            << ",\"delivery_lateness_max_ms\":" << percentile(delivery, 1)
            << ",\"missed_release_periods\":" << late(lateness)
            << ",\"missed_delivery_periods\":" << late(delivery)
            << ",\"starvations\":0,\"overflows\":0";
  // Stop discards bounded pending audio, matching live stop rather than draining
  // stale speech. Only the finite fixture flushes the complete tail.
}
}

int main(int argc, char **argv) {
  try {
    // Parent owns an open stdin pipe. Its death (including SIGKILL) closes the
    // pipe, so this worker cannot outlive the starter. No child processes.
    std::thread([] { std::cin.get(); std::_Exit(72); }).detach();
    if (argc != 6) throw std::runtime_error("INPUT OUTPUT PITCH SCALE SECONDS (0=finite, 1..60=paced)");
    const auto input = read_input(argv[1]);
    const double pitch = std::stod(argv[3]), scale = std::stod(argv[4]);
    const int seconds = std::stoi(argv[5]);
    if (!std::isfinite(pitch) || pitch < -12 || pitch > 12 ||
        !std::isfinite(scale) || scale < .5 || scale > 2 || seconds < 0 || seconds > 60)
      throw std::runtime_error("Unsupported configuration");
    const auto rss_before = rss_peak();
    const auto before = Clock::now();
    Stream stream(pitch, scale);
    const auto initialization_ms = ms(Clock::now() - before);
    const auto rss_initialized = rss_peak();
    std::cout.precision(10);
    std::cout << "{";
    if (seconds) paced(stream, input, seconds);
    else finite(stream, input, argv[2]);
    std::cout << ",\"frame_samples\":" << FRAME << ",\"batch_samples\":" << BATCH
              << ",\"core_delay_samples\":" << stream.core_delay
              << ",\"initialization_ms\":" << initialization_ms
              << ",\"peak_rss_before_init_bytes\":" << rss_before
              << ",\"peak_rss_after_init_bytes\":" << rss_initialized
              << ",\"peak_rss_end_bytes\":" << rss_peak();
    stream.bounds();
    std::cout << "}\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
