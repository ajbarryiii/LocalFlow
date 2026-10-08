//! Minimal safetensors reader: an 8-byte little-endian header length, a JSON
//! header, then raw little-endian tensor data.

use std::collections::BTreeMap;
use std::path::Path;

use crate::{Result, bail};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dtype {
    U8,
    I64,
    F16,
    F32,
}

impl Dtype {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "U8" => Dtype::U8,
            "I64" => Dtype::I64,
            "F16" => Dtype::F16,
            "F32" => Dtype::F32,
            _ => return None,
        })
    }

    pub fn size(self) -> usize {
        match self {
            Dtype::U8 => 1,
            Dtype::F16 => 2,
            Dtype::F32 => 4,
            Dtype::I64 => 8,
        }
    }
}

#[derive(Clone, Debug)]
pub struct TensorInfo {
    pub dtype: Dtype,
    pub shape: Vec<usize>,
    start: usize,
    end: usize,
}

pub struct SafeTensors {
    bytes: Vec<u8>,
    data_start: usize,
    pub metadata: BTreeMap<String, String>,
    pub tensors: BTreeMap<String, TensorInfo>,
}

impl SafeTensors {
    pub fn open(path: &Path) -> Result<Self> {
        Self::parse(std::fs::read(path)?)
    }

    pub fn parse(bytes: Vec<u8>) -> Result<Self> {
        if bytes.len() < 8 {
            bail!("safetensors: file too short");
        }
        let header_len = u64::from_le_bytes(bytes[..8].try_into().unwrap());
        let Some(data_start) = usize::try_from(header_len)
            .ok()
            .and_then(|n| n.checked_add(8))
        else {
            bail!("safetensors: header length overflows");
        };
        if data_start > bytes.len() {
            bail!("safetensors: header length {header_len} exceeds file size");
        }
        let header: serde_json::Value = serde_json::from_slice(&bytes[8..data_start])
            .map_err(|e| crate::Error(format!("safetensors: header json: {e}")))?;
        let Some(entries) = header.as_object() else {
            bail!("safetensors: header is not an object");
        };
        let data_len = bytes.len() - data_start;
        let mut metadata = BTreeMap::new();
        let mut tensors = BTreeMap::new();
        for (name, entry) in entries {
            if name == "__metadata__" {
                for (k, v) in entry.as_object().into_iter().flatten() {
                    if let Some(v) = v.as_str() {
                        metadata.insert(k.clone(), v.to_owned());
                    }
                }
                continue;
            }
            let info = parse_entry(entry)
                .ok_or_else(|| crate::Error(format!("safetensors: malformed entry for {name}")))?;
            let bytes_needed = info
                .shape
                .iter()
                .try_fold(info.dtype.size(), |acc, &d| acc.checked_mul(d));
            if info.end < info.start
                || info.end > data_len
                || Some(info.end - info.start) != bytes_needed
            {
                bail!("safetensors: bad data offsets for {name}");
            }
            tensors.insert(name.clone(), info);
        }
        // Tensors must not share bytes.
        let mut ranges: Vec<(usize, usize, &str)> = tensors
            .iter()
            .map(|(n, t)| (t.start, t.end, n.as_str()))
            .collect();
        ranges.sort();
        for w in ranges.windows(2) {
            if w[1].0 < w[0].1 {
                bail!("safetensors: {} overlaps {}", w[1].2, w[0].2);
            }
        }
        Ok(SafeTensors {
            bytes,
            data_start,
            metadata,
            tensors,
        })
    }

    pub fn get(&self, name: &str) -> Result<(&TensorInfo, &[u8])> {
        let Some(info) = self.tensors.get(name) else {
            bail!("missing tensor {name}");
        };
        let data = &self.bytes[self.data_start + info.start..self.data_start + info.end];
        Ok((info, data))
    }

    pub fn contains(&self, name: &str) -> bool {
        self.tensors.contains_key(name)
    }

    pub fn f32_vec(&self, name: &str) -> Result<Vec<f32>> {
        let (info, data) = self.get(name)?;
        if info.dtype != Dtype::F32 {
            bail!("{name}: expected F32, found {:?}", info.dtype);
        }
        Ok(data
            .as_chunks::<4>()
            .0
            .iter()
            .map(|b| f32::from_le_bytes(*b))
            .collect())
    }

    /// An F16 or F32 tensor widened to f32 (exact), with its shape.
    pub fn float_vec(&self, name: &str) -> Result<(Vec<usize>, Vec<f32>)> {
        let (info, data) = self.get(name)?;
        let values = match info.dtype {
            Dtype::F32 => self.f32_vec(name)?,
            Dtype::F16 => data
                .as_chunks::<2>()
                .0
                .iter()
                .map(|b| crate::half::f16_to_f32(u16::from_le_bytes(*b)))
                .collect(),
            other => bail!("{name}: expected F16 or F32, found {other:?}"),
        };
        Ok((info.shape.clone(), values))
    }

    /// Hashable view of the whole file as read from disk.
    pub fn file_bytes(&self) -> &[u8] {
        &self.bytes
    }
}

fn parse_entry(entry: &serde_json::Value) -> Option<TensorInfo> {
    let dtype = Dtype::parse(entry.get("dtype")?.as_str()?)?;
    let shape = entry
        .get("shape")?
        .as_array()?
        .iter()
        .map(|d| d.as_u64().and_then(|d| usize::try_from(d).ok()))
        .collect::<Option<Vec<_>>>()?;
    let offsets = entry.get("data_offsets")?.as_array()?;
    if offsets.len() != 2 {
        return None;
    }
    let start = usize::try_from(offsets[0].as_u64()?).ok()?;
    let end = usize::try_from(offsets[1].as_u64()?).ok()?;
    Some(TensorInfo {
        dtype,
        shape,
        start,
        end,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build(header: &str, data: &[u8]) -> Vec<u8> {
        let mut out = (header.len() as u64).to_le_bytes().to_vec();
        out.extend_from_slice(header.as_bytes());
        out.extend_from_slice(data);
        out
    }

    #[test]
    fn parses_tensors_and_metadata() {
        let header = r#"{"__metadata__":{"format":"x"},"a":{"dtype":"F32","shape":[2],"data_offsets":[0,8]},"b":{"dtype":"U8","shape":[1,3],"data_offsets":[8,11]}}"#;
        let mut data = Vec::new();
        data.extend_from_slice(&1.5f32.to_le_bytes());
        data.extend_from_slice(&(-2.0f32).to_le_bytes());
        data.extend_from_slice(&[7, 8, 9]);
        let st = SafeTensors::parse(build(header, &data)).unwrap();
        assert_eq!(st.metadata["format"], "x");
        assert_eq!(st.f32_vec("a").unwrap(), vec![1.5, -2.0]);
        let (info, bytes) = st.get("b").unwrap();
        assert_eq!(info.shape, vec![1, 3]);
        assert_eq!(bytes, &[7, 8, 9]);
    }

    #[test]
    fn rejects_offsets_that_disagree_with_shape() {
        let header = r#"{"a":{"dtype":"F32","shape":[3],"data_offsets":[0,8]}}"#;
        assert!(SafeTensors::parse(build(header, &[0; 8])).is_err());
    }

    #[test]
    fn rejects_overlap_and_overflowing_shapes() {
        let overlap = r#"{"a":{"dtype":"U8","shape":[4],"data_offsets":[0,4]},"b":{"dtype":"U8","shape":[4],"data_offsets":[2,6]}}"#;
        assert!(SafeTensors::parse(build(overlap, &[0; 6])).is_err());
        let huge = format!(
            r#"{{"a":{{"dtype":"F32","shape":[{},{}],"data_offsets":[0,0]}}}}"#,
            u64::MAX / 2,
            4
        );
        assert!(SafeTensors::parse(build(&huge, &[])).is_err());
    }

    #[test]
    fn rejects_offsets_past_end() {
        let header = r#"{"a":{"dtype":"U8","shape":[4],"data_offsets":[0,4]}}"#;
        assert!(SafeTensors::parse(build(header, &[0; 3])).is_err());
    }
}
