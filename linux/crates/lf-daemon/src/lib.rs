//! The LocalFlow dictation daemon (`localflowd`) and its control client
//! (`localflowctl`).
//!
//! Hyprland binds call `localflowctl press` / `release` / `toggle` /
//! `cancel`; the daemon records from the microphone, transcribes on a
//! dedicated worker thread, post-processes with `lf-dictation`, and types
//! the result through the virtual keyboard. Audio never leaves memory.

pub mod log;

pub mod backends;
pub mod capture;
pub mod config;
pub mod controller;
pub mod daemon;
pub mod dictionary;
pub mod history;
pub mod link;
pub mod media;
pub mod paths;
pub mod picker;
pub mod protocol;
pub mod recognizer;
pub mod server;
pub mod session;
pub mod signals;
pub mod t3;
pub mod testing;
pub mod tray;
pub mod watch;
pub mod waybar;
pub mod worker;
