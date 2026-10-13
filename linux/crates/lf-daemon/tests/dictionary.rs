//! The custom dictionary and correction suggestions end to end: the text
//! protocol over the socket, and `localflowctl correct` / `dict` with fake
//! rofi scripts. All text is synthetic.

mod common;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::time::{Duration, Instant};

use common::{Rig, data_dir, factory, runtime_dir, settings};
use lf_daemon::protocol::{decode_pct, encode_pct, reply_field};
use lf_daemon::testing::{FakeCapture, FakeRecognizer, TempDir};

const TYPED: &str = "we deployed it on cooper netties yesterday";
const EDITED: &str = "we deployed it on Kubernetes yesterday";
const RECOVERED: &str = "we deployed it on kubernetes yesterday";

fn start(tag: &str) -> (Rig, FakeRecognizer) {
    let rec = FakeRecognizer::returning(TYPED);
    rec.state().redecoded = vec![(1410, RECOVERED.into())];
    let rig = Rig::start(
        tag,
        FakeCapture::with_samples(vec![0.1; 16_000]),
        factory(rec.clone()),
        settings(),
        false,
    );
    (rig, rec)
}

fn dictate(rig: &Rig) {
    rig.cmd("toggle");
    rig.cmd("toggle");
    rig.wait_for("state=idle");
}

/// Sends a raw request line and returns the reply without its newline.
fn send(rig: &Rig, line: &str) -> String {
    let reply = rig.raw(format!("{line}\n").as_bytes());
    reply.strip_suffix('\n').unwrap_or(&reply).to_owned()
}

fn ok_fields(reply: &str) -> &str {
    reply
        .strip_prefix("localflow/1 ok ")
        .unwrap_or_else(|| panic!("{reply}"))
}

fn dictionary_file(rig: &Rig) -> PathBuf {
    data_dir(&rig.dir).join("dictionary.json")
}

#[test]
fn correction_over_the_socket() {
    let (rig, rec) = start("dict-socket");
    let mut watcher = rig.watch();
    assert_eq!(
        send(&rig, "localflow/1 correct-begin"),
        "localflow/1 error no-recent"
    );
    dictate(&rig);

    let begin = send(&rig, "localflow/1 correct-begin");
    let f = ok_fields(&begin);
    assert!(f.starts_with("state=idle model=ready id="), "{f}");
    let id = reply_field(f, "id").unwrap();
    assert_eq!(decode_pct(reply_field(f, "text").unwrap()).unwrap(), TYPED);

    let submit = send(
        &rig,
        &format!(
            "localflow/1 correct-submit id={id} text={}",
            encode_pct(EDITED)
        ),
    );
    let job = reply_field(ok_fields(&submit), "job").unwrap().to_owned();
    let until = Instant::now() + Duration::from_secs(10);
    let result = loop {
        let r = send(&rig, &format!("localflow/1 correct-result job={job}"));
        if !r.ends_with("result=pending") || Instant::now() > until {
            break r;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(
        result,
        "localflow/1 ok state=idle model=ready result=suggest word=Kubernetes strength=1.41 kind=replace"
    );
    // Strength 1.0 failed, 1.41 recovered the word.
    assert_eq!(rec.state().redecodes, 2);

    assert_eq!(
        send(&rig, "localflow/1 dict-add word=Kubernetes strength=1.41"),
        "localflow/1 ok state=idle model=ready"
    );
    // The dictionary changed: the session is gone.
    assert_eq!(
        send(&rig, &format!("localflow/1 correct-result job={job}")),
        "localflow/1 error stale"
    );
    assert_eq!(
        send(&rig, "localflow/1 correct-begin"),
        "localflow/1 error no-recent"
    );
    let file = dictionary_file(&rig);
    assert_eq!(
        std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert!(
        std::fs::read_to_string(&file)
            .unwrap()
            .contains("\"Kubernetes\"")
    );

    // The next dictation is boosted with it.
    dictate(&rig);
    assert_eq!(rec.state().dictionaries.last().unwrap().1, 1);
    assert_eq!(
        send(&rig, "localflow/1 dict-remove word=kubernetes"),
        "localflow/1 ok state=idle model=ready"
    );
    assert_eq!(
        send(&rig, "localflow/1 dict-remove word=kubernetes"),
        "localflow/1 error not-found"
    );
    assert_eq!(
        send(&rig, "localflow/1 dict-add word=1234"),
        "localflow/1 error invalid-entry"
    );

    // Watch lines never carry text.
    for line in watcher.until("state=idle") {
        assert!(
            !line.contains("text=") && !line.contains("ubernetes"),
            "{line}"
        );
    }
    for line in watcher.until("state=idle") {
        assert!(
            !line.contains("text=") && !line.contains("cooper"),
            "{line}"
        );
    }
}

#[test]
fn text_frames_have_their_own_limits() {
    let (rig, _) = start("dict-limits");
    // Other frames keep 256 bytes, and are cut off at once.
    let long = format!("localflow/1 status at={}\n", "1".repeat(300));
    assert_eq!(rig.raw(long.as_bytes()), "localflow/1 error too-long\n");
    // A text frame may be longer; its decoded text at most 4096 bytes.
    let fits = format!(
        "localflow/1 correct-submit id=1 text={}",
        "%41".repeat(4096)
    );
    assert!(fits.len() > 12 * 1024);
    assert_eq!(send(&rig, &fits), "localflow/1 error stale");
    let decoded = format!("localflow/1 correct-submit id=1 text={}", "a".repeat(4097));
    assert_eq!(send(&rig, &decoded), "localflow/1 error too-long");
    let frame = format!(
        "localflow/1 correct-submit id=1 text={}",
        "%41".repeat(6 * 1024)
    );
    assert_eq!(send(&rig, &frame), "localflow/1 error too-long");
    for bad in [
        "localflow/1 correct-submit id=1 text=a%0Ab",
        "localflow/1 correct-submit id=1 text=a text=b",
        "localflow/1 correct-submit text=a",
        "localflow/1 dict-add word=a extra=1",
        "localflow/1 correct-begin at=1",
    ] {
        assert_eq!(send(&rig, bad), "localflow/1 error bad-request", "{bad}");
    }
    assert_eq!(rig.cmd("status"), "state=idle model=ready");
}

/// A fake rofi in its own directory: records each call (arguments,
/// configuration from fd 3, stdin) under `log/`, then for the edit dialog
/// (`-format f`) runs `edit`, for the suggestion dialog (`-no-custom`)
/// runs `suggest`.
fn fake_rofi(dir: &Path, edit: &str, suggest: &str) -> PathBuf {
    let bin = dir.join("bin");
    let log = dir.join("log");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&log).unwrap();
    let l = log.display();
    let script = format!(
        "#!/bin/sh
case \" $* \" in
  *' -no-custom '*) which=suggest ;;
  *) which=edit ;;
esac
printf '%s\\n' \"$@\" > '{l}/'$which-args
cat /dev/fd/3 > '{l}/'$which-config
cat > '{l}/'$which-stdin
if [ $which = edit ]; then
{edit}
else
{suggest}
fi
"
    );
    let rofi = bin.join("rofi");
    std::fs::write(&rofi, script).unwrap();
    std::fs::set_permissions(&rofi, std::fs::Permissions::from_mode(0o700)).unwrap();
    bin
}

fn ctl(rig: &Rig, bin: &Path, args: &[&str]) -> Output {
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    std::process::Command::new(env!("CARGO_BIN_EXE_localflowctl"))
        .args(args)
        .env("XDG_RUNTIME_DIR", runtime_dir(&rig.dir))
        .env("XDG_DATA_HOME", rig.dir.path().join("data"))
        .env("PATH", path)
        .output()
        .unwrap()
}

fn text(out: &Output) -> (String, String) {
    (
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

fn assert_no_text(out: &Output) {
    let (o, e) = text(out);
    for word in ["cooper", "netties", "deployed", "ubernetes"] {
        assert!(!o.contains(word) && !e.contains(word), "{o:?} {e:?}");
    }
}

#[test]
fn localflowctl_correct_adds_a_confirmed_word() {
    let (rig, _) = start("dict-ctl");
    let t = TempDir::new("fake-rofi");
    let bin = fake_rofi(t.path(), &format!("echo '{EDITED}'"), "echo 0");
    dictate(&rig);
    let out = ctl(&rig, &bin, &["correct"]);
    assert_eq!(
        text(&out).0,
        "added to the dictionary\n",
        "{:?}",
        text(&out)
    );
    assert!(out.status.success());
    assert_no_text(&out);

    let log = t.path().join("log");
    let read = |n: &str| std::fs::read_to_string(log.join(n)).unwrap();
    // The transcript reached rofi through fd 3 only.
    let edit_args = read("edit-args");
    assert_eq!(
        edit_args.lines().collect::<Vec<_>>(),
        [
            "-dmenu",
            "-disable-history",
            "-no-plugins",
            "-format",
            "f",
            "-p",
            "Correct",
            "-config",
            "/dev/fd/3"
        ]
    );
    assert!(read("edit-config").contains(&format!("filter: \"{TYPED}\";")));
    assert_eq!(read("edit-stdin"), "");
    // The word reached it through stdin only.
    assert!(!read("suggest-args").contains("ubernetes"));
    assert!(read("suggest-stdin").contains("Add \u{201C}Kubernetes\u{201D}"));
    assert!(!read("suggest-config").contains("ubernetes"));

    let list = ctl(&rig, &bin, &["dict", "list"]);
    assert_eq!(text(&list).0, "Kubernetes\t1.41\n");
}

#[test]
fn localflowctl_correct_paths_that_change_nothing() {
    let (rig, _) = start("dict-ctl-none");
    let t = TempDir::new("fake-rofi-none");
    let none = TempDir::new("no-rofi");

    // No recent dictation.
    let bin = fake_rofi(t.path(), "exit 1", "exit 1");
    let out = ctl(&rig, &bin, &["correct"]);
    assert_eq!(out.status.code(), Some(1));
    assert!(text(&out).1.contains("no-recent"));

    dictate(&rig);
    // Dismissed (Escape), unchanged text, or rofi failing or missing.
    for (edit, want_out, code) in [
        ("exit 1", "correction cancelled\n", 0),
        (&format!("echo '{TYPED}'") as &str, "no change\n", 0),
        ("echo 'leaked words' >&2; exit 3", "", 7),
    ] {
        let bin = fake_rofi(t.path(), edit, "echo 0");
        let out = ctl(&rig, &bin, &["correct"]);
        assert_eq!(out.status.code(), Some(code), "{edit}: {:?}", text(&out));
        assert_eq!(text(&out).0, want_out);
        assert!(!text(&out).1.contains("leaked"));
        assert_no_text(&out);
    }
    let missing = std::process::Command::new(env!("CARGO_BIN_EXE_localflowctl"))
        .arg("correct")
        .env("XDG_RUNTIME_DIR", runtime_dir(&rig.dir))
        .env("PATH", none.path())
        .output()
        .unwrap();
    assert_eq!(missing.status.code(), Some(7));

    // A suggestion dismissed, then declined for good.
    let bin = fake_rofi(t.path(), &format!("echo '{EDITED}'"), "exit 1");
    let out = ctl(&rig, &bin, &["correct"]);
    assert_eq!(text(&out).0, "not added\n");
    let bin = fake_rofi(t.path(), &format!("echo '{EDITED}'"), "echo 2");
    let out = ctl(&rig, &bin, &["correct"]);
    assert_eq!(text(&out).0, "will not be suggested again\n");
    assert_no_text(&out);
    assert_eq!(
        text(&ctl(&rig, &bin, &["dict", "ignored"])).0,
        "kubernetes\n"
    );
    assert_eq!(text(&ctl(&rig, &bin, &["dict", "list"])).0, "");
    // Ignored now: nothing is suggested.
    dictate(&rig);
    let out = ctl(&rig, &bin, &["correct"]);
    assert_eq!(text(&out).0, "no suggestion\n");
}

/// A fake daemon whose `correct-result` replies never come: `correct`
/// still gives up within its 5 s polling deadline, whatever `--timeout-ms`.
#[test]
fn localflowctl_correct_polling_keeps_its_deadline() {
    use std::io::{BufRead, BufReader, Write};
    let t = TempDir::new("stalled-daemon");
    let run = t.path().join("run");
    common::private_dir(&run.join("localflow"));
    let listener = std::os::unix::net::UnixListener::bind(run.join("localflow/ctl.sock")).unwrap();
    std::thread::spawn(move || {
        let mut stalled = Vec::new();
        for conn in listener.incoming() {
            let Ok(mut s) = conn else { return };
            let mut line = String::new();
            let _ = BufReader::new(&s).read_line(&mut line);
            let reply = if line.contains("correct-begin") {
                format!(
                    "localflow/1 ok state=idle model=ready id=1 text={}\n",
                    encode_pct(TYPED)
                )
            } else if line.contains("correct-submit") {
                "localflow/1 ok state=idle model=ready job=2\n".into()
            } else {
                // correct-result: held open, never answered.
                stalled.push(s);
                continue;
            };
            let _ = s.write_all(reply.as_bytes());
        }
    });
    let rofi = fake_rofi(t.path(), &format!("echo '{EDITED}'"), "echo 0");
    let start = Instant::now();
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_localflowctl"))
        .args(["--timeout-ms", "30000", "correct"])
        .env("XDG_RUNTIME_DIR", &run)
        .env(
            "PATH",
            format!(
                "{}:{}",
                rofi.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .output()
        .unwrap();
    let took = start.elapsed();
    assert!(out.status.success(), "{:?}", text(&out));
    assert_eq!(text(&out).0, "no suggestion (the check took too long)\n");
    assert!(
        took >= Duration::from_millis(4500) && took < Duration::from_millis(6500),
        "{took:?}"
    );
}

#[test]
fn localflowctl_dict_subcommands() {
    let (rig, _) = start("dict-ctl-sub");
    let bin = PathBuf::from("/nonexistent");
    let ok = |args: &[&str], want: &str| {
        let out = ctl(&rig, &bin, args);
        assert!(out.status.success(), "{args:?}: {:?}", text(&out));
        assert_eq!(text(&out).0, want, "{args:?}");
    };
    ok(&["dict", "list"], "");
    ok(
        &["dict", "add", "New", "York", "--strength", "2"],
        "added\n",
    );
    ok(&["dict", "add", "--strength", "0.5", "NixOS"], "added\n");
    ok(&["dict", "add", "kubectl"], "added\n");
    ok(&["dict", "list"], "New York\t2\nNixOS\t0.5\nkubectl\t1\n");
    ok(&["dict", "remove", "new york"], "removed\n");
    ok(&["dict", "list"], "NixOS\t0.5\nkubectl\t1\n");

    let code = |args: &[&str]| ctl(&rig, &bin, args).status.code();
    assert_eq!(code(&["dict", "remove", "absent"]), Some(1));
    assert_eq!(code(&["dict", "unignore", "absent"]), Some(1));
    assert_eq!(code(&["dict", "add", "caf\u{e9}"]), Some(1));
    for usage in [
        &["dict"][..],
        &["dict", "add"],
        &["dict", "add", "x", "--strength", "9"],
        &["dict", "add", "x", "--strength", "1.4142"],
        &["dict", "list", "x"],
        &["dict", "frobnicate"],
        &["correct", "x"],
        &["correct-begin"],
        &["dict-add"],
        &["status", "--strength", "1"],
    ] {
        assert_eq!(code(usage), Some(2), "{usage:?}");
    }

    // An unsafe file is refused without quoting it.
    let file = dictionary_file(&rig);
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
    let out = ctl(&rig, &bin, &["dict", "list"]);
    assert_eq!(out.status.code(), Some(6));
    assert!(!text(&out).1.contains("NixOS"));
}

#[test]
fn a_bad_dictionary_file_stops_the_daemon_from_starting() {
    let dir = TempDir::new("dict-start");
    let data = dir.path().join("data");
    common::private_dir(&data);
    std::fs::write(data.join("dictionary.json"), "{\"version\":1,\"entries\":[{\"text\":\"SyntheticSecret\",\"strength\":99}],\"ignore\":[]}").unwrap();
    std::fs::set_permissions(
        data.join("dictionary.json"),
        std::fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let rd = dir.path().join("run");
    common::private_dir(&rd);
    let err = lf_daemon::daemon::start(
        lf_daemon::daemon::Parts {
            capture: Box::new(FakeCapture::default()),
            output: Box::new(lf_daemon::testing::FakeOutput::default()),
            recognizer: factory(FakeRecognizer::default()),
            settings: settings(),
            limits: lf_daemon::controller::Limits {
                min_recording: Duration::from_millis(300),
                max_recording: Duration::from_secs(60),
                double_tap: Duration::ZERO,
            },
            history: lf_daemon::history::Setting {
                dir: data.clone(),
                enabled: false,
            },
            dictionary: common::dictionary(data.clone()),
            media: None,
        },
        &rd,
    )
    .err()
    .expect("refused");
    assert!(
        err.contains("dictionary") && !err.contains("SyntheticSecret"),
        "{err}"
    );
    // The file is left as it was.
    assert!(
        std::fs::read_to_string(data.join("dictionary.json"))
            .unwrap()
            .contains("SyntheticSecret")
    );
}
