//! Text output through the kernel's uinput: a virtual keyboard device that
//! works under any Wayland compositor and under X11.
//!
//! [`UinputTyper`] creates one keyboard device (`/dev/uinput`, plain ioctls)
//! and types by sending key codes. The desktop interprets them with its own
//! keyboard layout, which this process cannot read, so the layout to type
//! with is configured ([`UinputConfig::layout`]; by default libxkbcommon's
//! defaults, `XKB_DEFAULT_*` or US). Text the layout cannot produce is
//! refused, and nothing is typed. Only the layout's first group is used,
//! and Caps Lock or another locked modifier on the physical keyboard
//! changes what the keys type.
//!
//! Access: opening `/dev/uinput` needs write permission on it (a udev rule
//! or group membership, e.g. NixOS `hardware.uinput.enable` and the `uinput`
//! group). With that permission any program the user runs can inject input;
//! LocalFlow only ever sends the keys of the text it types.
//!
//! Privacy: text is never logged or included in errors. Key events go to the
//! kernel, which passes them to the desktop like a physical keyboard's.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use lf_io_api::sys::wait_budget;
use lf_io_api::{IoError, TextOutput};

use crate::layout::{self, Layout, Rmlvo, Token};
use crate::{KeySink, Pace, type_strokes};

/// The device node.
pub const DEFAULT_PATH: &str = "/dev/uinput";

/// Name of the created device, as compositors and `libinput list-devices`
/// show it.
pub const DEVICE_NAME: &str = "LocalFlow virtual keyboard";

/// `EV_SYN`, `EV_KEY` and `SYN_REPORT` from `linux/input-event-codes.h`.
pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const SYN_REPORT: u16 = 0;
/// `BUS_VIRTUAL` from `linux/input.h`.
pub const BUS_VIRTUAL: u16 = 0x06;

/// `struct input_event` on 64-bit Linux: a 16-byte `timeval` (left zero;
/// the kernel stamps uinput events itself), `type`, `code` and `value`.
pub const EVENT_SIZE: usize = 24;
const _: () = assert!(std::mem::size_of::<libc::input_event>() == EVENT_SIZE);

const fn ioc(dir: u32, nr: u32, size: usize) -> libc::Ioctl {
    // asm-generic layout (x86, Arm, RISC-V): dir:2 size:14 type:8 nr:8.
    ((dir << 30) | ((size as u32) << 16) | ((b'U' as u32) << 8) | nr) as libc::Ioctl
}
const IOC_NONE: u32 = 0;
const IOC_WRITE: u32 = 1;

/// `UI_DEV_CREATE`, `UI_DEV_DESTROY`, `UI_DEV_SETUP`, `UI_SET_EVBIT` and
/// `UI_SET_KEYBIT` from `linux/uinput.h`.
pub const UI_DEV_CREATE: libc::Ioctl = ioc(IOC_NONE, 1, 0);
pub const UI_DEV_DESTROY: libc::Ioctl = ioc(IOC_NONE, 2, 0);
pub const UI_DEV_SETUP: libc::Ioctl = ioc(IOC_WRITE, 3, std::mem::size_of::<libc::uinput_setup>());
pub const UI_SET_EVBIT: libc::Ioctl = ioc(IOC_WRITE, 100, std::mem::size_of::<libc::c_int>());
pub const UI_SET_KEYBIT: libc::Ioctl = ioc(IOC_WRITE, 101, std::mem::size_of::<libc::c_int>());

/// One `struct input_event`.
pub fn event(type_: u16, code: u16, value: i32) -> [u8; EVENT_SIZE] {
    let mut e = [0u8; EVENT_SIZE];
    e[16..18].copy_from_slice(&type_.to_ne_bytes());
    e[18..20].copy_from_slice(&code.to_ne_bytes());
    e[20..24].copy_from_slice(&value.to_ne_bytes());
    e
}

/// Key events framed for uinput: every key change is followed by a
/// `SYN_REPORT`, as a physical keyboard reports it.
pub struct EventWriter<W: Write> {
    out: W,
    buf: Vec<u8>,
}

impl<W: Write> EventWriter<W> {
    pub fn new(out: W) -> Self {
        Self {
            out,
            buf: Vec::new(),
        }
    }

    pub fn into_inner(self) -> W {
        self.out
    }
}

impl<W: Write> KeySink for EventWriter<W> {
    fn key(&mut self, code: u32, pressed: bool) -> Result<(), IoError> {
        let code = u16::try_from(code).map_err(|_| IoError("key code out of range".into()))?;
        self.buf.extend(event(EV_KEY, code, i32::from(pressed)));
        self.buf.extend(event(EV_SYN, SYN_REPORT, 0));
        Ok(())
    }

    /// Writes to the device never wait: the kernel takes each event at once.
    fn flush(&mut self, _deadline: Instant) -> Result<(), IoError> {
        let result = self.out.write_all(&self.buf);
        self.buf.clear();
        result.map_err(|e| IoError(format!("cannot write to the uinput device: {}", e.kind())))
    }
}

/// Typing configuration.
#[derive(Clone, Debug)]
pub struct UinputConfig {
    pub path: PathBuf,
    /// The layout the desktop applies to the device.
    pub layout: Rmlvo,
    /// Pause after each character.
    pub key_delay: Duration,
    /// Upper bound for any single wait.
    pub timeout: Duration,
    /// Upper bound for one whole `type_text`/`press_enter` call, device
    /// creation included.
    pub call_timeout: Option<Duration>,
    /// Wait after creating the device before typing, so the compositor (or
    /// X server) has picked it up; keys sent earlier are lost.
    pub settle: Duration,
}

impl Default for UinputConfig {
    fn default() -> Self {
        Self {
            path: PathBuf::from(DEFAULT_PATH),
            layout: Rmlvo::default(),
            key_delay: Duration::from_millis(1),
            timeout: Duration::from_secs(1),
            call_timeout: None,
            settle: Duration::from_millis(500),
        }
    }
}

/// Whether `path` can be opened for writing now (a probe: no device is
/// created).
pub fn writable(path: &Path) -> bool {
    open(path).is_ok()
}

fn open(path: &Path) -> std::io::Result<File> {
    OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
}

/// A created uinput keyboard; destroyed when dropped.
struct Device {
    writer: EventWriter<File>,
}

impl Device {
    fn create(path: &Path, codes: &[u32]) -> Result<Device, IoError> {
        let file = open(path)
            .map_err(|e| IoError(format!("cannot open the uinput device: {}", e.kind())))?;
        let fd = file.as_raw_fd();
        let fail = |what: &str| {
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::ENOTTY) {
                IoError("the uinput path is not a uinput device".into())
            } else {
                IoError(format!("uinput {what} failed: {}", err.kind()))
            }
        };
        // SAFETY: plain ioctls with integer arguments on an fd we own.
        if unsafe { libc::ioctl(fd, UI_SET_EVBIT, libc::c_int::from(EV_KEY)) } < 0 {
            return Err(fail("setup"));
        }
        for &code in codes {
            // SAFETY: as above.
            if unsafe { libc::ioctl(fd, UI_SET_KEYBIT, code as libc::c_int) } < 0 {
                return Err(fail("setup"));
            }
        }
        // SAFETY: an all-zero uinput_setup is valid.
        let mut setup: libc::uinput_setup = unsafe { std::mem::zeroed() };
        setup.id.bustype = BUS_VIRTUAL;
        setup.id.version = 1;
        for (dst, &src) in setup.name.iter_mut().zip(DEVICE_NAME.as_bytes()) {
            *dst = src as libc::c_char;
        }
        // SAFETY: `setup` is a valid uinput_setup that outlives the call.
        if unsafe { libc::ioctl(fd, UI_DEV_SETUP, &setup as *const libc::uinput_setup) } < 0 {
            return Err(fail("setup"));
        }
        // SAFETY: plain ioctl without argument.
        if unsafe { libc::ioctl(fd, UI_DEV_CREATE) } < 0 {
            return Err(fail("device creation"));
        }
        Ok(Device {
            writer: EventWriter::new(file),
        })
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        // Destroying the device releases any key it still holds.
        let fd = self.writer.out.as_raw_fd();
        // SAFETY: plain ioctl without argument on an fd we own.
        unsafe { libc::ioctl(fd, UI_DEV_DESTROY) };
    }
}

/// `TextOutput` backed by a uinput keyboard.
///
/// The device is created by [`Self::connect`] or on first use and kept
/// until drop; after a write error it is destroyed and the next call
/// creates a new one.
pub struct UinputTyper {
    config: UinputConfig,
    layout: Layout,
    device: Option<Device>,
}

impl UinputTyper {
    /// Compiles the configured layout; opens nothing yet.
    pub fn new(config: UinputConfig) -> Result<Self, IoError> {
        let layout = Layout::from_names(&config.layout)?;
        Ok(Self {
            config,
            layout,
            device: None,
        })
    }

    /// Creates the device now and waits for it to settle, so setup errors
    /// (no permission) surface early. Idempotent.
    pub fn connect(&mut self) -> Result<(), IoError> {
        self.device_for(None).map(|_| ())
    }

    fn device_for(&mut self, deadline: Option<Instant>) -> Result<&mut Device, IoError> {
        if self.device.is_none() {
            wait_budget(self.config.timeout, deadline, Instant::now())?;
            let mut codes = self.layout.key_codes();
            codes.extend([layout::KEY_ENTER, layout::KEY_TAB]);
            codes.sort_unstable();
            codes.dedup();
            let device = Device::create(&self.config.path, &codes)?;
            let settle = self.config.settle;
            let left = deadline.map_or(settle, |d| d.saturating_duration_since(Instant::now()));
            std::thread::sleep(settle.min(left));
            self.device = Some(device);
            if left < settle {
                return Err(IoError(
                    "typing did not finish within its time limit".into(),
                ));
            }
        }
        Ok(self.device.as_mut().expect("device just set"))
    }

    fn type_tokens(&mut self, strokes: Vec<layout::Stroke>) -> Result<(), IoError> {
        if strokes.is_empty() {
            return Ok(());
        }
        let deadline = self.config.call_timeout.map(|t| Instant::now() + t);
        let pace = Pace {
            key_delay: self.config.key_delay,
            timeout: self.config.timeout,
            deadline,
        };
        let result = self
            .device_for(deadline)
            .and_then(|d| type_strokes(&mut d.writer, &strokes, pace));
        if result.is_err() {
            self.device = None;
        }
        result
    }
}

impl TextOutput for UinputTyper {
    fn check(&self, text: &str) -> Result<(), IoError> {
        self.layout.strokes(text).map(|_| ())
    }

    fn type_text(&mut self, text: &str) -> Result<(), IoError> {
        let strokes = self.layout.strokes(text)?;
        self.type_tokens(strokes)
    }

    fn press_enter(&mut self) -> Result<(), IoError> {
        let stroke = self
            .layout
            .stroke(Token::Return)
            .ok_or_else(|| IoError("the keyboard layout has no Return key".into()))?
            .clone();
        self.type_tokens(vec![stroke])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ioctl_numbers_match_linux_uinput_h() {
        assert_eq!(UI_DEV_CREATE, 0x5501);
        assert_eq!(UI_DEV_DESTROY, 0x5502);
        assert_eq!(UI_DEV_SETUP, 0x405c_5503);
        assert_eq!(UI_SET_EVBIT, 0x4004_5564);
        assert_eq!(UI_SET_KEYBIT, 0x4004_5565);
    }
}
