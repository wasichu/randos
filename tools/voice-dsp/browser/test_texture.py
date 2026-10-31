"""Numerical falsification tests; no models, network, devices or saved reviews."""

import unittest

import numpy as np
from scipy.signal import lfilter, sos2zpk
from texture_core import RATE, poles_with_bandwidth, shape_residual, transform


class TextureTests(unittest.TestCase):
    def test_known_poles_change_only_decay(self):
        poles = np.array(
            [
                0.97 * np.exp(1j * 2 * np.pi * 800 / RATE),
                0.97 * np.exp(-1j * 2 * np.pi * 800 / RATE),
            ]
        )
        a = np.poly(poles).real
        for factor in [0.75, 1.35]:
            sos, stats = poles_with_bandwidth(a, factor)
            got = sos2zpk(sos)[1]
            np.testing.assert_allclose(
                np.sort(np.angle(got)), np.sort(np.angle(poles)), atol=1e-12
            )
            np.testing.assert_allclose(np.abs(got), np.abs(poles) ** factor, atol=1e-12)
            self.assertEqual(stats["changed_poles"], 2)

    def test_narrow_poles_are_not_widened_by_a_floor(self):
        r = np.exp(-np.pi * 45 / RATE)
        a = np.poly([r * np.exp(1j * 0.1), r * np.exp(-1j * 0.1)]).real
        sos, stats = poles_with_bandwidth(a, 0.75)
        self.assertEqual(stats["changed_poles"], 0)
        np.testing.assert_allclose(
            np.sort_complex(sos2zpk(sos)[1]), np.sort_complex(np.roots(a)), atol=1e-12
        )

    def test_source_preserves_mean_rms_period_and_identity(self):
        pulse = np.r_[np.linspace(-0.2, 1, 40), np.linspace(1, -0.2, 200)]
        e = np.tile(pulse, 8)
        np.testing.assert_array_equal(shape_residual(e, 1), e)
        for gamma in [0.8, 1.25]:
            y = shape_residual(e, gamma)
            self.assertGreater(np.max(np.abs(y - e)), 0.01)
            self.assertAlmostEqual(np.mean(y), np.mean(e), places=12)
            self.assertAlmostEqual(np.std(y), np.std(e), places=12)
            np.testing.assert_allclose(y[240:], y[:-240], atol=1e-12)

    def test_identity_noise_silence_and_boundaries(self):
        rng = np.random.default_rng(41)
        pulse = np.zeros(9600)
        pulse[::240] = 0.03
        voiced = lfilter([1], [1, -1.7, 0.8], pulse)
        noise = rng.normal(0, 0.01, 9600)
        for x in [
            np.zeros(9600),
            noise,
            voiced,
            np.r_[voiced[:4800], noise[:4800]],
            np.r_[0.1, np.zeros(9599)],
            np.r_[np.zeros(9599), 0.1],
        ]:
            control, _stats = transform(x)
            np.testing.assert_allclose(control, x, atol=1e-7, rtol=0)
            for kwargs in [
                {"bandwidth": 0.75},
                {"bandwidth": 1.35},
                {"gamma": 0.8},
                {"gamma": 1.25},
            ]:
                y, s = transform(x, **kwargs)
                self.assertEqual(len(y), len(x))
                self.assertTrue(np.isfinite(y).all())
                if x is noise:
                    self.assertEqual(s["voiced_frames"], 0)
                    np.testing.assert_allclose(y, control, atol=1e-12)
                if not np.any(x):
                    np.testing.assert_array_equal(y, x)

    def test_rejects_unsupported_inputs(self):
        for x in [[], [float("nan")], [float("inf")]]:
            with self.assertRaises(ValueError):
                transform(x)
        with self.assertRaises(ValueError):
            transform(np.zeros(4800), bandwidth=0.75, gamma=0.8)

    def test_sos_control_exercises_root_conversion(self):
        e = np.zeros(9600)
        e[::240] = 0.02
        x = lfilter([1], [1, -1.7, 0.8], e)
        y, stats = transform(x, sos_control=True)
        self.assertGreater(stats["voiced_frames"], 0)
        self.assertLess(np.max(np.abs(y - x)), 0.001)
        self.assertLess(stats["max_sos_identity_error"], 0.001)


if __name__ == "__main__":
    unittest.main()
