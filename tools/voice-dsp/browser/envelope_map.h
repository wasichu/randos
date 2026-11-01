// Research only: perturb the envelope lookup, never the harmonic-frequency map.
#pragma once
#include <cmath>

inline double randosResearchBend = 0;
inline double randosResearchWarp(double frequency, double baseline) {
  constexpr double cutoff = 4000.0 / 48000.0;
  constexpr double pi = 3.14159265358979323846;
  // Preserve the original arithmetic exactly at zero and outside the band.
  if (randosResearchBend == 0 || frequency <= 0 || frequency >= cutoff) return baseline;
  const double angle = pi * frequency / cutoff;
  const double sine = std::sin(angle);
  return baseline + randosResearchBend * cutoff / (2 * pi)
      * std::sin(2 * angle) * sine * sine;
}
