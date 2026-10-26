//! Overwriting audio before memory is released.

/// Zeroes every element `v`'s allocation can hold, including spare capacity
/// left behind by `clear`, `truncate` or `drain`, then empties it. Volatile
/// writes keep the optimizer from dropping the stores as dead.
pub fn wipe(v: &mut Vec<f32>) {
    let cap = v.capacity();
    let p = v.as_mut_ptr();
    for i in 0..cap {
        // SAFETY: `i < capacity`, so the slot is allocated, aligned and
        // exclusively ours; writing an `f32` there is valid even past `len`.
        unsafe { std::ptr::write_volatile(p.add(i), 0.0) };
    }
    v.clear();
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
}

/// A temporary audio buffer that is wiped when dropped, including during a
/// panic unwind.
pub struct Wiped(pub Vec<f32>);

impl Drop for Wiped {
    fn drop(&mut self) {
        wipe(&mut self.0);
    }
}

/// Appends `extra` to `v`. If `v` must grow, the old allocation is wiped
/// before it is freed instead of being left behind by a reallocation.
pub fn extend_wiping(
    v: &mut Vec<f32>,
    extra: impl ExactSizeIterator<Item = f32>,
    new_cap: usize,
) {
    let need = v.len() + extra.len();
    if v.capacity() < need {
        let mut bigger = Vec::with_capacity(new_cap.max(need));
        bigger.extend_from_slice(v);
        wipe(v);
        *v = bigger;
    }
    v.extend(extra);
}

/// Makes room for `additional` more elements without a reallocation that
/// would leave an unwiped copy behind: if `v` must grow, its contents move to
/// a new allocation and the old one is wiped.
pub fn reserve_wiping(v: &mut Vec<f32>, additional: usize) {
    let need = v.len().checked_add(additional).expect("capacity overflow");
    if v.capacity() < need {
        let mut bigger = Vec::with_capacity(need.max(v.capacity().saturating_mul(2)));
        bigger.extend_from_slice(v);
        wipe(v);
        *v = bigger;
    }
}

/// Appends `extra` to `v`, growing it as [`reserve_wiping`] does.
pub fn push_wiping(v: &mut Vec<f32>, extra: &[f32]) {
    reserve_wiping(v, extra.len());
    v.extend_from_slice(extra);
}

/// Shortens `v` to `len`, zeroing the elements it drops.
pub fn truncate_wiping(v: &mut Vec<f32>, len: usize) {
    let p = v.as_mut_ptr();
    for i in len..v.len() {
        // SAFETY: `i < v.len()`, so the slot is initialized and ours.
        unsafe { std::ptr::write_volatile(p.add(i), 0.0) };
    }
    v.truncate(len);
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
}

/// Removes `range` from `v`, moving the rest down and zeroing the vacated
/// elements at the end.
pub fn remove_wiping(v: &mut Vec<f32>, range: std::ops::Range<usize>) {
    let len = v.len();
    assert!(range.start <= range.end && range.end <= len, "range out of bounds");
    v.copy_within(range.end..len, range.start);
    truncate_wiping(v, len - range.len());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wipes_spare_capacity_too() {
        let mut v = vec![0.5f32; 64];
        v.truncate(10);
        let p = v.as_ptr();
        let cap = v.capacity();
        wipe(&mut v);
        assert!(v.is_empty());
        assert_eq!(v.capacity(), cap);
        // The allocation is still owned by `v`, so reading it is sound.
        let all = unsafe { std::slice::from_raw_parts(p, cap) };
        assert!(all.iter().all(|&x| x == 0.0));
    }

    #[test]
    fn growth_keeps_contents() {
        let mut v = Vec::with_capacity(2);
        extend_wiping(&mut v, [0.25f32, 0.5].into_iter(), 2);
        extend_wiping(&mut v, [0.75f32].into_iter(), 8);
        assert_eq!(v, vec![0.25, 0.5, 0.75]);
        assert!(v.capacity() >= 8);
    }

    #[test]
    fn truncation_and_removal_zero_what_they_drop() {
        let mut v: Vec<f32> = (1..=8).map(|i| i as f32).collect();
        remove_wiping(&mut v, 2..5);
        assert_eq!(v, [1.0, 2.0, 6.0, 7.0, 8.0]);
        let p = v.as_ptr();
        // The allocation is still owned by `v`, so reading it is sound.
        let all = unsafe { std::slice::from_raw_parts(p, 8) };
        assert_eq!(&all[5..], [0.0; 3]);
        truncate_wiping(&mut v, 1);
        let all = unsafe { std::slice::from_raw_parts(p, 8) };
        assert_eq!(all, [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]);
    }
}
