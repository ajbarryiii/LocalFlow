//! IEEE 754 binary16 conversions.

pub fn f16_to_f32(h: u16) -> f32 {
    let sign = ((h >> 15) as u32) << 31;
    let exp = ((h >> 10) & 0x1f) as u32;
    let mant = (h & 0x3ff) as u32;
    let bits = match (exp, mant) {
        (0, 0) => sign,
        (0, m) => {
            // Subnormal: value = m * 2^-24, renormalized for f32.
            let shift = m.leading_zeros() - 21;
            let m = (m << shift) & 0x3ff;
            sign | ((113 - shift) << 23) | (m << 13)
        }
        (0x1f, 0) => sign | 0x7f80_0000,
        (0x1f, m) => sign | 0x7fc0_0000 | (m << 13),
        (e, m) => sign | ((e + 112) << 23) | (m << 13),
    };
    f32::from_bits(bits)
}

/// Round-to-nearest-even f32 to binary16, saturating to infinity.
pub fn f32_to_f16(f: f32) -> u16 {
    let bits = f.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exp = ((bits >> 23) & 0xff) as i32;
    let mant = bits & 0x7f_ffff;
    if exp == 0xff {
        return sign | 0x7c00 | if mant != 0 { 0x200 } else { 0 };
    }
    let e = exp - 127 + 15;
    if e >= 0x1f {
        return sign | 0x7c00;
    }
    let (m, shift) = if e <= 0 {
        // Subnormal or zero in f16: include the implicit bit and shift further.
        if e < -10 {
            return sign;
        }
        (mant | 0x80_0000, (14 - e) as u32)
    } else {
        (mant, 13)
    };
    let half_bits = m >> shift;
    let rem = m & ((1 << shift) - 1);
    let halfway = 1 << (shift - 1);
    let mut out = if e <= 0 {
        half_bits
    } else {
        ((e as u32) << 10) | half_bits
    };
    if rem > halfway || (rem == halfway && out & 1 == 1) {
        out += 1; // May carry into the exponent, which is the correct rounding.
    }
    sign | out as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_every_finite_half() {
        for h in 0..=u16::MAX {
            let f = f16_to_f32(h);
            if f.is_nan() {
                assert!(f32_to_f16(f) & 0x7c00 == 0x7c00 && f32_to_f16(f) & 0x3ff != 0);
                continue;
            }
            assert_eq!(f32_to_f16(f), h, "{h:#06x} -> {f}");
        }
    }

    #[test]
    fn known_values() {
        assert_eq!(f16_to_f32(0x3c00), 1.0);
        assert_eq!(f16_to_f32(0xc000), -2.0);
        assert_eq!(f16_to_f32(0x0001), 2f32.powi(-24));
        assert_eq!(f16_to_f32(0x7bff), 65504.0);
        assert_eq!(f32_to_f16(1.0 + 2f32.powi(-11)), 0x3c00); // tie to even
        assert_eq!(f32_to_f16(1.0 + 3.0 * 2f32.powi(-11)), 0x3c02);
        assert_eq!(f32_to_f16(70000.0), 0x7c00);
    }
}
