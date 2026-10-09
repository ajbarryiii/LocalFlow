//! Manual test only: types a string into the focused window of the current
//! Wayland session through the virtual keyboard.
//!
//! ```text
//! lf-type-smoke [--wait SECONDS] [--delay-ms MS] [--enter] TEXT
//! ```
//!
//! Waits (default 3 s) so you can focus a target window, types TEXT, then
//! optionally presses Return. Prints only character counts and timing,
//! never the text.

use std::process::ExitCode;
use std::time::{Duration, Instant};

use lf_io_api::TextOutput;
use lf_wayland::{TyperConfig, WaylandTyper};

fn usage() -> ExitCode {
    eprintln!("usage: lf-type-smoke [--wait SECONDS] [--delay-ms MS] [--enter] TEXT");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let mut wait = 3.0f64;
    let mut config = TyperConfig::default();
    let mut enter = false;
    let mut text = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--wait" => match args.next().and_then(|v| v.parse::<f64>().ok()) {
                Some(v) if (0.0..=60.0).contains(&v) => wait = v,
                _ => return usage(),
            },
            "--delay-ms" => match args.next().and_then(|v| v.parse::<u64>().ok()) {
                Some(v) if v <= 1000 => config.key_delay = Duration::from_millis(v),
                _ => return usage(),
            },
            "--enter" => enter = true,
            "-h" | "--help" => return usage(),
            _ if text.is_none() => text = Some(arg),
            _ => return usage(),
        }
    }
    let Some(text) = text else {
        return usage();
    };

    let mut typer = WaylandTyper::new(config);
    if let Err(e) = typer.connect() {
        eprintln!("error: {e}");
        return ExitCode::FAILURE;
    }
    eprintln!("connected; typing in {wait} s, focus the target window now");
    std::thread::sleep(Duration::from_secs_f64(wait));

    let t0 = Instant::now();
    if let Err(e) = typer.type_text(&text) {
        eprintln!("error: {e}");
        return ExitCode::FAILURE;
    }
    if enter && let Err(e) = typer.press_enter() {
        eprintln!("error: {e}");
        return ExitCode::FAILURE;
    }
    println!(
        "typed {} characters{} in {:.1} ms",
        text.chars().count(),
        if enter { " and Return" } else { "" },
        t0.elapsed().as_secs_f64() * 1e3
    );
    ExitCode::SUCCESS
}
