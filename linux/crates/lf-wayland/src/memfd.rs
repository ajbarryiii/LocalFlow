//! Sealed, anonymous in-memory file holding a keymap for the compositor.

use std::fs::File;
use std::io::{self, Write};
use std::os::fd::{FromRawFd, OwnedFd};

/// Creates a memfd containing `text` followed by a NUL byte, sealed against
/// writes and resizing (receivers `mmap` it from offset 0). Returns the fd and its size
/// in bytes (including the NUL), as `zwp_virtual_keyboard_v1.keymap` expects.
///
/// The memfd is close-on-exec and never touches the filesystem.
pub fn sealed_keymap(text: &str) -> io::Result<(OwnedFd, u32)> {
    let size = text
        .len()
        .checked_add(1)
        .and_then(|n| u32::try_from(n).ok())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "keymap too large"))?;
    // SAFETY: the name is a valid NUL-terminated string; the flags are valid.
    let raw = unsafe {
        libc::memfd_create(
            c"localflow-keymap".as_ptr(),
            libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING,
        )
    };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: memfd_create returned a new fd that nothing else owns.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let mut file = File::from(fd);
    file.write_all(text.as_bytes())?;
    file.write_all(&[0])?;
    let fd = OwnedFd::from(file);
    let seals = libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_WRITE | libc::F_SEAL_SEAL;
    // SAFETY: fd is a valid memfd created with MFD_ALLOW_SEALING.
    if unsafe {
        libc::fcntl(
            std::os::fd::AsRawFd::as_raw_fd(&fd),
            libc::F_ADD_SEALS,
            seals,
        )
    } < 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok((fd, size))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Seek, SeekFrom};
    use std::os::fd::AsRawFd;

    #[test]
    fn contents_size_and_seals() {
        let (fd, size) = sealed_keymap("xkb_keymap {};").unwrap();
        assert_eq!(size as usize, "xkb_keymap {};".len() + 1);
        let raw = fd.as_raw_fd();
        // SAFETY: valid fd.
        let seals = unsafe { libc::fcntl(raw, libc::F_GET_SEALS) };
        assert!(seals & libc::F_SEAL_WRITE != 0);
        assert!(seals & libc::F_SEAL_SHRINK != 0);
        assert!(seals & libc::F_SEAL_GROW != 0);
        // SAFETY: valid fd.
        let fdflags = unsafe { libc::fcntl(raw, libc::F_GETFD) };
        assert!(fdflags & libc::FD_CLOEXEC != 0);
        let mut file = File::from(fd);
        file.seek(SeekFrom::Start(0)).unwrap();
        let mut buf = Vec::new();
        file.read_to_end(&mut buf).unwrap();
        assert_eq!(buf, b"xkb_keymap {};\0");
        assert!(file.write_all(b"x").is_err(), "write seal not applied");
    }
}
