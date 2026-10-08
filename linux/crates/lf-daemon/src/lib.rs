//! The LocalFlow dictation daemon (`localflowd`) and its control client
//! (`localflowctl`).
//!
//! Hyprland binds call `localflowctl press` / `release` / `toggle` /
//! `cancel`; the daemon records from the microphone, transcribes on a
//! dedicated worker thread, post-processes with `lf-dictation`, and types
//! the result through the virtual keyboard. Audio never leaves memory.

pub mod log;

pub mod backends;
pub mod config;
pub mod controller;
pub mod daemon;
pub mod history;
pub mod media;
pub mod paths;
pub mod protocol;
pub mod recognizer;
pub mod server;
pub mod session;
pub mod signals;
pub mod testing;
pub mod watch;
pub mod waybar;
pub mod worker;
