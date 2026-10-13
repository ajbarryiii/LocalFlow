//! FLAC reading for the public test sets, shared by the evaluation binaries.

use std::path::Path;

pub const SAMPLE_RATE: u32 = 16_000;

/// 16 kHz mono 16-bit FLAC to f32 samples in [-1, 1).
pub fn read_flac(path: &Path) -> Result<Vec<f32>, String> {
    let mut reader =
        claxon::FlacReader::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let info = reader.streaminfo();
    if info.sample_rate != SAMPLE_RATE || info.channels != 1 || info.bits_per_sample != 16 {
        return Err(format!(
            "{}: need 16 kHz mono 16-bit, got {} Hz, {} ch, {} bit",
            path.display(),
            info.sample_rate,
            info.channels,
            info.bits_per_sample
        ));
    }
    // soundfile's int16 -> float32 conversion: divide by 32768.
    reader
        .samples()
        .map(|s| {
            s.map(|v| v as f32 / 32768.0)
                .map_err(|e| format!("{}: {e}", path.display()))
        })
        .collect()
}
