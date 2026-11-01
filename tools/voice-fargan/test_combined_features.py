"""Final combined-preset invariants, without model downloads or native builds."""

import unittest

import numpy as np
from combined_features import combined, strong_envelope, strong_lookup
from features import COMPENSATION, edit


class CombinedFeaturesTest(unittest.TestCase):
    def setUp(self):
        n = np.arange(18)
        self.basis = np.cos(np.pi / 18 * (n[:, None] + 0.5) * n[None, :]) * np.sqrt(
            2 / 18
        )
        self.basis[:, 0] /= np.sqrt(2)
        self.x = np.random.default_rng(7).normal(0, 0.2, (80, 20)).astype("<f4")
        self.x[:, 18] = 0.5

    def test_pitch_and_envelope_match_their_separate_calculations(self):
        for pitch, scale in [(-1, 0.8), (1, 1.25)]:
            y = combined(self.x, self.basis, pitch, scale)
            np.testing.assert_array_equal(
                y[:, 18], edit(self.x, self.basis, pitch=pitch)[:, 18]
            )
            np.testing.assert_array_equal(
                y[:, :18], strong_envelope(self.x, self.basis, scale)[:, :18]
            )
            np.testing.assert_array_equal(y[:, 0], self.x[:, 0])
            np.testing.assert_array_equal(y[:, 19], self.x[:, 19])
            np.testing.assert_array_equal(y[:20], self.x[:20])
            np.testing.assert_array_equal(y[-20:], self.x[-20:])
            self.assertFalse(np.array_equal(y[20:-20, 1:18], self.x[20:-20, 1:18]))

    def test_identity_and_input_immutability(self):
        before = self.x.tobytes()
        self.assertEqual(combined(self.x, self.basis).tobytes(), before)
        combined(self.x, self.basis, -1, 0.8)
        self.assertEqual(self.x.tobytes(), before)

    def test_map_matches_uniform_low_band_and_keeps_endpoints_and_continuity(self):
        f = np.linspace(0, 8000, 16001)
        for scale in [0.8, 1.25]:
            y = strong_lookup(f, scale)
            np.testing.assert_array_equal(y[f <= 4000], f[f <= 4000] / scale)
            self.assertEqual(y[0], 0)
            self.assertEqual(y[-1], 8000)
            self.assertTrue(np.all(np.diff(y) > 0))
            self.assertLess(
                abs(
                    strong_lookup(4000 - 1e-6, scale)
                    - strong_lookup(4000 + 1e-6, scale)
                ),
                3e-6,
            )

    def test_flat_compensated_envelope_does_not_gain_a_shape(self):
        bands = np.full(18, -3.0) - np.log10(COMPENSATION)
        coeff = bands @ self.basis
        coeff[0] -= 4
        self.x[:, :18] = coeff
        for scale in [0.8, 1.25]:
            y = strong_envelope(self.x, self.basis, scale)
            np.testing.assert_allclose(y, self.x, atol=1e-6)

    def test_other_combinations_remain_out_of_scope(self):
        for pitch, scale in [(-2, 0.8), (1, 0.8), (0, 0.8), (-1, 0.9)]:
            with self.assertRaises(ValueError):
                combined(self.x, self.basis, pitch, scale)


if __name__ == "__main__":
    unittest.main()
