//! `localflowctl fetch-model` as a user runs it, without the network: the
//! destination comes from the XDG directories and the configuration file,
//! and `curl` is a script on `PATH` (or missing). Downloading and
//! installing a synthetic export are covered in `lf_daemon::fetch`.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

use lf_daemon::testing::TempDir;

/// A home with XDG directories below `t` and only `path` on `PATH`.
fn ctl(t: &TempDir, path: &str, args: &[&str]) -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_localflowctl"));
    cmd.args(args)
        .env_clear()
        .env("HOME", t.path())
        .env("XDG_CONFIG_HOME", t.path().join("config"))
        .env("XDG_DATA_HOME", t.path().join("data"))
        .env("PATH", path)
        .stdin(Stdio::null());
    cmd
}

fn run(t: &TempDir, path: &str, args: &[&str]) -> (Option<i32>, String, String) {
    let Output {
        status,
        stdout,
        stderr,
    } = ctl(t, path, args).output().unwrap();
    (
        status.code(),
        String::from_utf8(stdout).unwrap(),
        String::from_utf8(stderr).unwrap(),
    )
}

/// The default destination below `t`.
fn data_model(t: &TempDir) -> PathBuf {
    t.path().join("data/localflow/model")
}

fn write_config(t: &TempDir, json: &str) {
    fs::create_dir_all(t.path().join("config/localflow")).unwrap();
    fs::write(t.path().join("config/localflow/config.json"), json).unwrap();
}

/// A directory `name` holding only an executable `curl` script with `body`.
fn fake_curl(t: &TempDir, name: &str, body: &str) -> String {
    let bin = t.path().join(name);
    fs::create_dir_all(&bin).unwrap();
    let curl = bin.join("curl");
    fs::write(&curl, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(&curl, fs::Permissions::from_mode(0o755)).unwrap();
    // The real PATH after it, for `sleep`.
    format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    )
}

/// An empty directory, for a `PATH` without curl.
fn no_curl(t: &TempDir) -> String {
    let empty = t.path().join("empty");
    fs::create_dir_all(&empty).unwrap();
    empty.display().to_string()
}

/// A directory that is not an export, with one file.
fn other_dir(dir: &Path) {
    fs::create_dir_all(dir).unwrap();
    fs::write(dir.join("keep"), b"synthetic").unwrap();
}

/// The names in `dir`, sorted (none if it does not exist).
fn entries(dir: &Path) -> Vec<String> {
    let Ok(rd) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut v: Vec<String> = rd
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    v.sort();
    v
}

#[test]
fn usage_errors() {
    let t = TempDir::new("fetch-usage");
    let path = no_curl(&t);
    for args in [
        &["fetch-model", "kea-z"][..],
        &["fetch-model", "kea-b", "kea-t"],
        &["fetch-model", "--dest"],
        &["fetch-model", "--dest", ""],
        &["status", "--force"],
        &["status", "--dest", "/tmp/x"],
    ] {
        let (code, _, err) = run(&t, &path, args);
        assert_eq!(code, Some(2), "{args:?}: {err}");
        assert!(err.contains("usage: localflowctl"), "{args:?}");
    }
    let (_, _, err) = run(&t, &path, &["fetch-model", "kea-z"]);
    assert!(err.contains("choose kea-b or kea-t"), "{err}");
    let (code, out, _) = run(&t, &path, &["--help"]);
    assert_eq!(code, Some(0));
    assert!(out.contains("localflowctl fetch-model [kea-b|kea-t] [--dest DIR] [--force]"));
}

#[test]
fn an_existing_destination_is_refused_without_force() {
    let t = TempDir::new("fetch-exists");
    let path = no_curl(&t);
    // No configuration: $XDG_DATA_HOME/localflow/model.
    let dest = data_model(&t);
    other_dir(&dest);
    for model in [&[][..], &["kea-t"]] {
        let args: Vec<&str> = ["fetch-model"].iter().chain(model).copied().collect();
        let (code, out, err) = run(&t, &path, &args);
        assert_eq!(code, Some(10), "{err}");
        assert_eq!(out, "");
        assert!(err.contains(&dest.display().to_string()), "{err}");
        assert!(err.contains("--force"), "{err}");
    }
    assert_eq!(entries(&dest), ["keep"]);
    assert_eq!(entries(dest.parent().unwrap()), ["model"]);

    // The configuration's export_path instead.
    let custom = t.path().join("models/custom");
    other_dir(&custom);
    write_config(&t, &format!(r#"{{"export_path": "{}"}}"#, custom.display()));
    let (code, _, err) = run(&t, &path, &["fetch-model"]);
    assert_eq!(code, Some(10));
    assert!(err.contains(&custom.display().to_string()), "{err}");
    assert!(!err.contains(&dest.display().to_string()), "{err}");

    // An invalid configuration is reported, not guessed around.
    write_config(&t, r#"{"export_path": "relative"}"#);
    let (code, _, err) = run(&t, &path, &["fetch-model"]);
    assert_eq!(code, Some(10));
    assert!(err.contains("export_path"), "{err}");
    // ... unless the destination is given.
    let given = t.path().join("given");
    other_dir(&given);
    let (code, _, err) = run(
        &t,
        &path,
        &["fetch-model", "--dest", given.to_str().unwrap()],
    );
    assert_eq!(code, Some(10));
    assert!(err.contains(&given.display().to_string()), "{err}");
    assert!(err.contains("--force"), "{err}");
}

#[test]
fn a_nix_store_export_path_is_read_only() {
    let t = TempDir::new("fetch-store");
    let store = "/nix/store/00000000000000000000000000000000-localflow-model-kea-b";
    write_config(&t, &format!(r#"{{"export_path": "{store}"}}"#));
    let (code, _, err) = run(&t, &no_curl(&t), &["fetch-model", "--force"]);
    assert_eq!(code, Some(10), "{err}");
    assert!(err.contains(store), "{err}");
    assert!(err.contains("Nix store"), "{err}");
    assert!(err.contains("--dest"), "{err}");
}

#[test]
fn failures_install_nothing() {
    let t = TempDir::new("fetch-fail");
    let dest = data_model(&t);
    let parent = dest.parent().unwrap().to_owned();
    // Copies --url into --output: never the pinned bytes.
    let junk = r#"while [ $# -gt 0 ]; do
case "$1" in --output) out=$2; shift;; --url) url=$2; shift;; esac; shift
done
printf '%s' "$url" > "$out""#;
    for (path, want) in [
        (no_curl(&t), "curl is not installed"),
        (fake_curl(&t, "fails", "exit 22"), "download failed"),
        (
            fake_curl(&t, "junk", junk),
            "does not match its pinned SHA-256",
        ),
    ] {
        let (code, out, err) = run(&t, &path, &["fetch-model"]);
        assert_eq!(code, Some(10), "{want}: {err}");
        assert_eq!(out, "");
        assert!(err.contains(want), "{want}: {err}");
        assert!(
            err.contains("nothing was installed") || want.contains("curl"),
            "{err}"
        );
        assert!(!dest.exists(), "{want}");
        assert!(
            entries(&parent).is_empty(),
            "{want}: {:?}",
            entries(&parent)
        );
    }
}

#[test]
fn an_interrupt_cleans_up() {
    let t = TempDir::new("fetch-interrupt");
    let dest = data_model(&t);
    let parent = dest.parent().unwrap().to_owned();
    // curl that never finishes; only localflowctl gets the signal.
    let path = fake_curl(&t, "sleeps", "exec sleep 30");
    for sig in [libc::SIGINT, libc::SIGTERM] {
        let child = ctl(&t, &path, &["fetch-model"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let until = Instant::now() + Duration::from_secs(20);
        while !entries(&parent)
            .iter()
            .any(|e| e.starts_with(".model.fetch-"))
        {
            assert!(Instant::now() < until, "no download started");
            std::thread::sleep(Duration::from_millis(20));
        }
        // SAFETY: signals our own child.
        assert_eq!(unsafe { libc::kill(child.id() as i32, sig) }, 0);
        let started = Instant::now();
        let out = child.wait_with_output().unwrap();
        assert!(started.elapsed() < Duration::from_secs(10));
        assert_eq!(out.status.code(), Some(128 + sig));
        let err = String::from_utf8(out.stderr).unwrap();
        assert!(err.contains("interrupted"), "{err}");
        assert!(!dest.exists());
        assert!(entries(&parent).is_empty(), "{:?}", entries(&parent));
    }
}
