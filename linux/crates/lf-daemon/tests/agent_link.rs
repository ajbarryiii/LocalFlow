//! The agent link end to end (linux/AGENT-LINK.md): dictionary suggestions
//! reviewed with `localflowctl dict review` and a fake rofi, project words
//! loaded with `localflowctl words set` and boosted in dictation, and agent
//! reports on `watch`. All words are invented.

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};
use std::time::Duration;

use common::{Rig, data_dir, factory, runtime_dir, settings};
use lf_daemon::protocol::{decode_pct, reply_field};
use lf_daemon::testing::{FakeCapture, FakeRecognizer, TempDir};

const SPOKEN: &str = "a synthetic dictation";

fn start(tag: &str) -> (Rig, FakeRecognizer) {
    let rec = FakeRecognizer::returning(SPOKEN);
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

/// A fake rofi in `dir/bin`: call `n` records its arguments, configuration
/// and stdin as `dir/log/{args,config,stdin}-n`, then answers with line `n`
/// of `dir/answers` (`esc` closes it, as Escape does).
fn fake_rofi(dir: &Path, answers: &[&str]) -> PathBuf {
    let bin = dir.join("bin");
    let log = dir.join("log");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::create_dir_all(&log).unwrap();
    std::fs::write(dir.join("answers"), answers.join("\n") + "\n").unwrap();
    let _ = std::fs::remove_file(dir.join("count"));
    let (d, l) = (dir.display(), log.display());
    let script = format!(
        "#!/bin/sh
n=$(cat '{d}/count' 2>/dev/null || echo 0)
n=$((n + 1))
echo $n > '{d}/count'
printf '%s\\n' \"$@\" > '{l}/args-'$n
cat /dev/fd/3 > '{l}/config-'$n
cat > '{l}/stdin-'$n
answer=$(sed -n \"${{n}}p\" '{d}/answers')
if [ \"$answer\" = esc ]; then exit 1; fi
echo \"$answer\"
"
    );
    let rofi = bin.join("rofi");
    std::fs::write(&rofi, script).unwrap();
    std::fs::set_permissions(&rofi, std::fs::Permissions::from_mode(0o700)).unwrap();
    bin
}

fn rofi_calls(dir: &Path) -> usize {
    std::fs::read_to_string(dir.join("count")).map_or(0, |c| c.trim().parse().unwrap())
}

fn ctl_command(rig: &Rig, bin: &Path, args: &[&str]) -> std::process::Command {
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_localflowctl"));
    cmd.args(args)
        .env("XDG_RUNTIME_DIR", runtime_dir(&rig.dir))
        .env("XDG_DATA_HOME", rig.dir.path().join("data"))
        .env("PATH", path);
    cmd
}

fn ctl(rig: &Rig, bin: &Path, args: &[&str]) -> Output {
    ctl_command(rig, bin, args)
        .stdin(Stdio::null())
        .output()
        .unwrap()
}

/// Runs `localflowctl` with `input` on its stdin.
fn ctl_stdin(rig: &Rig, args: &[&str], input: &str) -> Output {
    let mut child = ctl_command(rig, Path::new("/nonexistent"), args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn text(out: &Output) -> (String, String) {
    (
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

const WORDS: [&str; 6] = [
    "Zorblax", "Quuxwell", "Glimmux", "Blorft", "Snarfle", "Thing",
];

fn assert_no_words(out: &Output) {
    let (o, e) = text(out);
    for w in WORDS {
        assert!(!o.contains(w) && !e.contains(w), "{o:?} {e:?}");
    }
}

fn dictionary_text(rig: &Rig) -> String {
    std::fs::read_to_string(data_dir(&rig.dir).join("dictionary.json")).unwrap_or_default()
}

#[test]
fn suggestions_are_reviewed_in_rofi_and_added() {
    let (rig, _) = start("link-review");
    let t = TempDir::new("link-rofi");
    let none = PathBuf::from("/nonexistent");
    let ok = |args: &[&str], want: &str| {
        let out = ctl(&rig, &none, args);
        assert!(out.status.success(), "{args:?}: {:?}", text(&out));
        assert_eq!(text(&out).0, want, "{args:?}");
        assert_no_words(&out);
    };
    ok(&["dict", "suggest", "Zorblax"], "queued for review\n");
    ok(&["dict", "suggest", "Quuxwell"], "queued for review\n");
    ok(&["dict", "suggest", "Glimmux"], "queued for review\n");
    ok(&["dict", "suggest", "Blorft"], "queued for review\n");
    // Already pending: queued, once.
    assert_eq!(
        send(&rig, "localflow/1 suggest-add word=zorblax"),
        "localflow/1 ok state=idle model=ready outcome=queued"
    );
    ok(&["dict", "add", "Snarfle"], "added\n");
    ok(
        &["dict", "suggest", "snarfle"],
        "already in the dictionary\n",
    );
    assert_eq!(
        ctl(&rig, &none, &["dict", "suggest", "1234"]).status.code(),
        Some(1)
    );
    assert_eq!(
        ctl(&rig, &none, &["dict", "suggest"]).status.code(),
        Some(2)
    );
    let mut watcher = rig.watch();
    assert!(watcher.line().ends_with(" suggestions=4"));

    // Add, don't suggest, not now, then Escape: the last stays pending.
    let bin = fake_rofi(t.path(), &["0", "2", "1", "esc"]);
    let out = ctl(&rig, &bin, &["dict", "review"]);
    assert!(out.status.success(), "{:?}", text(&out));
    assert_eq!(text(&out).0, "added 1, ignored 1, dismissed 1\n");
    assert_no_words(&out);
    assert_eq!(rofi_calls(t.path()), 4);
    let log = t.path().join("log");
    let read = |n: &str| std::fs::read_to_string(log.join(n)).unwrap();
    for (i, w) in ["Zorblax", "Quuxwell", "Glimmux", "Blorft"]
        .iter()
        .enumerate()
    {
        let n = i + 1;
        // The word reaches rofi through its stdin only.
        assert!(
            read(&format!("stdin-{n}")).starts_with(&format!("Add \u{201C}{w}\u{201D}")),
            "{n}"
        );
        assert!(!read(&format!("args-{n}")).contains(w));
        assert!(!read(&format!("config-{n}")).contains(w));
        assert!(read(&format!("args-{n}")).contains("-no-custom"));
    }
    let dictionary = dictionary_text(&rig);
    assert!(dictionary.contains("\"Zorblax\""), "{dictionary}");
    assert!(!dictionary.contains("Glimmux") && !dictionary.contains("Blorft"));
    assert_eq!(
        text(&ctl(&rig, &none, &["dict", "ignored"])).0,
        "quuxwell\n"
    );
    assert_eq!(
        text(&ctl(&rig, &none, &["dict", "list"])).0,
        "Snarfle\t1\nZorblax\t1\n"
    );
    let next = send(&rig, "localflow/1 suggest-next");
    let f = next.strip_prefix("localflow/1 ok ").unwrap();
    assert_eq!(
        decode_pct(reply_field(f, "word").unwrap()).unwrap(),
        "Blorft"
    );

    // Watch lines follow the queue and never carry a word.
    let lines = watcher.until("state=idle model=ready mic=unknown suggestions=1");
    for line in &lines {
        for w in WORDS {
            assert!(!line.contains(w), "{line}");
        }
    }

    let bin = fake_rofi(t.path(), &["0"]);
    let out = ctl(&rig, &bin, &["dict", "review"]);
    assert_eq!(text(&out).0, "added 1, ignored 0, dismissed 0\n");
    assert!(dictionary_text(&rig).contains("\"Blorft\""));
    // Nothing pending: rofi is not even started.
    let out = ctl(&rig, &bin, &["dict", "review"]);
    assert!(out.status.success());
    assert_eq!(text(&out).0, "added 0, ignored 0, dismissed 0\n");
    assert_eq!(rofi_calls(t.path()), 1);
    assert_eq!(
        send(&rig, "localflow/1 suggest-next"),
        "localflow/1 error not-found"
    );

    // rofi failing is exit 7, and the word stays pending.
    ok(&["dict", "suggest", "Thing"], "queued for review\n");
    let failing = TempDir::new("link-rofi-fail");
    let bin = failing.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(bin.join("rofi"), "#!/bin/sh\ncat > /dev/null\nexit 3\n").unwrap();
    std::fs::set_permissions(bin.join("rofi"), std::fs::Permissions::from_mode(0o700)).unwrap();
    let out = ctl(&rig, &bin, &["dict", "review"]);
    assert_eq!(out.status.code(), Some(7), "{:?}", text(&out));
    assert_no_words(&out);
    assert!(send(&rig, "localflow/1 suggest-next").contains("word=Thing"));
}

#[test]
fn project_words_from_arguments_and_stdin_boost_dictation() {
    let (rig, rec) = start("link-words");
    assert_eq!(
        send(&rig, "localflow/1 dict-add word=Snarfle strength=2"),
        "localflow/1 ok state=idle model=ready"
    );
    dictate(&rig);
    assert_eq!(rec.state().dictionaries.last().unwrap().1, 1);

    let none = Path::new("/nonexistent");
    let out = ctl(
        &rig,
        none,
        &["words", "set", "repo", "Zorblax", "New Thing"],
    );
    assert!(out.status.success(), "{:?}", text(&out));
    assert_eq!(text(&out).0, "loaded 2, skipped 0\n");
    assert_no_words(&out);
    dictate(&rig);
    let after_args = *rec.state().dictionaries.last().unwrap();
    assert_eq!(after_args.1, 3);

    // One per line on stdin; blank lines are left out, an overlap with
    // another set is boosted once.
    let out = ctl_stdin(
        &rig,
        &["words", "set", "other.set", "--ttl", "600"],
        "Quuxwell\n\n  Glimmux  \n1234\nzorblax\nsnarfle\n",
    );
    assert!(out.status.success(), "{:?}", text(&out));
    assert_eq!(text(&out).0, "loaded 4, skipped 1\n");
    assert_no_words(&out);
    dictate(&rig);
    let after_stdin = *rec.state().dictionaries.last().unwrap();
    assert_eq!(after_stdin.1, 5);
    assert_ne!(after_stdin.0, after_args.0);
    // Unchanged words, unchanged revision.
    dictate(&rig);
    assert_eq!(*rec.state().dictionaries.last().unwrap(), after_stdin);

    // Watch lines count them.
    let mut watcher = rig.watch();
    assert_eq!(
        watcher.line(),
        "localflow/1 ok state=idle model=ready mic=unknown words=6"
    );
    // Project words never reach the dictionary file.
    let file = dictionary_text(&rig);
    assert!(
        !file.contains("Zorblax") && !file.contains("Quuxwell"),
        "{file}"
    );

    let code = |args: &[&str]| ctl(&rig, none, args).status.code();
    for usage in [
        &["words"][..],
        &["words", "set"],
        &["words", "set", "repo", "a,b"],
        &["words", "set", "bad name", "x"],
        &["words", "set", "bad/name", "x"],
        &["words", "set", "repo", "--ttl", "59", "x"],
        &["words", "set", "repo", "--ttl", "86401", "x"],
        &["words", "set", "repo", "--ttl"],
        &["words", "clear"],
        &["words", "clear", "repo", "x"],
        &["words", "frobnicate", "repo"],
        &["dict", "add", "x", "--ttl", "60"],
        &["agents"],
        &["agents", "clear", "x"],
    ] {
        assert_eq!(code(usage), Some(2), "{usage:?}");
    }
    for (input, why) in [("Zorblax\nNew, Thing\n", "comma"), ("\n \n", "empty")] {
        let out = ctl_stdin(&rig, &["words", "set", "repo"], input);
        assert_eq!(out.status.code(), Some(2), "{why}");
        assert_no_words(&out);
    }

    let out = ctl(&rig, none, &["words", "clear", "repo"]);
    assert_eq!(text(&out).0, "cleared\n");
    assert_eq!(code(&["words", "clear", "repo"]), Some(1));
    assert_eq!(
        watcher.line(),
        "localflow/1 ok state=idle model=ready mic=unknown words=4"
    );
    dictate(&rig);
    // Snarfle, Quuxwell, Glimmux, Zorblax.
    assert_eq!(rec.state().dictionaries.last().unwrap().1, 4);
}

#[test]
fn agent_reports_show_on_watch_and_expire() {
    let (rig, _) = start("link-agents");
    let mut watcher = rig.watch();
    assert_eq!(
        watcher.line(),
        "localflow/1 ok state=idle model=ready mic=unknown"
    );
    assert_eq!(
        send(&rig, "localflow/1 agents-set approval=1 input=2 working=3"),
        "localflow/1 ok state=idle model=ready"
    );
    assert_eq!(
        watcher.line(),
        "localflow/1 ok state=idle model=ready mic=unknown agent-approval=1 agent-input=2 agent-working=3"
    );
    // Status replies do not carry the counts.
    assert_eq!(rig.cmd("status"), "state=idle model=ready");
    for bad in [
        "localflow/1 agents-set approval=1000",
        "localflow/1 agents-set ttl=4",
        "localflow/1 agents-set ttl=601",
        "localflow/1 agents-set at=1",
        "localflow/1 words-set set=repo words=Zorblax ttl=59",
        "localflow/1 words-set set=a%20b words=Zorblax",
    ] {
        assert_eq!(send(&rig, bad), "localflow/1 error bad-request", "{bad}");
    }

    // `localflowctl watch` prints the same fields.
    let mut child = ctl_command(&rig, Path::new("/nonexistent"), &["watch"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut first = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut first)
        .unwrap();
    let _ = child.kill();
    let _ = child.wait();
    assert_eq!(
        first,
        "state=idle model=ready mic=unknown agent-approval=1 agent-input=2 agent-working=3\n"
    );

    let out = ctl(&rig, Path::new("/nonexistent"), &["agents", "clear"]);
    assert!(out.status.success(), "{:?}", text(&out));
    assert_eq!(text(&out).0, "cleared\n");
    assert_eq!(
        watcher.line(),
        "localflow/1 ok state=idle model=ready mic=unknown"
    );

    // A report ends by itself when its time is up.
    send(&rig, "localflow/1 agents-set done=2 ttl=5");
    assert_eq!(
        watcher.line(),
        "localflow/1 ok state=idle model=ready mic=unknown agent-done=2"
    );
    let started = std::time::Instant::now();
    assert_eq!(
        watcher.line(),
        "localflow/1 ok state=idle model=ready mic=unknown"
    );
    assert!(started.elapsed() >= Duration::from_secs(4));
}

/// A fake T3 Code server on loopback: answers every request with `body`
/// (status 200) when it carries `Bearer <token>`, else 401. Runs until the
/// test ends.
fn fake_t3(token: &'static str, body: String) -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut head = Vec::new();
            let mut byte = [0u8; 1];
            while !head.ends_with(b"\r\n\r\n") {
                match std::io::Read::read(&mut stream, &mut byte) {
                    Ok(1) => head.push(byte[0]),
                    _ => break,
                }
            }
            let head = String::from_utf8_lossy(&head);
            let authorized = head.starts_with("GET /api/orchestration/shell HTTP/1.1\r\n")
                && head.contains(&format!("\r\nAuthorization: Bearer {token}\r\n"));
            let reply = if authorized {
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
            } else {
                "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into()
            };
            let _ = stream.write_all(reply.as_bytes());
        }
    });
    port
}

/// A synthetic T3 Code 0.1.0 thread shell with this pending request kind
/// and run status.
fn thread(request: Option<&str>, status: &str) -> serde_json::Value {
    serde_json::json!({
        "id": "thread-synthetic",
        "title": "Zorblax",
        "lineage": {
            "parentThreadId": null,
            "relationshipToParent": null,
            "rootThreadId": "thread-synthetic",
        },
        "status": status,
        "activityRunStatus": null,
        "pendingRuntimeRequest": request.map(|kind| serde_json::json!({
            "id": "request-synthetic",
            "kind": kind,
            "createdAt": "2026-10-16T10:00:00.000Z",
        })),
        "pendingBackgroundTasks": [],
        "archivedAt": null,
        "deletedAt": null,
        "settledOverride": null,
        "settledAt": null,
    })
}

fn write_private(path: &Path, contents: &str, mode: u32) {
    std::fs::write(path, contents).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
}

#[test]
fn t3_bridge_reports_thread_counts() {
    const TOKEN: &str = "synthetic-token-1234";
    let (rig, _) = start("link-t3");
    let shell = serde_json::json!({
        "schemaVersion": 1,
        "snapshotSequence": 1,
        "projects": [],
        "threads": [
            thread(Some("command_execution_approval"), "running"),
            thread(Some("user_input"), "running"),
            thread(Some("user_input"), "completed"),
            thread(None, "running"),
            thread(None, "completed"),
        ],
        "archivedThreads": [],
    });
    let port = fake_t3(TOKEN, shell.to_string());
    let t3_home = rig.dir.path().join("t3");
    std::fs::create_dir_all(t3_home.join("userdata")).unwrap();
    std::fs::write(
        t3_home.join("userdata/server-runtime.json"),
        serde_json::json!({"host": "0.0.0.0", "port": port}).to_string(),
    )
    .unwrap();
    let token_file = rig.dir.path().join("t3-token");
    write_private(&token_file, &format!("{TOKEN}\n"), 0o600);

    let mut watcher = rig.watch();
    watcher.line();
    let token_arg = token_file.display().to_string();
    let mut bridge = ctl_command(
        &rig,
        Path::new("/nonexistent"),
        &[
            "agents",
            "t3",
            "--token-file",
            &token_arg,
            "--interval-ms",
            "500",
        ],
    )
    .env("T3CODE_HOME", &t3_home)
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .unwrap();
    let lines = watcher.until("agent-");
    // The bridge reports, then prints the state change.
    let mut first = String::new();
    let mut stderr = BufReader::new(bridge.stderr.take().unwrap());
    stderr.read_line(&mut first).unwrap();
    let _ = bridge.kill();
    let out = bridge.wait_with_output().unwrap();
    assert_eq!(
        lines.last().unwrap(),
        "localflow/1 ok state=idle model=ready mic=unknown agent-approval=1 agent-input=2 agent-working=1 agent-done=1"
    );
    // Only counts leave the bridge: no title, and no token.
    assert_eq!(first, "localflowctl: T3 Code reachable\n");
    let mut rest = String::new();
    let _ = std::io::Read::read_to_string(&mut stderr, &mut rest);
    let (o, _) = text(&out);
    assert!(o.is_empty(), "{o:?}");
    assert!(
        !rest.contains(TOKEN) && !rest.contains("Zorblax"),
        "{rest:?}"
    );

    // A token file others can read is refused with exit 8.
    write_private(&token_file, &format!("{TOKEN}\n"), 0o644);
    let out = ctl_command(
        &rig,
        Path::new("/nonexistent"),
        &["agents", "t3", "--token-file", &token_arg],
    )
    .env("T3CODE_HOME", &t3_home)
    .stdin(Stdio::null())
    .output()
    .unwrap();
    assert_eq!(out.status.code(), Some(8), "{:?}", text(&out));
    assert!(!text(&out).1.contains(TOKEN));

    // Options of the bridge need `agents t3`.
    let out = ctl(
        &rig,
        Path::new("/nonexistent"),
        &["agents", "clear", "--interval-ms", "500"],
    );
    assert_eq!(out.status.code(), Some(2));
}
