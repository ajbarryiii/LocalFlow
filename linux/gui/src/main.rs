//! `localflow-gui`: LocalFlow's windows on Linux, drawn with Rune.
//!
//! - `localflow-gui [settings]`: the settings window, one per user (a
//!   second launch brings it forward; see [`instance`]).
//! - `localflow-gui edit`: correct a dictation (text on stdin; the edit on
//!   stdout). See [`prompt`].
//! - `localflow-gui choose`: pick one of the rows on stdin (its number on
//!   stdout).
//!
//! Rune's own flags work on every window (`--snap out.png`, `--tree`),
//! which render it headless.

mod instance;
mod look;
mod prompt;
mod settings;

use std::io::{Read, Write};
use std::sync::{Mutex, OnceLock};

use prompt::Outcome;
use rune::AppSpec;

/// The app id the compositor sees (window rules match it).
const APP_ID: &str = "com.ajbarryiii.localflow.gui";
/// The most text `edit` and `choose` read (the daemon's text limit is far
/// below this).
const MAX_INPUT: u64 = 1 << 20;

/// What stdin held, for the window's `init` (an `fn`, so no captures).
static INPUT: OnceLock<String> = OnceLock::new();

fn main() {
    rune::set_app_id(APP_ID);
    let args = rune::extra_args();
    let code = match args.first().map(String::as_str) {
        None | Some("settings") => run_settings(),
        Some("edit") => run_edit(),
        Some("choose") => run_choose(),
        Some(other) => {
            eprintln!("localflow-gui: unknown command {other:?} (settings, edit, choose)");
            2
        }
    };
    std::process::exit(code);
}

fn read_stdin() -> Result<String, String> {
    let mut s = String::new();
    std::io::stdin()
        .take(MAX_INPUT)
        .read_to_string(&mut s)
        .map_err(|e| format!("stdin: {e}"))?;
    Ok(s)
}

/// Prints the outcome: 0 with the answer, 1 when dismissed.
fn finish() -> i32 {
    let outcome = prompt::ANSWER.lock().unwrap().take();
    let mut out = std::io::stdout().lock();
    let written = match outcome {
        Some(Outcome::Accepted(text)) => writeln!(out, "{text}"),
        Some(Outcome::Chose(i)) => writeln!(out, "{i}"),
        Some(Outcome::Dismissed) | None => return 1,
    };
    match written.and_then(|()| out.flush()) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

fn run_edit() -> i32 {
    match read_stdin() {
        Ok(text) => {
            let _ = INPUT.set(text);
        }
        Err(e) => {
            eprintln!("localflow-gui: {e}");
            return 2;
        }
    }
    fn init() -> prompt::Edit {
        prompt::Edit::new(INPUT.get().map_or("", String::as_str))
    }
    rune::run(AppSpec::<prompt::Edit> {
        min_size: Some(prompt::edit_min_size()),
        on_key: Some(prompt::edit_key),
        ..AppSpec::new(
            "Fix dictation",
            (
                560.0,
                prompt::edit_height(INPUT.get().map_or("", String::as_str)),
            ),
            init,
            prompt::edit_view,
        )
    });
    finish()
}

fn run_choose() -> i32 {
    match read_stdin() {
        Ok(text) => {
            let _ = INPUT.set(text);
        }
        Err(e) => {
            eprintln!("localflow-gui: {e}");
            return 2;
        }
    }
    fn init() -> prompt::Choose {
        prompt::Choose::new(prompt::parse_rows(INPUT.get().map_or("", String::as_str)))
    }
    if init().rows.is_empty() {
        eprintln!("localflow-gui: no rows on stdin");
        return 2;
    }
    let rows = INPUT.get().map_or(0, |s| prompt::parse_rows(s).len());
    rune::run(AppSpec::<prompt::Choose> {
        min_size: Some(prompt::choose_min_size(rows)),
        on_key: Some(prompt::choose_key),
        ..AppSpec::new(
            "LocalFlow",
            (420.0, prompt::choose_height(rows)),
            init,
            prompt::choose_view,
        )
    });
    finish()
}

/// The settings window's state, made before the window opens.
static SETTINGS: Mutex<Option<settings::Settings>> = Mutex::new(None);

fn run_settings() -> i32 {
    let Some(listener) = claim_settings() else {
        return 0;
    };
    let made = (|| -> Result<settings::Settings, String> {
        let config = lf_daemon::paths::config_file()?;
        let data = lf_daemon::paths::data_dir()?;
        let layers = lf_daemon::config::Layers::load(&config, &data)?;
        settings::Settings::new(config, data, layers, Some(settings::Daemon::SYSTEM))
    })();
    match made {
        Ok(s) => *SETTINGS.lock().unwrap() = Some(s),
        Err(e) => {
            eprintln!("localflow-gui: {e}");
            return 1;
        }
    }
    fn init() -> settings::Settings {
        SETTINGS
            .lock()
            .unwrap()
            .take()
            .expect("settings are made once, before the window")
    }
    let app = rune::App::new(AppSpec::<settings::Settings> {
        min_size: Some((520.0, 400.0)),
        on_key: Some(settings::key),
        ..AppSpec::new("LocalFlow Settings", (600.0, 880.0), init, settings::view)
    });
    if let Some(listener) = listener {
        let handle = app.handle();
        listener.serve(move |token| handle.activate(token));
    }
    app.run();
    0
}

/// Whether a settings window is already open: if so it is asked to come
/// forward and this process has nothing to do (`None`). Headless renders
/// skip this.
fn claim_settings() -> Option<Option<instance::Listener>> {
    if rune::is_headless() {
        return Some(None);
    }
    let token = std::env::var("XDG_ACTIVATION_TOKEN").unwrap_or_default();
    let claimed =
        lf_daemon::paths::runtime_dir().and_then(|d| instance::claim(&d.join("localflow"), &token));
    match claimed {
        Ok(instance::Instance::First(l)) => Some(Some(l)),
        Ok(instance::Instance::Forwarded) => None,
        Err(e) => {
            eprintln!("localflow-gui: {e}");
            Some(None)
        }
    }
}
