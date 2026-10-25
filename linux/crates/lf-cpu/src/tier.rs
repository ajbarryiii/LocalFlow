//! Kernel tiers: which instruction sets the kernels use, chosen once per
//! process.
//!
//! Every kernel has an AVX-512 path and an AVX2 path. The AVX2 tier needs
//! AVX2, FMA and F16C (every x86-64 CPU since Haswell and Zen 1); its INT8
//! dot products use AVX-VNNI (`vpdpbusd`, VEX-encoded: Alder Lake and later,
//! Zen 5) when the CPU has it, otherwise `vpmaddubsw` + `vpmaddwd`.
//!
//! [`tier`] picks the best tier the CPU supports on its first call, unless
//! [`ENV`] forces one; the choice is then fixed for the process. A
//! [`crate::ThreadPool`] carries the tier its kernels run at, so tests and
//! benchmarks can run every tier the host supports side by side.
//!
//! On other architectures `Tier` has no variants (there are no kernels yet),
//! so every kernel's `match` on its pool's tier compiles with no arms there.

use std::fmt;
use std::sync::OnceLock;

/// Environment variable that forces a tier: `avx512`, `avx2` (with AVX-VNNI
/// when the CPU has it) or `avx2-novnni` (without, even when it has it).
/// Unset, empty or `auto` picks the best tier.
pub const ENV: &str = "LOCALFLOW_CPU_TIER";

/// A set of kernels and the CPU features they need.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Tier {
    /// AVX-512 F, BW, VNNI and VBMI, and BMI2.
    #[cfg(target_arch = "x86_64")]
    Avx512,
    /// AVX2, FMA and F16C; with `vnni`, INT8 dot products use AVX-VNNI.
    #[cfg(target_arch = "x86_64")]
    Avx2 { vnni: bool },
}

/// Why no tier could be chosen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TierError {
    /// [`ENV`] holds something other than the accepted names.
    UnknownOverride,
    /// [`ENV`] forces a tier this CPU lacks.
    Unsupported(Tier),
    /// The CPU supports no tier.
    NoTier,
}

impl fmt::Display for TierError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TierError::UnknownOverride => {
                write!(f, "{ENV} must be auto, avx512, avx2 or avx2-novnni")
            }
            TierError::Unsupported(t) => write!(
                f,
                "{ENV} forces the {t} kernels, but this CPU lacks {}",
                t.requirements()
            ),
            #[cfg(target_arch = "x86_64")]
            TierError::NoTier => write!(
                f,
                "this CPU has neither {} nor {}",
                Tier::Avx512.requirements(),
                Tier::Avx2 { vnni: false }.requirements()
            ),
            #[cfg(not(target_arch = "x86_64"))]
            TierError::NoTier => f.write_str("there are no CPU kernels for this architecture"),
        }
    }
}

impl std::error::Error for TierError {}

impl fmt::Display for Tier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

impl Tier {
    /// Every tier, best first.
    #[cfg(target_arch = "x86_64")]
    pub const ALL: &[Tier] = &[
        Tier::Avx512,
        Tier::Avx2 { vnni: true },
        Tier::Avx2 { vnni: false },
    ];
    #[cfg(not(target_arch = "x86_64"))]
    pub const ALL: &[Tier] = &[];

    /// `avx512`, `avx2+vnni` or `avx2`.
    pub fn name(self) -> &'static str {
        match self {
            #[cfg(target_arch = "x86_64")]
            Tier::Avx512 => "avx512",
            #[cfg(target_arch = "x86_64")]
            Tier::Avx2 { vnni: true } => "avx2+vnni",
            #[cfg(target_arch = "x86_64")]
            Tier::Avx2 { vnni: false } => "avx2",
        }
    }

    /// The CPU features this tier needs, for messages.
    pub fn requirements(self) -> &'static str {
        match self {
            #[cfg(target_arch = "x86_64")]
            Tier::Avx512 => "AVX-512 F/BW/VNNI/VBMI and BMI2",
            #[cfg(target_arch = "x86_64")]
            Tier::Avx2 { vnni: true } => "AVX2, FMA, F16C and AVX-VNNI",
            #[cfg(target_arch = "x86_64")]
            Tier::Avx2 { vnni: false } => "AVX2, FMA and F16C",
        }
    }

    /// Whether this CPU has every feature the tier's kernels use.
    pub fn supported(self) -> bool {
        match self {
            #[cfg(target_arch = "x86_64")]
            Tier::Avx512 => {
                use std::arch::is_x86_feature_detected as has;
                has!("bmi2")
                    && has!("avx512f")
                    && has!("avx512bw")
                    && has!("avx512vnni")
                    && has!("avx512vbmi")
            }
            #[cfg(target_arch = "x86_64")]
            Tier::Avx2 { vnni } => {
                use std::arch::is_x86_feature_detected as has;
                has!("avx2") && has!("fma") && has!("f16c") && (!vnni || has!("avxvnni"))
            }
        }
    }

    /// Every tier this CPU supports, best first, whatever [`ENV`] says.
    pub fn available() -> Vec<Tier> {
        Tier::ALL
            .iter()
            .copied()
            .filter(|t| t.supported())
            .collect()
    }
}

/// Resolves an [`ENV`] value (`None` when unset) against what the CPU
/// supports, as given by `supported`.
fn resolve(value: Option<&str>, supported: impl Fn(Tier) -> bool) -> Result<Tier, TierError> {
    let forced = match value.map(str::trim) {
        None | Some("" | "auto") => None,
        Some(name @ ("avx512" | "avx2" | "avx2-novnni")) => Some(named(name, &supported)?),
        Some(_) => return Err(TierError::UnknownOverride),
    };
    match forced {
        Some(t) if supported(t) => Ok(t),
        Some(t) => Err(TierError::Unsupported(t)),
        None => Tier::ALL
            .iter()
            .copied()
            .find(|&t| supported(t))
            .ok_or(TierError::NoTier),
    }
}

/// The tier an accepted [`ENV`] name stands for.
#[cfg(target_arch = "x86_64")]
fn named(name: &str, supported: impl Fn(Tier) -> bool) -> Result<Tier, TierError> {
    Ok(match name {
        "avx512" => Tier::Avx512,
        "avx2" => Tier::Avx2 {
            vnni: supported(Tier::Avx2 { vnni: true }),
        },
        _ => Tier::Avx2 { vnni: false },
    })
}

#[cfg(not(target_arch = "x86_64"))]
fn named(_: &str, _: impl Fn(Tier) -> bool) -> Result<Tier, TierError> {
    Err(TierError::NoTier)
}

/// The process's tier: [`ENV`] if set, otherwise the best this CPU supports.
/// Chosen on the first call; every later call returns the same result.
pub fn tier() -> Result<Tier, TierError> {
    static SELECTED: OnceLock<Result<Tier, TierError>> = OnceLock::new();
    SELECTED
        .get_or_init(|| {
            // A value that is not valid UTF-8 cannot name a tier.
            let value = std::env::var_os(ENV)
                .map(|v| v.into_string().unwrap_or_else(|_| "\u{fffd}".into()));
            resolve(value.as_deref(), Tier::supported)
        })
        .clone()
}

#[cfg(all(test, target_arch = "x86_64"))]
mod tests {
    use super::*;

    const VNNI: Tier = Tier::Avx2 { vnni: true };
    const AVX2: Tier = Tier::Avx2 { vnni: false };

    #[test]
    fn picks_the_best_supported_tier_unless_forced() {
        let all = |_: Tier| true;
        let no_avx512 = |t: Tier| t != Tier::Avx512;
        let plain_avx2 = |t: Tier| t == AVX2;
        let none = |_: Tier| false;
        assert_eq!(resolve(None, all), Ok(Tier::Avx512));
        assert_eq!(resolve(Some("auto"), no_avx512), Ok(VNNI));
        assert_eq!(resolve(Some(""), plain_avx2), Ok(AVX2));
        assert_eq!(resolve(None, none), Err(TierError::NoTier));

        assert_eq!(resolve(Some("avx2"), all), Ok(VNNI));
        assert_eq!(resolve(Some(" avx2 "), plain_avx2), Ok(AVX2));
        assert_eq!(resolve(Some("avx2-novnni"), all), Ok(AVX2));
        assert_eq!(resolve(Some("avx512"), all), Ok(Tier::Avx512));
    }

    #[test]
    fn forcing_a_missing_tier_or_an_unknown_name_is_an_error() {
        let plain_avx2 = |t: Tier| t == AVX2;
        assert_eq!(
            resolve(Some("avx512"), plain_avx2),
            Err(TierError::Unsupported(Tier::Avx512))
        );
        assert_eq!(
            resolve(Some("avx2"), |_| false),
            Err(TierError::Unsupported(AVX2))
        );
        for bad in ["AVX512", "sse4", "avx2,avx512", "\u{fffd}"] {
            assert_eq!(
                resolve(Some(bad), |_| true),
                Err(TierError::UnknownOverride)
            );
        }
        let msg = TierError::Unsupported(Tier::Avx512).to_string();
        assert!(msg.contains(ENV) && msg.contains("AVX-512"), "{msg}");
    }

    #[test]
    fn the_process_tier_is_fixed_and_supported() {
        let first = tier();
        assert_eq!(tier(), first);
        if let Ok(t) = first {
            assert!(t.supported());
            assert!(Tier::available().contains(&t));
        }
        assert_eq!(crate::cpu_supported(), first.is_ok());
    }
}
