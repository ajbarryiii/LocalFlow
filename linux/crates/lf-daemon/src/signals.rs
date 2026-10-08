//! SIGTERM / SIGINT / SIGHUP handling without async-signal-safety concerns:
//! the signals are blocked in every thread and one thread waits for them
//! with `sigwait`.

fn termination_set() -> libc::sigset_t {
    // SAFETY: sigemptyset/sigaddset initialize and modify a local set.
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        for sig in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::sigaddset(&mut set, sig);
        }
        set
    }
}

/// Blocks the termination signals in the calling thread. Call before
/// spawning any thread so that every thread inherits the mask.
pub fn block() -> Result<(), String> {
    let set = termination_set();
    // SAFETY: `set` is initialized; the old mask is not needed.
    let rc = unsafe { libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut()) };
    if rc != 0 {
        return Err(format!(
            "pthread_sigmask: {}",
            std::io::Error::from_raw_os_error(rc)
        ));
    }
    Ok(())
}

/// Calls `on_signal` once, from a new thread, when a termination signal
/// arrives. Requires [`block`] first.
pub fn on_termination(on_signal: impl FnOnce(i32) + Send + 'static) -> Result<(), String> {
    std::thread::Builder::new()
        .name("lf-signals".into())
        .spawn(move || {
            let set = termination_set();
            let mut sig = 0;
            loop {
                // SAFETY: `set` is initialized and `sig` is writable.
                let rc = unsafe { libc::sigwait(&set, &mut sig) };
                if rc == 0 {
                    break;
                }
            }
            on_signal(sig);
        })
        .map(|_| ())
        .map_err(|e| format!("cannot start the signal thread: {e}"))
}
