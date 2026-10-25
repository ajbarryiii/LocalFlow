//! `manifest.json` handling: every file in an export is pinned by SHA-256.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Component, Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::{Result, SafeTensors, WeightFormat, bail};

pub struct Manifest {
    pub format: String,
    /// Relative path -> lowercase hex SHA-256.
    pub files: BTreeMap<String, String>,
    /// The NeMo model config (`config`), or null if absent.
    pub config: serde_json::Value,
}

impl Manifest {
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        let value: serde_json::Value = serde_json::from_slice(bytes)
            .map_err(|e| crate::Error(format!("manifest json: {e}")))?;
        let Some(format) = value.get("format").and_then(|v| v.as_str()) else {
            bail!("manifest: missing format");
        };
        let Some(entries) = value.get("files").and_then(|v| v.as_object()) else {
            bail!("manifest: missing files");
        };
        let mut files = BTreeMap::new();
        for (path, hash) in entries {
            let Some(hash) = hash.as_str() else {
                bail!("manifest: hash for {path} is not a string");
            };
            if !is_plain_relative(path) {
                bail!("manifest: refusing path {path}");
            }
            if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
                bail!("manifest: malformed hash for {path}");
            }
            files.insert(path.clone(), hash.to_ascii_lowercase());
        }
        Ok(Manifest {
            format: format.to_owned(),
            files,
            config: value
                .get("config")
                .cloned()
                .unwrap_or(serde_json::Value::Null),
        })
    }

    /// The weight packing named by `format`; other formats are refused.
    pub fn weight_format(&self) -> Result<WeightFormat> {
        match WeightFormat::parse(&self.format) {
            Some(f) => Ok(f),
            None => bail!("unsupported export format {}", self.format),
        }
    }
}

fn is_plain_relative(path: &str) -> bool {
    let p = Path::new(path);
    !path.is_empty() && p.components().all(|c| matches!(c, Component::Normal(_)))
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

pub fn sha256_file(path: &Path) -> Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex(&hasher.finalize()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A verified export directory.
pub struct Export {
    pub dir: PathBuf,
    pub manifest: Manifest,
    /// From the manifest, and the same in the tensor file's metadata.
    pub format: WeightFormat,
    pub tensors: SafeTensors,
}

pub const TENSOR_FILE: &str = "export.safetensors";

impl Export {
    /// Opens an export and checks every file against the manifest hashes.
    pub fn open(dir: &Path) -> Result<Self> {
        let dir = dir.canonicalize()?;
        let manifest = Manifest::parse(&std::fs::read(dir.join("manifest.json"))?)?;
        let format = manifest.weight_format()?;
        let Some(tensor_hash) = manifest.files.get(TENSOR_FILE) else {
            bail!("manifest does not list {TENSOR_FILE}");
        };
        let tensors = SafeTensors::open(&contained(&dir, TENSOR_FILE)?)?;
        if sha256_hex(tensors.file_bytes()) != *tensor_hash {
            bail!("{TENSOR_FILE}: SHA-256 mismatch");
        }
        for (path, hash) in &manifest.files {
            if path != TENSOR_FILE && sha256_file(&contained(&dir, path)?)? != *hash {
                bail!("{path}: SHA-256 mismatch");
            }
        }
        if tensors.metadata.get("format").map(String::as_str) != Some(format.name()) {
            bail!("{TENSOR_FILE}: format metadata does not match the manifest");
        }
        Ok(Export {
            dir,
            manifest,
            format,
            tensors,
        })
    }

    /// Reads one file listed in `dir`'s manifest, verified against its hash,
    /// without opening or hashing the tensors. Returns the manifest too.
    pub fn read_one(dir: &Path, path: &str) -> Result<(Manifest, Vec<u8>)> {
        let dir = dir.canonicalize()?;
        let manifest = Manifest::parse(&std::fs::read(dir.join("manifest.json"))?)?;
        manifest.weight_format()?;
        let Some(hash) = manifest.files.get(path) else {
            bail!("manifest does not list {path}");
        };
        let bytes = std::fs::read(contained(&dir, path)?)?;
        if sha256_hex(&bytes) != *hash {
            bail!("{path}: SHA-256 mismatch");
        }
        Ok((manifest, bytes))
    }

    /// Reads a file listed in the manifest, verifying its hash on the bytes returned.
    pub fn read_verified(&self, path: &str) -> Result<Vec<u8>> {
        let Some(hash) = self.manifest.files.get(path) else {
            bail!("manifest does not list {path}");
        };
        let bytes = std::fs::read(contained(&self.dir, path)?)?;
        if sha256_hex(&bytes) != *hash {
            bail!("{path}: SHA-256 mismatch");
        }
        Ok(bytes)
    }
}

/// `dir/rel` resolved through symlinks, refused unless it stays inside `dir`
/// (which must already be canonical).
fn contained(dir: &Path, rel: &str) -> Result<PathBuf> {
    let path = dir.join(rel).canonicalize()?;
    if !path.starts_with(dir) {
        bail!("{rel} resolves outside the export directory");
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn symlinks_cannot_escape() {
        let base = std::env::temp_dir().join(format!("lf-manifest-test-{}", std::process::id()));
        let dir = base.join("export");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(base.join("outside.txt"), b"x").unwrap();
        std::fs::write(dir.join("inside.txt"), b"x").unwrap();
        std::os::unix::fs::symlink(base.join("outside.txt"), dir.join("link.txt")).unwrap();
        let dir = dir.canonicalize().unwrap();
        assert!(contained(&dir, "inside.txt").is_ok());
        assert!(contained(&dir, "link.txt").is_err());
        std::fs::remove_dir_all(&base).unwrap();
    }

    /// A one-tensor export in a fresh directory, with the manifest naming
    /// `manifest_format` and the tensor file's metadata `file_format`.
    fn tiny_export(tag: &str, manifest_format: &str, file_format: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("lf-export-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let header = format!(
            r#"{{"__metadata__":{{"format":"{file_format}"}},"m.scale":{{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}}}"#
        );
        let mut file = (header.len() as u64).to_le_bytes().to_vec();
        file.extend_from_slice(header.as_bytes());
        file.extend_from_slice(&1.0f32.to_le_bytes());
        let manifest = format!(
            r#"{{"format":"{manifest_format}","files":{{"{TENSOR_FILE}":"{}"}}}}"#,
            sha256_hex(&file)
        );
        std::fs::write(dir.join(TENSOR_FILE), file).unwrap();
        std::fs::write(dir.join("manifest.json"), manifest).unwrap();
        dir
    }

    #[test]
    fn opens_both_formats_and_refuses_others() {
        for f in [WeightFormat::Ternary, WeightFormat::Binary] {
            let dir = tiny_export(f.name(), f.name(), f.name());
            assert_eq!(Export::open(&dir).unwrap().format, f);
            std::fs::remove_dir_all(&dir).unwrap();
        }
        let mixed = tiny_export("mixed", crate::BINARY_FORMAT, crate::TERNARY_FORMAT);
        assert!(Export::open(&mixed).is_err());
        std::fs::remove_dir_all(&mixed).unwrap();
        let unknown = tiny_export(
            "unknown",
            "parakeet-quaternary-v1",
            "parakeet-quaternary-v1",
        );
        assert!(Export::open(&unknown).is_err());
        assert!(Export::read_one(&unknown, TENSOR_FILE).is_err());
        std::fs::remove_dir_all(&unknown).unwrap();
    }

    #[test]
    fn known_digest() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn rejects_escaping_paths() {
        let h = "0".repeat(64);
        for path in ["../x", "/etc/x", "a/../../x", ""] {
            let json = format!(r#"{{"format":"f","files":{{"{path}":"{h}"}}}}"#);
            assert!(Manifest::parse(json.as_bytes()).is_err(), "{path}");
        }
        let json = format!(r#"{{"format":"f","files":{{"tokenizer/vocab.txt":"{h}"}}}}"#);
        assert!(Manifest::parse(json.as_bytes()).is_ok());
    }
}
