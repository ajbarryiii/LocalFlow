//! `localflowctl fetch-model`: downloads a published model export from
//! Hugging Face and installs it where the daemon looks for it.
//!
//! The exports are pinned in `linux/models.json` (repository, revision and
//! every file's SHA-256), the same pins the flake's `kea-b` and `kea-t`
//! packages use. Files are downloaded with `curl` (HTTPS only, redirects
//! too) into a temporary directory beside the destination, checked against
//! the pins and the daemon's own export checks, and only then moved into
//! place with one rename, so the destination never holds a partial export.
//! The daemon itself never downloads anything.

use std::collections::BTreeMap;
use std::ffi::{CString, OsStr, OsString};
use std::fmt;
use std::fs;
use std::io::{ErrorKind, IsTerminal};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicI32, AtomicU64, Ordering};
use std::time::Duration;

use lf_model::manifest::sha256_file;

use crate::config::Config;
use crate::paths;

/// The pins, shared with `linux/flake.nix`.
const PINS_JSON: &str = include_str!("../../../models.json");

/// The model installed when none is named.
pub const DEFAULT_MODEL: &str = "kea-b";

/// Every download starts here; redirects may lead elsewhere, over HTTPS.
pub const HOST: &str = "https://huggingface.co";

/// The tensor file, downloaded last (it is by far the largest).
const TENSOR_FILE: &str = lf_model::manifest::TENSOR_FILE;

/// The Nix store, which is read-only.
const NIX_STORE: &str = "/nix/store";

/// One published export: where it lives and what every file hashes to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pins {
    pub name: String,
    /// `owner/name` on Hugging Face.
    pub repo: String,
    /// A full commit hash.
    pub rev: String,
    /// Relative path -> lowercase hex SHA-256.
    pub files: BTreeMap<String, String>,
}

impl Pins {
    /// The pinned exports, by name.
    pub fn published() -> Result<Vec<Pins>, String> {
        Pins::parse(PINS_JSON)
    }

    /// The pinned export called `name`, if there is one.
    pub fn find(name: &str) -> Result<Option<Pins>, String> {
        Ok(Pins::published()?.into_iter().find(|p| p.name == name))
    }

    /// Parses and checks a `models.json` document.
    pub fn parse(json: &str) -> Result<Vec<Pins>, String> {
        let value: serde_json::Value =
            serde_json::from_str(json).map_err(|e| format!("model pins: {e}"))?;
        let models = value.as_object().ok_or("model pins: not an object")?;
        let mut out = Vec::new();
        for (name, m) in models {
            let bad = |what: &str| format!("model pins: {name}: {what}");
            if !is_name(name) {
                return Err(bad("bad name"));
            }
            let repo = m.get("repo").and_then(|v| v.as_str()).unwrap_or("");
            if !repo
                .split_once('/')
                .is_some_and(|(owner, n)| is_name(owner) && is_name(n))
            {
                return Err(bad("bad repo"));
            }
            let rev = m.get("rev").and_then(|v| v.as_str()).unwrap_or("");
            if !is_hex(rev, 40) {
                return Err(bad("rev is not a full commit hash"));
            }
            let entries = m
                .get("files")
                .and_then(|v| v.as_object())
                .ok_or_else(|| bad("no files"))?;
            let mut files = BTreeMap::new();
            for (path, hash) in entries {
                if !is_file_path(path) {
                    return Err(bad(&format!("refusing path {path:?}")));
                }
                match hash.as_str() {
                    Some(h) if is_hex(h, 64) => files.insert(path.clone(), h.to_owned()),
                    _ => return Err(bad(&format!("bad hash for {path}"))),
                };
            }
            for required in ["manifest.json", TENSOR_FILE] {
                if !files.contains_key(required) {
                    return Err(bad(&format!("{required} is not pinned")));
                }
            }
            out.push(Pins {
                name: name.clone(),
                repo: repo.to_owned(),
                rev: rev.to_owned(),
                files,
            });
        }
        Ok(out)
    }

    /// The download URL of one pinned file (the flake fetches the same).
    pub fn url(&self, file: &str) -> String {
        format!("{HOST}/{}/resolve/{}/{file}", self.repo, self.rev)
    }

    /// The files in download order: the tensor file last, so a bad pin or
    /// a failed download is usually found before the big transfer.
    fn ordered(&self) -> impl Iterator<Item = (&String, &String)> {
        let (big, small): (Vec<_>, Vec<_>) =
            self.files.iter().partition(|(f, _)| *f == TENSOR_FILE);
        small.into_iter().chain(big)
    }
}

fn is_name(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('.')
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn is_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// A relative path of plain components, each a [`is_name`] (so it needs no
/// escaping in a URL and cannot leave the export directory).
fn is_file_path(path: &str) -> bool {
    !path.is_empty() && path.split('/').all(is_name)
}

/// The export directory the daemon would load: the configuration file's
/// `export_path`, else `<data_dir>/model`. The configuration is read the
/// way the daemon reads it, so an invalid one is an error here too.
pub fn default_dest(config_file: &Path, data_dir: &Path) -> Result<PathBuf, String> {
    Config::load(config_file, data_dir).map(|c| c.export_path)
}

/// [`default_dest`] at the daemon's XDG locations.
pub fn configured_dest() -> Result<PathBuf, String> {
    default_dest(&paths::config_file()?, &paths::data_dir()?)
}

/// Why an export was not installed. None of the messages carry anything
/// but file names from the pins and the destination path.
#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// The destination holds something other than this export.
    Exists(PathBuf),
    /// The destination cannot be written.
    ReadOnly {
        path: PathBuf,
        reason: String,
    },
    /// The destination's parent is writable by other users.
    Untrusted(PathBuf),
    /// The file system cannot swap the destination for the new export.
    NoExchange(PathBuf),
    /// `curl` is not installed.
    NoCurl,
    /// A download failed.
    Download(String),
    /// A downloaded file does not match its pin.
    Mismatch(String),
    /// The downloaded files do not pass the daemon's export checks.
    Invalid(String),
    /// A termination signal arrived (the signal number).
    Cancelled(i32),
    Io(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Exists(p) => write!(
                f,
                "{} already exists and is not this export; pass --force to replace it",
                p.display()
            ),
            Error::ReadOnly { path, reason } => write!(
                f,
                "cannot install into {}: {reason}; pass --dest DIR, or set export_path \
                 to a writable directory",
                path.display()
            ),
            Error::Untrusted(dir) => write!(
                f,
                "{} is writable by other users (the destination's parent must be \
                 owned by you or root, and not writable by others unless sticky); \
                 pass --dest DIR in a directory only you can write",
                dir.display()
            ),
            Error::NoExchange(p) => write!(
                f,
                "the file system of {} cannot replace it in one step; remove it and \
                 run fetch-model again",
                p.display()
            ),
            Error::NoCurl => f.write_str(
                "curl is not installed (fetch-model downloads with it); install curl, \
                 or download the export by hand (see the README)",
            ),
            Error::Download(m) => write!(f, "download failed: {m}; nothing was installed"),
            Error::Mismatch(file) => write!(
                f,
                "{file} does not match its pinned SHA-256; nothing was installed"
            ),
            Error::Invalid(m) => {
                write!(
                    f,
                    "the downloaded export does not load ({m}); nothing was installed"
                )
            }
            Error::Cancelled(sig) => {
                write!(f, "interrupted by signal {sig}; nothing was installed")
            }
            Error::Io(m) => f.write_str(m),
        }
    }
}

fn io(what: &str, path: &Path) -> impl Fn(std::io::Error) -> Error {
    move |e| Error::Io(format!("cannot {what} {}: {e}", path.display()))
}

/// Downloads one file. Implementations write `url`'s body to `out` (which
/// does not exist yet) and give up promptly once `cancel` is non-zero.
pub trait Fetcher {
    fn fetch(&mut self, file: &str, url: &str, out: &Path, cancel: &AtomicI32)
    -> Result<(), Error>;
}

/// How often a running download checks for cancellation.
const POLL: Duration = Duration::from_millis(50);

/// [`Fetcher`] that runs `curl` (no shell), HTTPS only.
pub struct Curl {
    program: OsString,
    /// Names each file on stderr, with curl's progress bar on a terminal.
    pub announce: bool,
}

impl Default for Curl {
    fn default() -> Curl {
        Curl::with_program("curl")
    }
}

impl Curl {
    /// `program` instead of `curl` from `PATH`.
    pub fn with_program(program: impl Into<OsString>) -> Curl {
        Curl {
            program: program.into(),
            announce: false,
        }
    }

    /// curl's arguments for one download: no `.curlrc` (`--disable` must
    /// come first), HTTPS and TLS 1.2 or later for the request and every
    /// redirect, HTTP errors fail, transient errors are retried, and a
    /// stalled transfer gives up.
    pub fn args(url: &str, out: &Path, progress: bool) -> Vec<OsString> {
        let mut args: Vec<OsString> = [
            "--disable",
            "--fail",
            "--location",
            "--max-redirs",
            "10",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--tlsv1.2",
            "--globoff",
            "--retry",
            "3",
            "--connect-timeout",
            "30",
            "--speed-limit",
            "1024",
            "--speed-time",
            "60",
            "--max-filesize",
            "1073741824",
        ]
        .map(OsString::from)
        .into();
        if progress {
            args.push("--progress-bar".into());
        } else {
            args.extend(["--silent", "--show-error"].map(OsString::from));
        }
        args.extend([
            "--output".into(),
            out.as_os_str().to_owned(),
            "--url".into(),
            url.into(),
        ]);
        args
    }
}

impl Fetcher for Curl {
    fn fetch(
        &mut self,
        file: &str,
        url: &str,
        out: &Path,
        cancel: &AtomicI32,
    ) -> Result<(), Error> {
        let progress = self.announce && std::io::stderr().is_terminal();
        if self.announce {
            eprintln!("localflowctl: downloading {file}");
        }
        let mut cmd = Command::new(&self.program);
        cmd.args(Curl::args(url, out, progress))
            .stdin(Stdio::null())
            .stdout(Stdio::null());
        // A program written a moment ago can be briefly busy (ETXTBSY: a
        // process forked meanwhile still holds it open for writing until it
        // execs), so that is retried a few times, as for the pickers.
        let mut tries = 0;
        let mut child = loop {
            match cmd.spawn() {
                Ok(c) => break c,
                Err(e) if e.kind() == ErrorKind::ExecutableFileBusy && tries < 5 => {
                    tries += 1;
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(e) if e.kind() == ErrorKind::NotFound => return Err(Error::NoCurl),
                Err(e) => return Err(Error::Download(format!("cannot run curl: {e}"))),
            }
        };
        loop {
            let sig = cancel.load(Ordering::SeqCst);
            if sig != 0 {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Error::Cancelled(sig));
            }
            match child.try_wait() {
                Ok(Some(status)) if status.success() => return Ok(()),
                Ok(Some(status)) => {
                    return Err(Error::Download(format!("{file}: curl {status}")));
                }
                Ok(None) => std::thread::sleep(POLL),
                Err(e) => return Err(Error::Download(format!("{file}: {e}"))),
            }
        }
    }
}

/// What [`install`] did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The destination did not exist; it holds the export now.
    Installed,
    /// The destination already held exactly this export; nothing changed.
    Present,
    /// The destination held something else and was replaced (`force`).
    Replaced,
}

/// True if `dir` holds every pinned file as a regular file inside it (after
/// resolving symlinks, as the daemon does) with the pinned hash. Other
/// files in `dir` are allowed.
fn holds(pins: &Pins, dir: &Path) -> bool {
    let Ok(root) = dir.canonicalize() else {
        return false;
    };
    pins.ordered().all(|(file, hash)| {
        root.join(file).canonicalize().is_ok_and(|p| {
            p.starts_with(&root)
                && fs::metadata(&p).is_ok_and(|m| m.is_file())
                && sha256_file(&p).is_ok_and(|h| h == *hash)
        })
    })
}

/// Fails if `path` is in the Nix store.
fn outside_store(path: &Path) -> Result<(), Error> {
    if path.starts_with(NIX_STORE) {
        return Err(Error::ReadOnly {
            path: path.to_owned(),
            reason: "it is in the Nix store, which is read-only".into(),
        });
    }
    Ok(())
}

/// Fails unless `dir` (the destination's resolved parent) is a directory
/// owned by this user or root and not writable by group or others, or
/// sticky (like `/tmp`).
fn trusted_parent(dir: &Path) -> Result<(), Error> {
    let m = fs::metadata(dir).map_err(io("inspect", dir))?;
    let owned = m.uid() == paths::euid() || m.uid() == 0;
    let others_write = m.mode() & 0o022 != 0 && m.mode() & libc::S_ISVTX == 0;
    if !owned || others_write || !m.is_dir() {
        return Err(Error::Untrusted(dir.to_owned()));
    }
    Ok(())
}

/// A [`Error::ReadOnly`] for errors that mean "cannot write here".
fn write_error(what: &str, path: &Path, e: std::io::Error) -> Error {
    match e.raw_os_error() {
        Some(libc::EROFS | libc::EACCES | libc::EPERM) => Error::ReadOnly {
            path: path.to_owned(),
            reason: e.to_string(),
        },
        _ => Error::Io(format!("cannot {what} {}: {e}", path.display())),
    }
}

/// Removes whatever `path` names (a directory tree, a file or a symlink;
/// symlinks are not followed).
fn remove_entry(path: &Path) -> std::io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(m) if m.is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

/// A temporary directory beside the destination, removed (with whatever is
/// in it) when dropped.
struct Staging(PathBuf);

impl Drop for Staging {
    fn drop(&mut self) {
        let _ = remove_entry(&self.0);
    }
}

impl Staging {
    fn new(parent: &Path, dest_name: &OsStr) -> Result<Staging, Error> {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let mut name = OsString::from(".");
        name.push(dest_name);
        name.push(format!(
            ".fetch-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let path = parent.join(name);
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .map_err(|e| write_error("create a directory in", parent, e))?;
        Ok(Staging(path))
    }
}

/// `rename(2)` with `renameat2` flags.
fn rename_with(from: &Path, to: &Path, flags: libc::c_uint) -> std::io::Result<()> {
    let c = |p: &Path| {
        CString::new(p.as_os_str().as_bytes())
            .map_err(|_| std::io::Error::from(ErrorKind::InvalidInput))
    };
    let (from, to) = (c(from)?, c(to)?);
    // SAFETY: both paths are valid NUL-terminated strings.
    let rc = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            from.as_ptr(),
            libc::AT_FDCWD,
            to.as_ptr(),
            flags,
        )
    };
    if rc == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

/// True for errors meaning the file system (or kernel) lacks a rename flag.
fn unsupported(e: &std::io::Error) -> bool {
    matches!(e.raw_os_error(), Some(libc::EINVAL | libc::ENOSYS))
}

/// Downloads `pins` into `dest` (an absolute path) with `fetcher`.
///
/// - `dest` already holding exactly this export: [`Outcome::Present`],
///   nothing downloaded.
/// - `dest` holding anything else: [`Error::Exists`] unless `force`; with
///   `force` it is replaced in one atomic exchange ([`Error::NoExchange`]
///   on file systems without one).
/// - The parent of `dest` must not be writable by other users
///   ([`Error::Untrusted`]).
/// - Missing parents of `dest` are created with mode 0700 (the daemon's
///   data directory must be private).
///
/// Every file is checked against its pin, and the whole export with the
/// daemon's loader, before anything moves into place; on any failure or
/// cancellation `dest` is left as it was and the temporary directory is
/// removed.
pub fn install(
    pins: &Pins,
    dest: &Path,
    force: bool,
    fetcher: &mut dyn Fetcher,
    cancel: &AtomicI32,
) -> Result<Outcome, Error> {
    if !dest.is_absolute() {
        return Err(Error::Io(format!(
            "{} is not an absolute path",
            dest.display()
        )));
    }
    let (Some(parent), Some(name)) = (dest.parent(), dest.file_name()) else {
        return Err(Error::Io(format!(
            "{} cannot hold an export",
            dest.display()
        )));
    };
    let existed = match fs::symlink_metadata(dest) {
        Ok(_) => true,
        Err(e) if e.kind() == ErrorKind::NotFound => false,
        Err(e) => return Err(io("inspect", dest)(e)),
    };
    if existed && holds(pins, dest) {
        return Ok(Outcome::Present);
    }
    outside_store(dest)?;
    if existed && !force {
        return Err(Error::Exists(dest.to_owned()));
    }
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)
        .map_err(|e| write_error("create", parent, e))?;
    let parent = parent.canonicalize().map_err(io("resolve", parent))?;
    outside_store(&parent)?;
    trusted_parent(&parent)?;
    let staging = Staging::new(&parent, name)?;
    if existed {
        // Found out before the download, not after.
        probe_exchange(&staging.0, dest)?;
    }
    let cancelled = || match cancel.load(Ordering::SeqCst) {
        0 => Ok(()),
        sig => Err(Error::Cancelled(sig)),
    };
    for (file, hash) in pins.ordered() {
        cancelled()?;
        let out = staging.0.join(file);
        let dir = out.parent().unwrap_or(&staging.0);
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o755)
            .create(dir)
            .map_err(io("create", dir))?;
        if let Err(e) = fetcher.fetch(file, &pins.url(file), &out, cancel) {
            // A Ctrl-C also kills curl, which may report that first.
            cancelled()?;
            return Err(e);
        }
        cancelled()?;
        // A regular file, not a link to one: the daemon refuses files that
        // resolve outside the export, and this one will be moved.
        if !fs::symlink_metadata(&out).is_ok_and(|m| m.is_file()) {
            return Err(Error::Mismatch(file.clone()));
        }
        if sha256_file(&out).map_err(|e| Error::Io(format!("{file}: {e}")))? != *hash {
            return Err(Error::Mismatch(file.clone()));
        }
        fs::set_permissions(&out, fs::Permissions::from_mode(0o644))
            .map_err(io("set the mode of", &out))?;
        sync(&out)?;
    }
    // The same checks the daemon makes when it loads the model.
    lf_model::Export::open(&staging.0).map_err(|e| Error::Invalid(e.to_string()))?;
    fs::set_permissions(&staging.0, fs::Permissions::from_mode(0o755))
        .map_err(io("set the mode of", &staging.0))?;
    for dir in pins.files.keys().filter_map(|f| Path::new(f).parent()) {
        sync(&staging.0.join(dir))?;
    }
    cancelled()?;
    let dest = parent.join(name);
    let outcome = if existed {
        replace(&staging.0, &dest)?;
        Outcome::Replaced
    } else {
        match rename_with(&staging.0, &dest, libc::RENAME_NOREPLACE) {
            Ok(()) => {}
            Err(e) if e.raw_os_error() == Some(libc::EEXIST) => return Err(Error::Exists(dest)),
            Err(e) if unsupported(&e) => {
                if fs::symlink_metadata(&dest).is_ok() {
                    return Err(Error::Exists(dest));
                }
                fs::rename(&staging.0, &dest).map_err(|e| write_error("rename into", &dest, e))?;
            }
            Err(e) => return Err(write_error("rename into", &dest, e)),
        }
        Outcome::Installed
    };
    // Its path is the export (or nothing) now; nothing is left to remove.
    std::mem::forget(staging);
    // The rename itself, so the export is there after a crash (best effort:
    // the export is in place either way).
    let _ = sync(&parent);
    Ok(outcome)
}

/// Swaps the staged export with `dest` in one step and removes the old
/// entry. A file system without `RENAME_EXCHANGE` is refused: replacing in
/// two renames would leave no export between them.
fn replace(staged: &Path, dest: &Path) -> Result<(), Error> {
    match rename_with(staged, dest, libc::RENAME_EXCHANGE) {
        Ok(()) => {}
        Err(e) if unsupported(&e) => return Err(Error::NoExchange(dest.to_owned())),
        Err(e) => return Err(write_error("replace", dest, e)),
    }
    // `staged` names the old entry now. The export is in place, so a
    // leftover old entry is not a failure.
    let _ = remove_entry(staged);
    Ok(())
}

/// Fails with [`Error::NoExchange`] for `dest` unless the file system of
/// `staging` (and so of `dest`) supports `RENAME_EXCHANGE`, found by
/// swapping two empty directories in `staging`.
fn probe_exchange(staging: &Path, dest: &Path) -> Result<(), Error> {
    let (a, b) = (staging.join("a"), staging.join("b"));
    for d in [&a, &b] {
        fs::create_dir(d).map_err(io("create", d))?;
    }
    let swapped = rename_with(&a, &b, libc::RENAME_EXCHANGE);
    for d in [&a, &b] {
        fs::remove_dir(d).map_err(io("remove", d))?;
    }
    match swapped {
        Ok(()) => Ok(()),
        Err(e) if unsupported(&e) => Err(Error::NoExchange(dest.to_owned())),
        Err(e) => Err(write_error("replace", dest, e)),
    }
}

/// Flushes `path` (a file or directory) to disk.
fn sync(path: &Path) -> Result<(), Error> {
    fs::File::open(path)
        .and_then(|f| f.sync_all())
        .map_err(io("flush", path))
}

/// Set to the signal number by [`cancel_on_signals`]'s handler.
static CANCEL: AtomicI32 = AtomicI32::new(0);

extern "C" fn on_signal(sig: libc::c_int) {
    CANCEL.store(sig, Ordering::SeqCst);
}

/// Makes SIGINT, SIGTERM and SIGHUP set the returned flag instead of
/// killing the process, so [`install`] can clean up. Child processes get
/// the default handlers back when they start (curl dies on Ctrl-C as
/// usual).
pub fn cancel_on_signals() -> Result<&'static AtomicI32, String> {
    for sig in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
        // SAFETY: a zeroed sigaction is valid; the handler only stores to
        // an atomic, which is async-signal-safe.
        let rc = unsafe {
            let mut sa: libc::sigaction = std::mem::zeroed();
            sa.sa_sigaction = on_signal as extern "C" fn(libc::c_int) as libc::sighandler_t;
            sa.sa_flags = libc::SA_RESTART;
            libc::sigemptyset(&mut sa.sa_mask);
            libc::sigaction(sig, &sa, std::ptr::null_mut())
        };
        if rc != 0 {
            return Err(format!("sigaction: {}", std::io::Error::last_os_error()));
        }
    }
    Ok(&CANCEL)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::MetadataExt;
    use std::sync::atomic::AtomicI32;

    use crate::testing::TempDir;

    // ---- Pins ----

    #[test]
    fn published_pins_are_kea_b_and_kea_t() {
        let pins = Pins::published().unwrap();
        let names: Vec<&str> = pins.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["kea-b", "kea-t"]);
        assert_eq!(DEFAULT_MODEL, "kea-b");
        for p in &pins {
            assert_eq!(p.repo, format!("rajb3/{}", p.name));
            for file in [
                "export.safetensors",
                "manifest.json",
                "tokenizer/tokenizer.model",
                "tokenizer/tokenizer.vocab",
                "tokenizer/vocab.txt",
                "LICENSE",
                "NOTICE",
            ] {
                assert!(p.files.contains_key(file), "{}: {file}", p.name);
            }
        }
        let b = Pins::find("kea-b").unwrap().unwrap();
        assert_eq!(
            b.url("tokenizer/vocab.txt"),
            format!(
                "https://huggingface.co/rajb3/kea-b/resolve/{}/tokenizer/vocab.txt",
                b.rev
            )
        );
        assert!(Pins::find("kea-z").unwrap().is_none());
    }

    #[test]
    fn bad_pins_are_refused() {
        let h = "a".repeat(64);
        let rev = "b".repeat(40);
        let doc = |repo: &str, rev: &str, path: &str, hash: &str| {
            format!(
                r#"{{"m": {{"repo": "{repo}", "rev": "{rev}", "files": {{
                    "manifest.json": "{h}", "export.safetensors": "{h}", "{path}": "{hash}"}}}}}}"#
            )
        };
        assert!(Pins::parse(&doc("o/m", &rev, "tokenizer/vocab.txt", &h)).is_ok());
        for bad in [
            doc("o/m", &rev, "../x", &h),
            doc("o/m", &rev, "/etc/x", &h),
            doc("o/m", &rev, "a//b", &h),
            doc("o/m", &rev, "a b", &h),
            doc("o/m", &rev, "x", &h.to_uppercase()),
            doc("o/m", &rev, "x", "abc"),
            doc("o/m", "main", "x", &h),
            doc("o", &rev, "x", &h),
            doc("o/m/x", &rev, "x", &h),
            doc("../m", &rev, "x", &h),
            format!(
                r#"{{"m": {{"repo": "o/m", "rev": "{rev}", "files": {{"manifest.json": "{h}"}}}}}}"#
            ),
            "[]".into(),
        ] {
            assert!(Pins::parse(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn destination_is_the_configured_export_path() {
        let t = TempDir::new("fetch-dest");
        let data = t.path().join("data/localflow");
        let config = t.path().join("config.json");
        assert_eq!(default_dest(&config, &data).unwrap(), data.join("model"));
        fs::write(&config, r#"{"export_path": "/models/kea-t"}"#).unwrap();
        assert_eq!(
            default_dest(&config, &data).unwrap(),
            Path::new("/models/kea-t")
        );
        fs::write(&config, r#"{"export_path": "relative"}"#).unwrap();
        assert!(default_dest(&config, &data).is_err());
    }

    // ---- install ----

    /// A synthetic export that passes the daemon's loader: a one-tensor
    /// binary-format file, a manifest pinning every file, a tokenizer and
    /// license files. `tag` makes the contents distinct.
    fn synthetic(tag: &str) -> (Pins, BTreeMap<String, Vec<u8>>) {
        let header = format!(
            r#"{{"__metadata__":{{"format":"{}"}},"m.scale":{{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}}}"#,
            lf_model::BINARY_FORMAT
        );
        let mut tensors = (header.len() as u64).to_le_bytes().to_vec();
        tensors.extend_from_slice(header.as_bytes());
        tensors.extend_from_slice(&1.0f32.to_le_bytes());
        let mut files: BTreeMap<String, Vec<u8>> = BTreeMap::new();
        files.insert(TENSOR_FILE.into(), tensors);
        files.insert(
            "tokenizer/vocab.txt".into(),
            format!("a\nb\n{tag}\n").into_bytes(),
        );
        files.insert("LICENSE".into(), b"synthetic license\n".to_vec());
        files.insert(
            "NOTICE".into(),
            format!("synthetic notice {tag}\n").into_bytes(),
        );
        let listed: serde_json::Map<String, serde_json::Value> = files
            .iter()
            .map(|(k, v)| (k.clone(), lf_model::manifest::sha256_hex(v).into()))
            .collect();
        let manifest = serde_json::json!({"format": lf_model::BINARY_FORMAT, "files": listed});
        files.insert("manifest.json".into(), manifest.to_string().into_bytes());
        let pins = Pins {
            name: "test".into(),
            repo: "synthetic/test".into(),
            rev: "c".repeat(40),
            files: files
                .iter()
                .map(|(k, v)| (k.clone(), lf_model::manifest::sha256_hex(v)))
                .collect(),
        };
        (pins, files)
    }

    /// Serves files by URL from memory and records what was asked.
    struct Fake {
        /// URL -> body.
        served: BTreeMap<String, Vec<u8>>,
        urls: Vec<String>,
        /// Fails the download with this index (0-based).
        fail_at: Option<usize>,
        /// Sets the cancel flag during the download with this index.
        cancel_at: Option<usize>,
        /// Writes a symlink to this path instead of the file with this name.
        link: Option<(String, PathBuf)>,
    }

    impl Fake {
        fn new(pins: &Pins, files: &BTreeMap<String, Vec<u8>>) -> Fake {
            Fake {
                served: files
                    .iter()
                    .map(|(k, v)| (pins.url(k), v.clone()))
                    .collect(),
                urls: Vec::new(),
                fail_at: None,
                cancel_at: None,
                link: None,
            }
        }
    }

    impl Fetcher for Fake {
        fn fetch(
            &mut self,
            file: &str,
            url: &str,
            out: &Path,
            cancel: &AtomicI32,
        ) -> Result<(), Error> {
            let i = self.urls.len();
            self.urls.push(url.into());
            assert!(!out.exists(), "{out:?} exists before its download");
            if let Some((name, target)) = &self.link
                && name == file
            {
                std::os::unix::fs::symlink(target, out).unwrap();
                return Ok(());
            }
            let body = self.served.get(url).cloned().unwrap_or_default();
            if self.cancel_at == Some(i) {
                // Half a file, then the signal.
                fs::write(out, &body[..body.len() / 2]).unwrap();
                cancel.store(libc::SIGINT, Ordering::SeqCst);
                return Err(Error::Cancelled(libc::SIGINT));
            }
            if self.fail_at == Some(i) {
                fs::write(out, &body[..body.len() / 2]).unwrap();
                return Err(Error::Download(format!("{file}: synthetic failure")));
            }
            fs::write(out, body).unwrap();
            Ok(())
        }
    }

    /// The names in `dir`, sorted.
    fn entries(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        v.sort();
        v
    }

    fn assert_holds(dest: &Path, files: &BTreeMap<String, Vec<u8>>) {
        for (name, body) in files {
            let p = dest.join(name);
            let m = fs::symlink_metadata(&p).unwrap();
            assert!(m.is_file(), "{name} is not a regular file");
            assert_eq!(&fs::read(&p).unwrap(), body, "{name}");
        }
        // Loads the way the daemon loads it.
        crate::recognizer::check_export(dest).unwrap();
        let export = lf_model::Export::open(dest).unwrap();
        assert_eq!(export.format, lf_model::WeightFormat::Binary);
    }

    #[test]
    fn installs_into_a_new_destination() {
        let t = TempDir::new("fetch-new");
        let (pins, files) = synthetic("one");
        // Parents that do not exist yet, like a first run's data directory.
        let parent = t.path().join("data/localflow");
        let dest = parent.join("model");
        let mut fake = Fake::new(&pins, &files);
        let cancel = AtomicI32::new(0);
        assert_eq!(
            install(&pins, &dest, false, &mut fake, &cancel),
            Ok(Outcome::Installed)
        );
        assert_holds(&dest, &files);
        // Every pinned file, once each, from the pinned URLs, the tensor
        // file last.
        let mut want: Vec<String> = pins.files.keys().map(|f| pins.url(f)).collect();
        want.sort();
        let mut got = fake.urls.clone();
        assert_eq!(got.last().unwrap(), &pins.url(TENSOR_FILE));
        got.sort();
        assert_eq!(got, want);
        assert!(
            got.iter()
                .all(|u| u.starts_with("https://huggingface.co/synthetic/test/resolve/"))
        );
        // Nothing else beside it, and the data directory is private.
        assert_eq!(entries(&parent), ["model"]);
        assert_eq!(fs::metadata(&parent).unwrap().mode() & 0o777, 0o700);
        assert_eq!(fs::metadata(&dest).unwrap().mode() & 0o777, 0o755);
        assert_eq!(
            fs::metadata(dest.join(TENSOR_FILE)).unwrap().mode() & 0o777,
            0o644
        );
    }

    #[test]
    fn a_hash_mismatch_installs_nothing() {
        let t = TempDir::new("fetch-mismatch");
        let (pins, files) = synthetic("one");
        let dest = t.path().join("model");
        let mut fake = Fake::new(&pins, &files);
        fake.served
            .insert(pins.url("NOTICE"), b"tampered notice\n".to_vec());
        let cancel = AtomicI32::new(0);
        assert_eq!(
            install(&pins, &dest, false, &mut fake, &cancel),
            Err(Error::Mismatch("NOTICE".into()))
        );
        assert!(!dest.exists());
        assert!(entries(t.path()).is_empty());
    }

    #[test]
    fn a_failed_download_installs_nothing() {
        let t = TempDir::new("fetch-fail");
        let (pins, files) = synthetic("one");
        let dest = t.path().join("model");
        for at in 0..pins.files.len() {
            let mut fake = Fake::new(&pins, &files);
            fake.fail_at = Some(at);
            let cancel = AtomicI32::new(0);
            let r = install(&pins, &dest, false, &mut fake, &cancel);
            assert!(matches!(r, Err(Error::Download(_))), "{at}: {r:?}");
            assert_eq!(fake.urls.len(), at + 1, "stopped at the failure");
            assert!(!dest.exists());
            assert!(entries(t.path()).is_empty(), "{at}");
        }
    }

    #[test]
    fn cancelling_installs_nothing() {
        let t = TempDir::new("fetch-cancel");
        let (pins, files) = synthetic("one");
        let dest = t.path().join("model");
        let mut fake = Fake::new(&pins, &files);
        fake.cancel_at = Some(2);
        let cancel = AtomicI32::new(0);
        assert_eq!(
            install(&pins, &dest, false, &mut fake, &cancel),
            Err(Error::Cancelled(libc::SIGINT))
        );
        assert!(!dest.exists());
        assert!(entries(t.path()).is_empty());
        // A flag already set downloads nothing.
        let mut fake = Fake::new(&pins, &files);
        assert_eq!(
            install(&pins, &dest, false, &mut fake, &cancel),
            Err(Error::Cancelled(libc::SIGINT))
        );
        assert!(fake.urls.is_empty());
        assert!(entries(t.path()).is_empty());
    }

    #[test]
    fn a_symlinked_download_is_refused() {
        let t = TempDir::new("fetch-link");
        let (pins, files) = synthetic("one");
        // The link points at a file with the right contents, outside.
        let outside = t.path().join("outside");
        fs::write(&outside, &files["NOTICE"]).unwrap();
        let dest = t.path().join("model");
        let mut fake = Fake::new(&pins, &files);
        fake.link = Some(("NOTICE".into(), outside));
        let cancel = AtomicI32::new(0);
        assert_eq!(
            install(&pins, &dest, false, &mut fake, &cancel),
            Err(Error::Mismatch("NOTICE".into()))
        );
        assert!(!dest.exists());
        assert_eq!(entries(t.path()), ["outside"]);
    }

    #[test]
    fn pins_that_do_not_load_install_nothing() {
        let t = TempDir::new("fetch-invalid");
        let (mut pins, mut files) = synthetic("one");
        // Pinned, but the manifest's hash for it is stale.
        files.insert("LICENSE".into(), b"another license\n".to_vec());
        pins.files.insert(
            "LICENSE".into(),
            lf_model::manifest::sha256_hex(&files["LICENSE"]),
        );
        let dest = t.path().join("model");
        let mut fake = Fake::new(&pins, &files);
        let cancel = AtomicI32::new(0);
        let r = install(&pins, &dest, false, &mut fake, &cancel);
        assert!(matches!(r, Err(Error::Invalid(_))), "{r:?}");
        assert!(!dest.exists());
        assert!(entries(t.path()).is_empty());
    }

    /// Installs `files` into `dest` directly, as a previous run would have.
    fn place(dest: &Path, files: &BTreeMap<String, Vec<u8>>) {
        for (name, body) in files {
            let p = dest.join(name);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(p, body).unwrap();
        }
    }

    #[test]
    fn a_matching_destination_is_left_alone() {
        let t = TempDir::new("fetch-present");
        let (pins, files) = synthetic("one");
        let dest = t.path().join("model");
        place(&dest, &files);
        // Extra files (a git clone's) do not matter.
        fs::write(dest.join("README.md"), b"readme").unwrap();
        let before = fs::metadata(dest.join(TENSOR_FILE)).unwrap();
        for force in [false, true] {
            let mut fake = Fake::new(&pins, &files);
            let cancel = AtomicI32::new(0);
            assert_eq!(
                install(&pins, &dest, force, &mut fake, &cancel),
                Ok(Outcome::Present)
            );
            assert!(fake.urls.is_empty());
        }
        let after = fs::metadata(dest.join(TENSOR_FILE)).unwrap();
        assert_eq!((before.ino(), before.mtime()), (after.ino(), after.mtime()));
        assert_eq!(entries(t.path()), ["model"]);

        // Through a symlink, as `export_path` may be.
        let link = t.path().join("link");
        std::os::unix::fs::symlink(&dest, &link).unwrap();
        let mut fake = Fake::new(&pins, &files);
        let cancel = AtomicI32::new(0);
        assert_eq!(
            install(&pins, &link, false, &mut fake, &cancel),
            Ok(Outcome::Present)
        );
    }

    #[test]
    fn a_file_linked_from_outside_does_not_match() {
        let t = TempDir::new("fetch-outside");
        let (pins, files) = synthetic("one");
        let dest = t.path().join("model");
        place(&dest, &files);
        let outside = t.path().join("NOTICE");
        fs::rename(dest.join("NOTICE"), &outside).unwrap();
        std::os::unix::fs::symlink(&outside, dest.join("NOTICE")).unwrap();
        let mut fake = Fake::new(&pins, &files);
        let cancel = AtomicI32::new(0);
        assert_eq!(
            install(&pins, &dest, false, &mut fake, &cancel),
            Err(Error::Exists(dest.clone()))
        );
    }

    #[test]
    fn a_different_destination_needs_force() {
        let t = TempDir::new("fetch-differs");
        let (old_pins, old_files) = synthetic("old");
        let (pins, files) = synthetic("new");
        assert_ne!(old_pins.files, pins.files);
        let dest = t.path().join("model");
        place(&dest, &old_files);
        fs::write(dest.join("marker"), b"old").unwrap();

        let mut fake = Fake::new(&pins, &files);
        let cancel = AtomicI32::new(0);
        assert_eq!(
            install(&pins, &dest, false, &mut fake, &cancel),
            Err(Error::Exists(dest.clone()))
        );
        assert!(fake.urls.is_empty());
        assert_holds(&dest, &old_files);
        assert_eq!(entries(t.path()), ["model"]);

        // With force, a failed download still leaves the old export.
        let mut fake = Fake::new(&pins, &files);
        fake.fail_at = Some(3);
        let r = install(&pins, &dest, true, &mut fake, &cancel);
        assert!(matches!(r, Err(Error::Download(_))), "{r:?}");
        assert_holds(&dest, &old_files);
        assert_eq!(entries(t.path()), ["model"]);

        // With force, it is replaced, and nothing of the old one is left.
        let mut fake = Fake::new(&pins, &files);
        assert_eq!(
            install(&pins, &dest, true, &mut fake, &cancel),
            Ok(Outcome::Replaced)
        );
        assert_holds(&dest, &files);
        assert!(!dest.join("marker").exists());
        assert_eq!(entries(t.path()), ["model"]);
    }

    #[test]
    fn force_replaces_a_file_or_a_symlink_itself() {
        let t = TempDir::new("fetch-entry");
        let (pins, files) = synthetic("one");
        let cancel = AtomicI32::new(0);

        let file = t.path().join("file");
        fs::write(&file, b"not an export").unwrap();
        let mut fake = Fake::new(&pins, &files);
        assert_eq!(
            install(&pins, &file, false, &mut fake, &cancel),
            Err(Error::Exists(file.clone()))
        );
        assert_eq!(
            install(&pins, &file, true, &mut fake, &cancel),
            Ok(Outcome::Replaced)
        );
        assert_holds(&file, &files);

        // The link is replaced; what it pointed at is not touched.
        let target = t.path().join("target");
        fs::create_dir(&target).unwrap();
        fs::write(target.join("keep"), b"keep").unwrap();
        let link = t.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let mut fake = Fake::new(&pins, &files);
        assert_eq!(
            install(&pins, &link, true, &mut fake, &cancel),
            Ok(Outcome::Replaced)
        );
        assert!(fs::symlink_metadata(&link).unwrap().is_dir());
        assert_holds(&link, &files);
        assert_eq!(entries(&target), ["keep"]);
        assert_eq!(entries(t.path()), ["file", "link", "target"]);
    }

    #[test]
    fn read_only_destinations_are_refused() {
        let (pins, files) = synthetic("one");
        let cancel = AtomicI32::new(0);
        let store = Path::new("/nix/store/00000000000000000000000000000000-localflow-model");
        let mut fake = Fake::new(&pins, &files);
        let r = install(&pins, store, false, &mut fake, &cancel);
        assert!(
            matches!(&r, Err(Error::ReadOnly { path, reason }) if path == store && reason.contains("Nix store")),
            "{r:?}"
        );
        assert!(r.unwrap_err().to_string().contains("--dest"));
        assert!(fake.urls.is_empty());

        if paths::euid() != 0 {
            let t = TempDir::new("fetch-ro");
            let ro = t.path().join("ro");
            fs::create_dir(&ro).unwrap();
            fs::set_permissions(&ro, fs::Permissions::from_mode(0o555)).unwrap();
            let r = install(&pins, &ro.join("model"), false, &mut fake, &cancel);
            fs::set_permissions(&ro, fs::Permissions::from_mode(0o755)).unwrap();
            assert!(matches!(r, Err(Error::ReadOnly { .. })), "{r:?}");
            assert!(fake.urls.is_empty());
            assert!(entries(&ro).is_empty());
        }

        let r = install(
            &pins,
            Path::new("relative/model"),
            false,
            &mut fake,
            &cancel,
        );
        assert!(matches!(r, Err(Error::Io(_))), "{r:?}");
    }

    #[test]
    fn a_parent_others_can_write_is_refused() {
        let t = TempDir::new("fetch-shared");
        let (pins, files) = synthetic("one");
        let cancel = AtomicI32::new(0);
        let shared = t.path().join("shared");
        fs::create_dir(&shared).unwrap();
        let dest = shared.join("model");
        // Writable by everyone, or by the group, and not sticky.
        for mode in [0o777, 0o770] {
            fs::set_permissions(&shared, fs::Permissions::from_mode(mode)).unwrap();
            let mut fake = Fake::new(&pins, &files);
            let r = install(&pins, &dest, false, &mut fake, &cancel);
            assert_eq!(r, Err(Error::Untrusted(shared.canonicalize().unwrap())));
            assert!(r.unwrap_err().to_string().contains("--dest"));
            assert!(fake.urls.is_empty());
            assert!(entries(&shared).is_empty(), "{mode:o}: nothing created");
        }
        // Sticky, like /tmp.
        fs::set_permissions(&shared, fs::Permissions::from_mode(0o1777)).unwrap();
        let mut fake = Fake::new(&pins, &files);
        assert_eq!(
            install(&pins, &dest, false, &mut fake, &cancel),
            Ok(Outcome::Installed)
        );
        assert_holds(&dest, &files);
        fs::set_permissions(&shared, fs::Permissions::from_mode(0o755)).unwrap();
    }

    // ---- curl ----

    #[test]
    fn curl_is_https_only_and_ignores_curlrc() {
        let out = Path::new("/tmp/x/NOTICE");
        let args = Curl::args("https://huggingface.co/a/b", out, false);
        let args: Vec<&str> = args.iter().map(|a| a.to_str().unwrap()).collect();
        assert_eq!(args[0], "--disable", "must come first to skip .curlrc");
        let pair = |flag: &str| {
            let i = args
                .iter()
                .position(|a| *a == flag)
                .unwrap_or_else(|| panic!("{flag}"));
            args[i + 1]
        };
        assert_eq!(pair("--proto"), "=https");
        assert_eq!(pair("--proto-redir"), "=https");
        assert_eq!(pair("--output"), "/tmp/x/NOTICE");
        assert_eq!(pair("--url"), "https://huggingface.co/a/b");
        for flag in [
            "--fail",
            "--location",
            "--tlsv1.2",
            "--silent",
            "--show-error",
        ] {
            assert!(args.contains(&flag), "{flag}");
        }
        for flag in ["--insecure", "-k", "--netrc"] {
            assert!(!args.contains(&flag), "{flag}");
        }
        let args = Curl::args("https://huggingface.co/a/b", out, true);
        assert!(args.contains(&"--progress-bar".into()));
        assert!(!args.contains(&"--silent".into()));
    }

    /// An executable script standing in for curl.
    fn fake_curl(dir: &Path, body: &str) -> PathBuf {
        let path = dir.join("curl");
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    /// Copies the `--url` argument into the `--output` file.
    const ECHO_URL: &str = r#"while [ $# -gt 0 ]; do
case "$1" in --output) out=$2; shift;; --url) url=$2; shift;; esac; shift
done
printf '%s' "$url" > "$out""#;

    #[test]
    fn curl_runs_without_a_shell_and_reports_failure() {
        let t = TempDir::new("fetch-curl");
        let cancel = AtomicI32::new(0);
        let out = t.path().join("out");
        // Arguments arrive intact, even ones a shell would split or expand.
        let url = "https://huggingface.co/a b/$HOME/*";
        let mut curl = Curl::with_program(fake_curl(t.path(), ECHO_URL));
        curl.fetch("f", url, &out, &cancel).unwrap();
        assert_eq!(fs::read_to_string(&out).unwrap(), url);

        let mut curl = Curl::with_program(fake_curl(t.path(), "exit 22"));
        let r = curl.fetch("NOTICE", url, &t.path().join("out2"), &cancel);
        assert!(
            matches!(&r, Err(Error::Download(m)) if m.contains("NOTICE") && m.contains("22")),
            "{r:?}"
        );

        let mut curl = Curl::with_program(t.path().join("missing/curl"));
        assert_eq!(
            curl.fetch("f", url, &t.path().join("out3"), &cancel),
            Err(Error::NoCurl)
        );
        assert!(Error::NoCurl.to_string().contains("install curl"));
    }

    #[test]
    fn cancelling_stops_curl() {
        let t = TempDir::new("fetch-curl-cancel");
        let mut curl = Curl::with_program(fake_curl(t.path(), "exec sleep 30"));
        let cancel = AtomicI32::new(0);
        let started = std::time::Instant::now();
        let r = std::thread::scope(|s| {
            s.spawn(|| {
                std::thread::sleep(Duration::from_millis(200));
                cancel.store(libc::SIGTERM, Ordering::SeqCst);
            });
            curl.fetch(
                "f",
                "https://huggingface.co/x",
                &t.path().join("out"),
                &cancel,
            )
        });
        assert_eq!(r, Err(Error::Cancelled(libc::SIGTERM)));
        assert!(started.elapsed() < Duration::from_secs(10));
    }
}
