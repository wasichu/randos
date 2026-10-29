//! Bounded, allocation-free LPC analysis and polynomial roots for the lab's
//! McAdams experiment. f64 keeps the narrow resonances numerically tractable.
use std::ops::{Add, Div, Mul, Sub};

pub const ORDER: usize = 20;
pub type Coefficients = [f64; ORDER + 1];

pub fn at(values: &[f64], index: usize) -> f64 {
    values.get(index).copied().unwrap_or(0.0)
}

pub fn coefficients(frame: &[f64]) -> Option<Coefficients> {
    let mut correlation = [0.0; ORDER + 1];
    for (lag, value) in correlation.iter_mut().enumerate() {
        *value = frame.iter().skip(lag).zip(frame).map(|(a, b)| a * b).sum();
    }
    let mut error = at(&correlation, 0) * (1.0 + 1e-6);
    if !error.is_finite() || error < 1e-20 {
        return None;
    }
    let mut a = [0.0; ORDER + 1];
    if let Some(first) = a.first_mut() {
        *first = 1.0;
    }
    for order in 1..=ORDER {
        let sum: f64 = (1..order)
            .map(|j| at(&a, j) * at(&correlation, order - j))
            .sum();
        let reflection = (-(at(&correlation, order) + sum) / error).clamp(-0.999, 0.999);
        let before = a;
        for (j, coefficient) in a.iter_mut().enumerate().take(order).skip(1) {
            *coefficient = at(&before, j) + reflection * at(&before, order - j);
        }
        if let Some(coefficient) = a.get_mut(order) {
            *coefficient = reflection;
        }
        error *= 1.0 - reflection * reflection;
        if !error.is_finite() || error < 1e-30 {
            return None;
        }
    }
    Some(a)
}

#[derive(Clone, Copy, Default, Debug)]
struct Complex {
    re: f64,
    im: f64,
}
impl Complex {
    fn polar(radius: f64, angle: f64) -> Self {
        Self {
            re: radius * angle.cos(),
            im: radius * angle.sin(),
        }
    }
    fn norm(self) -> f64 {
        self.re.hypot(self.im)
    }
    fn conj(self) -> Self {
        Self {
            re: self.re,
            im: -self.im,
        }
    }
}
impl Add for Complex {
    type Output = Self;
    fn add(self, b: Self) -> Self {
        Self {
            re: self.re + b.re,
            im: self.im + b.im,
        }
    }
}
impl Sub for Complex {
    type Output = Self;
    fn sub(self, b: Self) -> Self {
        Self {
            re: self.re - b.re,
            im: self.im - b.im,
        }
    }
}
impl Mul for Complex {
    type Output = Self;
    fn mul(self, b: Self) -> Self {
        Self {
            re: self.re * b.re - self.im * b.im,
            im: self.re * b.im + self.im * b.re,
        }
    }
}
impl Div for Complex {
    type Output = Self;
    fn div(self, b: Self) -> Self {
        let denominator = b.re * b.re + b.im * b.im;
        Self {
            re: (self.re * b.re + self.im * b.im) / denominator,
            im: (self.im * b.re - self.re * b.im) / denominator,
        }
    }
}

fn polynomial(a: &Coefficients, z: Complex) -> (Complex, Complex) {
    let mut value = Complex { re: 1.0, im: 0.0 };
    let mut derivative = Complex::default();
    for coefficient in a.iter().skip(1) {
        derivative = derivative * z + value;
        value = value * z
            + Complex {
                re: *coefficient,
                im: 0.0,
            };
    }
    (value, derivative)
}

fn roots_reconstruct(a: &Coefficients, roots: &[Complex; ORDER]) -> bool {
    let mut product = [Complex::default(); ORDER + 1];
    if let Some(first) = product.first_mut() {
        first.re = 1.0;
    }
    for (degree, root) in roots.iter().enumerate() {
        let before = product;
        product.fill(Complex::default());
        for (index, coefficient) in before.iter().enumerate().take(degree + 1) {
            if let Some(value) = product.get_mut(index) {
                *value = *value + *coefficient;
            }
            if let Some(value) = product.get_mut(index + 1) {
                *value = *value - *coefficient * *root;
            }
        }
    }
    let scale = a.iter().map(|value| value.abs()).fold(1.0_f64, f64::max);
    product.iter().zip(a).all(|(actual, expected)| {
        (actual.re - expected).abs() < 1e-6 * scale && actual.im.abs() < 1e-6 * scale
    })
}

fn roots(a: &Coefficients) -> Option<[Complex; ORDER]> {
    let mut roots = std::array::from_fn(|index| {
        Complex::polar(
            0.95,
            std::f64::consts::TAU * (index as f64 + 0.5) / ORDER as f64,
        )
    });
    for _ in 0..100 {
        let before = roots;
        let mut largest_step = 0.0_f64;
        for (index, root) in roots.iter_mut().enumerate() {
            let (value, derivative) = polynomial(a, *root);
            if value.norm() < 1e-14 {
                continue;
            }
            if derivative.norm() < 1e-25 {
                return None;
            }
            let newton = value / derivative;
            let mut repulsion = Complex::default();
            for (other_index, other) in before.iter().enumerate() {
                if index == other_index {
                    continue;
                }
                let distance = *root - *other;
                if distance.norm() < 1e-15 {
                    return None;
                }
                repulsion = repulsion + Complex { re: 1.0, im: 0.0 } / distance;
            }
            let step = newton / (Complex { re: 1.0, im: 0.0 } - newton * repulsion);
            if !step.norm().is_finite() {
                return None;
            }
            *root = *root - step;
            largest_step = largest_step.max(step.norm());
        }
        if largest_step < 1e-9 {
            let scale = a.iter().map(|value| value.abs()).sum::<f64>().max(1.0);
            return (roots_reconstruct(a, &roots)
                && roots.iter().all(|root| {
                    root.norm() < 1.00001 && polynomial(a, *root).0.norm() < 1e-9 * scale
                }))
            .then_some(roots);
        }
    }
    None
}

/// Move conjugate pole angles while retaining radii and real poles. Root,
/// pairing and stability failures are explicit; callers must not emit raw audio.
pub fn warp(a: &Coefficients, alpha: f64) -> Option<Coefficients> {
    warp_angles(a, alpha, false).map(|(coefficients, _)| coefficients)
}

/// Offline approximate reversal. Reanalysis can put poles outside the
/// forward transform's image: cap rather than fold them through cosine.
pub fn inverse(a: &Coefficients, forward_alpha: f64) -> Option<(Coefficients, usize)> {
    if !forward_alpha.is_finite() || !(0.5..=1.0).contains(&forward_alpha) {
        return None;
    }
    warp_angles(a, forward_alpha.recip(), true)
}

fn warp_angles(a: &Coefficients, exponent: f64, cap: bool) -> Option<(Coefficients, usize)> {
    let roots = roots(a)?;
    let mut used = [false; ORDER];
    let mut result = [0.0; ORDER + 1];
    if let Some(first) = result.first_mut() {
        *first = 1.0;
    }
    let mut degree = 0;
    let mut corrected = 0;
    for (index, root) in roots.iter().enumerate() {
        if used.get(index).copied().unwrap_or(true) {
            continue;
        }
        if let Some(used) = used.get_mut(index) {
            *used = true;
        }
        let (factor, width) = if root.im.abs() < 1e-7 {
            ([1.0, -root.re, 0.0], 1)
        } else {
            let (mate, error) = roots
                .iter()
                .enumerate()
                .filter(|(j, _)| !used.get(*j).copied().unwrap_or(true))
                .map(|(j, other)| (j, (*other - root.conj()).norm()))
                .min_by(|a, b| a.1.total_cmp(&b.1))?;
            if error > 1e-4 {
                return None;
            }
            if let Some(used) = used.get_mut(mate) {
                *used = true;
            }
            let radius = root.norm().min(0.9999);
            let mut angle = root.im.atan2(root.re).abs().powf(exponent);
            if cap && angle >= std::f64::consts::PI {
                angle = std::f64::consts::PI - 1e-6;
                corrected += 2;
            }
            ([1.0, -2.0 * radius * angle.cos(), radius * radius], 2)
        };
        let before = result;
        result.fill(0.0);
        for (i, coefficient) in before.iter().enumerate().take(degree + 1) {
            for (j, factor) in factor.iter().enumerate().take(width + 1) {
                if let Some(target) = result.get_mut(i + j) {
                    *target += coefficient * factor;
                }
            }
        }
        degree += width;
    }
    (degree == ORDER && result.iter().all(|value| value.is_finite())).then_some((result, corrected))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_conjugate_poles_move_to_expected_angles() {
        // Ten distinct conjugate pairs: a known stable 20th-order vowel model.
        let mut coefficients = [0.0; ORDER + 1];
        coefficients[0] = 1.0;
        let mut expected = coefficients;
        for pair in 0..10 {
            let angle = 0.12 + pair as f64 * 0.28;
            let radius = 0.85 + pair as f64 * 0.009;
            for (values, theta) in [(&mut coefficients, angle), (&mut expected, angle.powf(0.8))] {
                let before = *values;
                values.fill(0.0);
                for (i, value) in before.iter().enumerate().take(pair * 2 + 1) {
                    values[i] += value;
                    values[i + 1] -= value * 2.0 * radius * theta.cos();
                    values[i + 2] += value * radius * radius;
                }
            }
        }
        let actual = warp(&coefficients, 0.8).expect("known poles converge");
        for (actual, expected) in actual.iter().zip(expected) {
            assert!((actual - expected).abs() < 1e-4, "{actual} != {expected}");
        }
        assert!(warp(&[f64::NAN; ORDER + 1], 0.8).is_none());
        let (restored, corrected) = inverse(&actual, 0.8).expect("known inverse poles converge");
        assert_eq!(corrected, 0);
        for (actual, original) in restored.iter().zip(coefficients) {
            assert!(
                (actual - original).abs() < 1e-4,
                "inverse {actual} != {original}"
            );
        }
        let (identity, corrected) = inverse(&coefficients, 1.0).expect("identity inverse");
        assert_eq!(corrected, 0);
        for (actual, original) in identity.iter().zip(coefficients) {
            assert!((actual - original).abs() < 1e-4);
        }
        let (capped, corrected) =
            inverse(&coefficients, 0.7).expect("out-of-domain poles are capped");
        let mut expected_cap = [0.0; ORDER + 1];
        expected_cap[0] = 1.0;
        let mut expected_count = 0;
        for pair in 0..10 {
            let theta = (0.12 + pair as f64 * 0.28).powf(1.0 / 0.7);
            expected_count += usize::from(theta >= std::f64::consts::PI) * 2;
            let theta = theta.min(std::f64::consts::PI - 1e-6);
            let radius = 0.85 + pair as f64 * 0.009;
            let before = expected_cap;
            expected_cap.fill(0.0);
            for (i, value) in before.iter().enumerate().take(pair * 2 + 1) {
                expected_cap[i] += value;
                expected_cap[i + 1] -= value * 2.0 * radius * theta.cos();
                expected_cap[i + 2] += value * radius * radius;
            }
        }
        assert!(expected_count > 0);
        assert_eq!(corrected, expected_count);
        for (actual, expected) in capped.iter().zip(expected_cap) {
            assert!(
                (actual - expected).abs() < 1e-4,
                "cap {actual} != {expected}"
            );
        }
        assert!(inverse(&coefficients, 0.0).is_none());
    }
}
