//! `localflowd`: the LocalFlow dictation daemon.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use lf_daemon::config::{self, Config};
use lf_daemon::controller::Limits;
use lf_daemon::daemon::{self, Parts};
use lf_daemon::history;
use lf_daemon::{backends, error, info, log, paths, recognizer, signals, warn, worker};

const USAGE: &str = "usage: localflowd [--config PATH] [--check-config] [--fake-io]

  --config PATH    configuration file (default $XDG_CONFIG_HOME/localflow/config.json)
  --check-config   validate the configuration and exit
  --fake-io        record silence and discard text instead of using the
                   microphone and keyboard, and leave media players alone
                   (for testing)";

struct Args {
    config: Option<PathBuf>,
    check: bool,
    fake_io: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut a = Args {
        config: None,
        check: false,
        fake_io: false,
    };
    let mut it = std::env::args_os().skip(1);
    while let Some(arg) = it.next() {
        match arg.to_str() {
            Some("--config") => {
                a.config = Some(PathBuf::from(it.next().ok_or("--config needs a path")?));
            }
            Some("--check-config") => a.check = true,
            Some("--fake-io") => a.fake_io = true,
            Some("-h" | "--help") => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            _ => return Err(format!("unexpected argument {arg:?}\n{USAGE}")),
        }
    }
    Ok(a)
}

/// How long exiting waits for the logger to write what it holds. A stalled
/// stderr makes it give up rather than hang the exit.
const LOG_FLUSH_TIMEOUT: Duration = Duration::from_secs(1);

fn main() -> ExitCode {
    // Before any thread exists: the default hook writes to stderr
    // synchronously and would block a panicking thread on a stalled stderr.
    // (Installing it starts no thread; the logger starts on first use.)
    log::install_panic_hook();
    let code = match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            error!("{e}");
            ExitCode::FAILURE
        }
    };
    log::flush(LOG_FLUSH_TIMEOUT);
    code
}

/// Environment variables that make libraries print protocol traffic or
/// buffer contents to stderr (and so to journald), which would include typed
/// text. They are cleared before any library reads them.
const CONTENT_DEBUG_VARS: [&str; 1] = ["WAYLAND_DEBUG"];

fn run() -> Result<(), String> {
    let mut cleared = Vec::new();
    for var in CONTENT_DEBUG_VARS {
        if std::env::var_os(var).is_some() {
            // SAFETY: no other thread exists yet (this is the first thing
            // `main` does), so nothing can read the environment concurrently.
            unsafe { std::env::remove_var(var) };
            cleared.push(var);
        }
    }
    // Before any thread exists, so every thread inherits the mask.
    signals::block()?;
    for var in cleared {
        warn!("ignoring {var}: it would log typed text");
    }
    // Until the daemon runs, a termination signal simply exits.
    let shutdown: Arc<Mutex<Option<Sender<daemon::Event>>>> = Arc::default();
    let target = Arc::clone(&shutdown);
    signals::on_termination(move |sig| {
        let sender = target.lock().unwrap_or_else(|e| e.into_inner()).clone();
        match sender {
            Some(events) => {
                info!("signal {sig}; shutting down");
                let _ = events.send(daemon::Event::Shutdown);
            }
            None => {
                log::flush(LOG_FLUSH_TIMEOUT);
                std::process::exit(128 + sig)
            }
        }
    })?;
    let args = parse_args()?;
    let data_dir = paths::data_dir()?;
    let config_path = match args.config {
        Some(p) => p,
        None => paths::config_file()?,
    };
    let config = Config::load(&config_path, &data_dir)?;
    log::set_level(config.log_level);
    let cpus = config::resolve_cpus(config.cpus.as_deref())?;
    if args.check {
        println!("configuration ok");
        return Ok(());
    }
    let runtime_dir = paths::runtime_dir()?;

    let (capture, output) = if args.fake_io {
        info!("fake I/O: recording silence and discarding text");
        backends::fake()
    } else {
        backends::desktop(&config)
    };
    let parts = Parts {
        capture,
        output,
        recognizer: recognizer::asr_factory(config.export_path.clone(), cpus, config.precision),
        settings: worker::Settings {
            options: config.dictation_options(),
            macros: config.voice_macros.clone(),
            type_chunk_chars: worker::chunk_chars_for_key_delay(config.key_delay_ms),
            prompt_tag: config.prompt_tag.clone(),
        },
        limits: Limits {
            min_recording: Duration::from_secs_f64(config.min_recording_seconds),
            max_recording: Duration::from_secs_f64(config.max_recording_seconds),
            double_tap: Duration::from_millis(config.double_tap_ms),
        },
        history: history::Setting {
            dir: data_dir,
            enabled: config.history,
        },
        // `--fake-io` leaves the desktop alone, media players included.
        media: (config.pause_media && !args.fake_io).then(backends::media),
    };
    // Signals go to the shutdown path before the first request is served, so
    // none can bypass it (and leave media paused) mid-recording.
    let handle = daemon::start_with(parts, &runtime_dir, |events| {
        *shutdown.lock().unwrap_or_else(|e| e.into_inner()) = Some(events);
    })?;
    let result = handle.join();
    info!("stopped");
    result
}
