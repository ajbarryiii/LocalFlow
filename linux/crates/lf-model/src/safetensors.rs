//! Minimal safetensors reader: an 8-byte little-endian header length, a JSON
//! header, then raw little-endian tensor data.

use std::collections::BTreeMap;
use std::path::Path;

use crate::{Result, bail};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dtype {
    U8,
    I32,
    I64,
    F16,
    F32,
}

impl Dtype {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "U8" => Dtype::U8,
            "I32" => Dtype::I32,
            "I64" => Dtype::I64,
            "F16" => Dtype::F16,
            "F32" => Dtype::F32,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Dtype::U8 => "U8",
            Dtype::I32 => "I32",
            Dtype::I64 => "I64",
            Dtype::F16 => "F16",
            Dtype::F32 => "F32",
        }
    }

    pub fn size(self) -> usize {
        match self {
            Dtype::U8 => 1,
            Dtype::F16 => 2,
            Dtype::I32 | Dtype::F32 => 4,
            Dtype::I64 => 8,
        }
    }
}

/// One tensor for [`serialize`]: name, dtype, shape and little-endian bytes.
pub struct TensorData<'a> {
    pub name: &'a str,
    pub dtype: Dtype,
    pub shape: Vec<usize>,
    pub bytes: std::borrow::Cow<'a, [u8]>,
}

impl<'a> TensorData<'a> {
    pub fn f32(name: &'a str, shape: Vec<usize>, values: &[f32]) -> Self {
        Self::owned(
            name,
            Dtype::F32,
            shape,
            values.iter().flat_map(|v| v.to_le_bytes()),
        )
    }

    pub fn i32(name: &'a str, shape: Vec<usize>, values: &[i32]) -> Self {
        Self::owned(
            name,
            Dtype::I32,
            shape,
            values.iter().flat_map(|v| v.to_le_bytes()),
        )
    }

    pub fn i64(name: &'a str, shape: Vec<usize>, values: &[i64]) -> Self {
        Self::owned(
            name,
            Dtype::I64,
            shape,
            values.iter().flat_map(|v| v.to_le_bytes()),
        )
    }

    pub fn u8(name: &'a str, shape: Vec<usize>, values: &[u8]) -> Self {
        Self::owned(name, Dtype::U8, shape, values.iter().copied())
    }

    fn owned(name: &'a str, dtype: Dtype, shape: Vec<usize>, b: impl Iterator<Item = u8>) -> Self {
        TensorData {
            name,
            dtype,
            shape,
            bytes: std::borrow::Cow::Owned(b.collect()),
        }
    }
}

/// A safetensors file: string `metadata` and `tensors` (names unique, none
/// `__metadata__`, byte length matching dtype and shape), data in the given order.
pub fn serialize(metadata: &BTreeMap<String, String>, tensors: &[TensorData]) -> Result<Vec<u8>> {
    let mut header = serde_json::Map::new();
    if !metadata.is_empty() {
        header.insert("__metadata__".into(), serde_json::json!(metadata));
    }
    let mut offset = 0usize;
    for t in tensors {
        let need = t
            .shape
            .iter()
            .try_fold(t.dtype.size(), |acc, &d| acc.checked_mul(d));
        if need != Some(t.bytes.len()) {
            bail!(
                "safetensors: {} has {} bytes for shape {:?}",
                t.name,
                t.bytes.len(),
                t.shape
            );
        }
        let entry = serde_json::json!({
            "dtype": t.dtype.name(),
            "shape": t.shape,
            "data_offsets": [offset, offset + t.bytes.len()],
        });
        if t.name == "__metadata__" || header.insert(t.name.to_owned(), entry).is_some() {
            bail!("safetensors: duplicate or reserved tensor name {}", t.name);
        }
        offset += t.bytes.len();
    }
    let mut json = serde_json::to_vec(&serde_json::Value::Object(header))
        .map_err(|e| crate::Error(format!("safetensors: {e}")))?;
    // Pad the header with spaces to 8 bytes, as the reference writer does.
    while !json.len().is_multiple_of(8) {
        json.push(b' ');
    }
    let mut out = Vec::with_capacity(8 + json.len() + offset);
    out.extend_from_slice(&(json.len() as u64).to_le_bytes());
    out.extend_from_slice(&json);
    for t in tensors {
        out.extend_from_slice(&t.bytes);
    }
    Ok(out)
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

    pub fn i32_vec(&self, name: &str) -> Result<Vec<i32>> {
        let (info, data) = self.get(name)?;
        if info.dtype != Dtype::I32 {
            bail!("{name}: expected I32, found {:?}", info.dtype);
        }
        Ok(data
            .as_chunks::<4>()
            .0
            .iter()
            .map(|b| i32::from_le_bytes(*b))
            .collect())
    }

    pub fn i64_vec(&self, name: &str) -> Result<Vec<i64>> {
        let (info, data) = self.get(name)?;
        if info.dtype != Dtype::I64 {
            bail!("{name}: expected I64, found {:?}", info.dtype);
        }
        Ok(data
            .as_chunks::<8>()
            .0
            .iter()
            .map(|b| i64::from_le_bytes(*b))
            .collect())
    }

    pub fn u8_vec(&self, name: &str) -> Result<Vec<u8>> {
        let (info, data) = self.get(name)?;
        if info.dtype != Dtype::U8 {
            bail!("{name}: expected U8, found {:?}", info.dtype);
        }
        Ok(data.to_vec())
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
    fn serialize_round_trips_every_dtype() {
        let meta: BTreeMap<String, String> = [("variant".to_owned(), "L3".to_owned())].into();
        let tensors = [
            TensorData::f32("w", vec![2, 2], &[1.0, -2.5, 3.0, 0.0]),
            TensorData::i32("t", vec![3], &[-1, 0, 1024]),
            TensorData::i64("o", vec![2], &[0, i64::MAX]),
            TensorData::u8("k", vec![1, 2], &[0, 1]),
            TensorData::f32("s", vec![], &[7.0]),
        ];
        let bytes = serialize(&meta, &tensors).unwrap();
        let st = SafeTensors::parse(bytes).unwrap();
        assert_eq!(st.metadata, meta);
        assert_eq!(st.f32_vec("w").unwrap(), [1.0, -2.5, 3.0, 0.0]);
        assert_eq!(st.tensors["w"].shape, [2, 2]);
        assert_eq!(st.i32_vec("t").unwrap(), [-1, 0, 1024]);
        assert_eq!(st.i64_vec("o").unwrap(), [0, i64::MAX]);
        assert_eq!(st.u8_vec("k").unwrap(), [0, 1]);
        assert_eq!(st.f32_vec("s").unwrap(), [7.0]);
        assert!(st.tensors["s"].shape.is_empty());
        // Typed accessors check the dtype.
        assert!(st.i32_vec("w").is_err() && st.f32_vec("t").is_err() && st.i64_vec("t").is_err());
        // Wrong byte counts and duplicate names are refused.
        let bad = TensorData::f32("w", vec![3], &[1.0]);
        assert!(serialize(&meta, &[bad]).is_err());
        let dup = [
            TensorData::u8("a", vec![1], &[1]),
            TensorData::u8("a", vec![1], &[2]),
        ];
        assert!(serialize(&BTreeMap::new(), &dup).is_err());
    }

    #[test]
    fn rejects_offsets_past_end() {
        let header = r#"{"a":{"dtype":"U8","shape":[4],"data_offsets":[0,4]}}"#;
        assert!(SafeTensors::parse(build(header, &[0; 3])).is_err());
    }
}
