//! Small system helpers shared by the backends: bounded waits on file
//! descriptors, the kernel clocks other processes stamp events with, and
//! the time budget of a typing call.
//!
//! Errors here are plain `std::io::Error`s or fixed messages; callers turn
//! them into their own.

use std::os::fd::{AsRawFd, BorrowedFd};
use std::time::{Duration, Instant};

use crate::IoError;

/// Waits until `fd` reports any of `events` (or a hang-up or error) and
/// returns `Ok(true)`, or until `deadline` passes and returns `Ok(false)`.
/// Interrupted polls are retried; any other poll failure is returned.
/// Readiness says nothing about what is ready: the caller's next I/O
/// operation reports a hang-up or error.
pub fn wait_fd(fd: BorrowedFd<'_>, events: i16, deadline: Instant) -> std::io::Result<bool> {
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Ok(false);
        }
        let mut pfd = libc::pollfd {
            fd: fd.as_raw_fd(),
            events,
            revents: 0,
        };
        let ms = left.as_millis().clamp(1, i32::MAX as u128) as libc::c_int;
        // SAFETY: one valid pollfd.
        let n = unsafe { libc::poll(&mut pfd, 1, ms) };
        if n < 0 {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
        if n > 0 {
            return Ok(true);
        }
    }
}

fn clock(id: libc::clockid_t) -> Duration {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid timespec to write; both clocks used here
    // always exist on Linux.
    unsafe { libc::clock_gettime(id, &mut ts) };
    Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32)
}

/// `CLOCK_MONOTONIC` now: the clock compositors, libei and `localflowctl`
/// stamp events with (shared by all processes).
pub fn monotonic() -> Duration {
    clock(libc::CLOCK_MONOTONIC)
}

/// `CLOCK_BOOTTIME`: like `CLOCK_MONOTONIC`, but counting suspend.
pub fn boottime() -> Duration {
    clock(libc::CLOCK_BOOTTIME)
}

/// How long the next wait of a typing call may take: `timeout`, cut to
/// what is left before the call's `deadline`. Fails once the deadline has
/// passed.
pub fn wait_budget(
    timeout: Duration,
    deadline: Option<Instant>,
    now: Instant,
) -> Result<Duration, IoError> {
    match deadline {
        None => Ok(timeout),
        Some(d) => {
            let left = d.saturating_duration_since(now);
            if left.is_zero() {
                Err(IoError(
                    "typing did not finish within its time limit".into(),
                ))
            } else {
                Ok(timeout.min(left))
            }
        }
    }
}

/// The pause after a typed key: sleeps for `delay`, but never past
/// `deadline` (the caller's next wait then fails the call). Returns at
/// once for a zero delay.
pub fn pause(delay: Duration, deadline: Option<Instant>) {
    if !delay.is_zero() {
        let left = deadline.map_or(delay, |d| d.saturating_duration_since(Instant::now()));
        std::thread::sleep(delay.min(left));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::{AsFd, FromRawFd, OwnedFd};

    /// A pipe: (read end, write end).
    fn pipe() -> (OwnedFd, OwnedFd) {
        let mut fds = [0; 2];
        // SAFETY: valid out-array of two fds.
        assert_eq!(unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
        // SAFETY: fresh fds owned by nobody else.
        unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
    }

    #[test]
    fn wait_fd_reports_readiness() {
        let (r, w) = pipe();
        let far = Instant::now() + Duration::from_secs(5);
        let t0 = Instant::now();
        assert!(wait_fd(w.as_fd(), libc::POLLOUT, far).unwrap());
        // SAFETY: writes one byte from a valid buffer.
        assert_eq!(
            unsafe { libc::write(w.as_raw_fd(), b"x".as_ptr().cast(), 1) },
            1
        );
        assert!(wait_fd(r.as_fd(), libc::POLLIN, far).unwrap());
        assert!(t0.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn wait_fd_reports_a_hang_up_as_ready() {
        let (r, w) = pipe();
        drop(w);
        let far = Instant::now() + Duration::from_secs(5);
        assert!(wait_fd(r.as_fd(), libc::POLLIN, far).unwrap());
    }

    #[test]
    fn wait_fd_gives_up_at_the_deadline() {
        let (r, _w) = pipe();
        let t0 = Instant::now();
        let ready = wait_fd(r.as_fd(), libc::POLLIN, t0 + Duration::from_millis(60)).unwrap();
        let took = t0.elapsed();
        assert!(!ready);
        assert!(took >= Duration::from_millis(60), "{took:?}");
        assert!(took < Duration::from_secs(1), "{took:?}");
        // A deadline that has passed returns at once.
        assert!(!wait_fd(r.as_fd(), libc::POLLIN, Instant::now()).unwrap());
    }

    #[test]
    fn clocks_advance_and_boottime_includes_monotonic() {
        let a = monotonic();
        let b = boottime();
        assert!(a > Duration::ZERO);
        assert!(b >= a, "{b:?} < {a:?}");
        std::thread::sleep(Duration::from_millis(2));
        assert!(monotonic() >= a + Duration::from_millis(2));
        assert!(boottime() >= b + Duration::from_millis(2));
    }

    #[test]
    fn call_deadline_cuts_every_wait() {
        let now = Instant::now();
        let t = Duration::from_secs(1);
        // No call deadline: the per-wait timeout.
        assert_eq!(wait_budget(t, None, now).unwrap(), t);
        // A nearer deadline shortens the wait.
        let d = now + Duration::from_millis(300);
        assert_eq!(
            wait_budget(t, Some(d), now).unwrap(),
            Duration::from_millis(300)
        );
        // A farther one does not lengthen it.
        assert_eq!(
            wait_budget(t, Some(now + Duration::from_secs(9)), now).unwrap(),
            t
        );
        // Once it has passed, the call fails.
        let err = wait_budget(t, Some(now), now).unwrap_err();
        assert!(err.0.contains("time limit"), "{err}");
        assert!(wait_budget(t, Some(now), now + Duration::from_millis(1)).is_err());
    }

    #[test]
    fn pause_sleeps_the_delay_but_never_past_the_deadline() {
        let t0 = Instant::now();
        pause(Duration::from_millis(30), None);
        assert!(t0.elapsed() >= Duration::from_millis(30));

        let t0 = Instant::now();
        pause(Duration::from_secs(5), Some(t0 + Duration::from_millis(30)));
        let took = t0.elapsed();
        assert!(took >= Duration::from_millis(30), "{took:?}");
        assert!(took < Duration::from_secs(1), "{took:?}");

        // A passed deadline or a zero delay: no sleep at all.
        let t0 = Instant::now();
        pause(Duration::from_secs(5), Some(t0));
        pause(Duration::ZERO, None);
        assert!(t0.elapsed() < Duration::from_secs(1));
    }
}
