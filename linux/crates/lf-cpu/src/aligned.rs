/// A 64-byte aligned, zero-initialized byte buffer.
pub struct AlignedBuf {
    lines: Vec<Line>,
}

#[derive(Clone, Copy)]
#[repr(C, align(64))]
struct Line([u8; 64]);

impl AlignedBuf {
    pub fn new(bytes: usize) -> Self {
        AlignedBuf {
            lines: vec![Line([0; 64]); bytes.div_ceil(64)],
        }
    }

    pub fn len(&self) -> usize {
        self.lines.len() * 64
    }

    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }

    pub fn as_ptr(&self) -> *const u8 {
        self.lines.as_ptr().cast()
    }

    pub fn as_mut_ptr(&mut self) -> *mut u8 {
        self.lines.as_mut_ptr().cast()
    }
}
