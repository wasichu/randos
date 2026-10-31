"""Offline edit invariants; no pretrained model, compiler or downloads needed."""

import unittest

import numpy as np
from features import edit, lookup, periods


class FeatureEditsTest(unittest.TestCase):
    def setUp(self):
        n = np.arange(18)
        self.basis = np.cos(np.pi / 18 * (n[:, None] + 0.5) * n[None, :]) * np.sqrt(
            2 / 18
        )
        self.basis[:, 0] /= np.sqrt(2)
        self.x = np.random.default_rng(7).normal(0, 0.2, (80, 20)).astype("<f4")
        self.x[:, 18] = 0.5

    def test_identity_is_byte_exact_and_input_is_not_mutated(self):
        before = self.x.tobytes()
        self.assertEqual(edit(self.x, self.basis).tobytes(), before)
        edit(self.x, self.basis, scale=0.9)
        self.assertEqual(self.x.tobytes(), before)

    def test_pitch_preserves_envelope_voicing_and_padding(self):
        for pitch in [-1, 1]:
            y = edit(self.x, self.basis, pitch=pitch)
            np.testing.assert_array_equal(y[:20], self.x[:20])
            np.testing.assert_array_equal(y[-20:], self.x[-20:])
            np.testing.assert_array_equal(y[:, :18], self.x[:, :18])
            np.testing.assert_array_equal(y[:, 19], self.x[:, 19])
            np.testing.assert_allclose(
                y[20:-20, 18] - self.x[20:-20, 18], pitch / 12, atol=1e-7
            )

    def test_pitch_keeps_bound_frames_instead_of_relying_on_clamps(self):
        self.x[:, 18] = -1.5  # 256-sample period
        y = edit(self.x, self.basis, pitch=-1)
        np.testing.assert_array_equal(y, self.x)
        self.assertTrue(np.all(periods(y) <= 256))

    def test_envelope_preserves_pitch_voicing_level_and_padding(self):
        for scale in [0.9, 1.1]:
            y = edit(self.x, self.basis, scale=scale)
            np.testing.assert_array_equal(y[:20], self.x[:20])
            np.testing.assert_array_equal(y[-20:], self.x[-20:])
            np.testing.assert_array_equal(y[:, 18:], self.x[:, 18:])
            np.testing.assert_array_equal(y[:, 0], self.x[:, 0])
            self.assertFalse(np.array_equal(y[20:-20, 1:18], self.x[20:-20, 1:18]))

    def test_inverse_map_is_monotonic_and_keeps_band_endpoints(self):
        f = np.linspace(0, 8000, 10001)
        for scale in [0.9, 1.1]:
            y = lookup(f, scale)
            self.assertEqual(y[0], 0)
            self.assertEqual(y[-1], 8000)
            self.assertTrue(np.all(np.diff(y) > 0))

    def test_invalid_or_combined_edits_are_rejected(self):
        for settings in [
            {"pitch": 2},
            {"scale": 0.8},
            {"pitch": 1, "scale": 1.1},
            {"scale": float("nan")},
        ]:
            with self.assertRaises(ValueError):
                edit(self.x, self.basis, **settings)
        self.x[25, 1] = np.nan
        with self.assertRaises(ValueError):
            edit(self.x, self.basis)


if __name__ == "__main__":
    unittest.main()
