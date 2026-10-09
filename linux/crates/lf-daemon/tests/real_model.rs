//! The daemon with the real model: a fake capture returns a public
//! LibriSpeech test-clean utterance, a fake output collects the typed text,
//! and the text must equal the M1 GPU hypothesis after post-processing.
//!
//! Ignored by default (loads about 1.5 GB of weights and pins 16 threads).
//! Paths come from the environment, so none are committed:
//!
//! ```text
//! LF_TEST_EXPORT=<export dir> \
//! LF_TEST_LIBRISPEECH=<LibriSpeech/test-clean> \
//! LF_TEST_M1_HYPS=<M1-test/librispeech_clean.json> \
//! cargo test --release -p lf-daemon --test real_model -- --ignored --nocapture
//! ```

mod common;

use std::path::PathBuf;
use std::time::Instant;

use common::Rig;
use lf_daemon::config::{Precision, resolve_cpus};
use lf_daemon::recognizer::asr_factory;
use lf_daemon::testing::FakeCapture;

// The first utterance is repeated to compare the first dictation with a later one.
const UTTERANCES: &[&str] = &["1089-134686-0000", "1089-134686-0001", "1089-134686-0000"];

fn env_path(name: &str) -> PathBuf {
    PathBuf::from(
        std::env::var_os(name).unwrap_or_else(|| panic!("set {name} (see the file header)")),
    )
}

fn read_flac(path: &std::path::Path) -> Vec<f32> {
    let mut reader = claxon::FlacReader::open(path).unwrap();
    let info = reader.streaminfo();
    assert_eq!((info.sample_rate, info.channels), (16_000, 1));
    let scale = 1.0 / (1u32 << (info.bits_per_sample - 1)) as f32;
    reader
        .samples()
        .map(|s| s.unwrap() as f32 * scale)
        .collect()
}

fn m1_hypothesis(path: &std::path::Path, id: &str) -> String {
    let v: serde_json::Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    v["records"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == id)
        .and_then(|r| r["hyp"].as_str())
        .unwrap_or_else(|| panic!("{id} not in {}", path.display()))
        .to_owned()
}

#[test]
#[ignore = "loads the real model; see the file header"]
fn dictates_librispeech_with_the_real_model() {
    let export = env_path("LF_TEST_EXPORT");
    let librispeech = env_path("LF_TEST_LIBRISPEECH");
    let hyps = env_path("LF_TEST_M1_HYPS");
    let cpus = resolve_cpus(None).unwrap();

    let capture = FakeCapture::default();
    let load = Instant::now();
    let rig = Rig::start(
        "real-model",
        capture.clone(),
        asr_factory(export, cpus, Precision::Int8(3)),
        common::settings(),
        true,
    );
    eprintln!("model ready after {:.2?}", load.elapsed());

    let mut expected_all = String::new();
    for id in UTTERANCES {
        let mut parts = id.split('-');
        let (speaker, chapter) = (parts.next().unwrap(), parts.next().unwrap());
        let audio = read_flac(
            &librispeech
                .join(speaker)
                .join(chapter)
                .join(format!("{id}.flac")),
        );
        let seconds = audio.len() as f64 / 16_000.0;
        capture.state().samples = audio;

        let expected = lf_dictation::process(
            &m1_hypothesis(&hyps, id),
            &[],
            lf_dictation::Options::default(),
            None,
        );
        assert!(!expected.output.is_empty());
        assert!(!expected.should_press_enter);

        rig.cmd("press");
        let t = Instant::now();
        assert_eq!(rig.cmd("release"), "state=transcribing model=ready");
        rig.wait_for("state=idle");
        eprintln!(
            "{id}: {seconds:.1} s of audio, release to idle in {:.0?}",
            t.elapsed()
        );
        expected_all += &expected.output;
        assert_eq!(rig.output.text(), expected_all, "{id}");
    }
    let history = lf_daemon::history::History::open(&common::data_dir(&rig.dir)).unwrap();
    assert_eq!(history.entries().count(), UTTERANCES.len());
}
