import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("speech_benchmark", Path(__file__).resolve().parents[1] / "scripts/benchmark-apple-speech.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


def utterance(reference, hypothesis, seconds=0.5, duration=5.0):
    return {"reference": reference, "hypothesis": hypothesis, "seconds": seconds, "duration": duration}


class NormalizationTests(unittest.TestCase):
    def test_case_punctuation_and_apostrophes(self):
        self.assertEqual(benchmark.normalize("Hello, World! It's 'fine'."), ["hello", "world", "it's", "fine"])
        self.assertEqual(benchmark.normalize("well-known — re-entry"), ["well", "known", "re", "entry"])
        self.assertEqual(benchmark.normalize("Mr. Smith met Mrs. Jones and Dr. Brown"),
                         ["mister", "smith", "met", "missus", "jones", "and", "doctor", "brown"])
        self.assertEqual(benchmark.normalize(""), [])

    def test_digits_become_reference_style_words(self):
        cases = {
            "7": "seven", "21": "twenty one", "105": "one hundred five", "3,400": "three thousand four hundred",
            "1st": "first", "22nd": "twenty second", "3rd": "third", "40th": "fortieth", "12th": "twelfth",
            "1850": "eighteen fifty", "1905": "nineteen o five", "1900": "nineteen hundred",
            "2005": "two thousand five", "$5": "five dollars", "10%": "ten percent",
        }
        for written, spoken in cases.items():
            with self.subTest(written=written):
                self.assertEqual(benchmark.normalize(written), spoken.split())

    def test_spelling_map_applies_to_words(self):
        spelling = {"counselled": "counseled", "colour": "color"}
        self.assertEqual(benchmark.normalize("Counselled, the colour!", spelling), ["counseled", "the", "color"])
        self.assertEqual(benchmark.normalize("Counselled", {}), ["counselled"])

    def test_spelling_map_must_match_pinned_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "spelling.json"
            path.write_text(json.dumps({"invented": "invent"}))
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(benchmark.load_spelling_map(path, digest), {"invented": "invent"})
            with self.assertRaises(ValueError):
                benchmark.load_spelling_map(path, "0" * 64)

    def test_plain_normalizer_keeps_digits(self):
        self.assertEqual(benchmark.plain_normalize("In 1850, Mr. Smith"), ["in", "1850", "mr", "smith"])


class AlignmentTests(unittest.TestCase):
    def test_counts_substitutions_deletions_insertions(self):
        reference = "the cat sat down".split()
        self.assertEqual(benchmark.align(reference, reference), (0, 0, 0))
        self.assertEqual(benchmark.align(reference, "the bat sat down".split()), (1, 0, 0))
        self.assertEqual(benchmark.align(reference, "the cat down".split()), (0, 1, 0))
        self.assertEqual(benchmark.align(reference, "the big cat sat down".split()), (0, 0, 1))
        self.assertEqual(benchmark.align(reference, []), (0, 4, 0))
        self.assertEqual(benchmark.align([], ["extra"]), (0, 0, 1))


class LibriSpeechTests(unittest.TestCase):
    def test_reads_transcripts_and_requires_audio(self):
        with tempfile.TemporaryDirectory() as temporary:
            chapter = Path(temporary) / "LibriSpeech/test-clean/11/22"
            chapter.mkdir(parents=True)
            (chapter / "11-22.trans.txt").write_text("11-22-0001 INVENTED FIRST LINE\n11-22-0000 INVENTED SECOND\n")
            for name in ("11-22-0000", "11-22-0001"):
                (chapter / f"{name}.flac").write_bytes(b"invented")
            items = benchmark.load_librispeech(Path(temporary), "test-clean")
            self.assertEqual([item["id"] for item in items], ["11-22-0000", "11-22-0001"])
            self.assertEqual(items[1]["reference"], "INVENTED FIRST LINE")
            self.assertEqual(items[0]["path"], chapter / "11-22-0000.flac")
            (chapter / "11-22-0001.flac").unlink()
            with self.assertRaises(ValueError):
                benchmark.load_librispeech(Path(temporary), "test-clean")

    def test_rejects_output_inside_repository(self):
        with self.assertRaises(ValueError):
            benchmark.outside_repo(benchmark.REPO / "results")


class SummaryTests(unittest.TestCase):
    def test_corpus_wer_speed_and_failures(self):
        summary = benchmark.summarize([
            utterance("the cat sat", "the bat sat", seconds=1.0, duration=10.0),
            utterance("in eighteen fifty", "In 1850.", seconds=0.2, duration=2.0),
            utterance("one more word", "", seconds=0.3, duration=3.0),
        ], seed=1)
        self.assertEqual(summary["utterances"], 3)
        self.assertEqual(summary["reference_words"], 9)
        self.assertEqual((summary["substitutions"], summary["deletions"], summary["insertions"]), (1, 3, 0))
        self.assertAlmostEqual(summary["wer"], 4 / 9)
        self.assertAlmostEqual(summary["plain_wer"], 6 / 9)
        self.assertEqual(summary["empty_hypotheses"], 1)
        self.assertAlmostEqual(summary["real_time_factor"], 1.5 / 15.0)
        self.assertAlmostEqual(summary["median_seconds"], 0.3)
        low, high = summary["wer_95ci"]
        self.assertLessEqual(low, summary["wer"])
        self.assertGreaterEqual(high, summary["wer"])
        self.assertEqual(summary, benchmark.summarize([
            utterance("the cat sat", "the bat sat", seconds=1.0, duration=10.0),
            utterance("in eighteen fifty", "In 1850.", seconds=0.2, duration=2.0),
            utterance("one more word", "", seconds=0.3, duration=3.0),
        ], seed=1))

    def test_spelling_map_is_reported_separately(self):
        summary = benchmark.summarize([utterance("his belly counselled him", "His belly counseled him.")],
                                      seed=1, spelling={"counselled": "counseled"})
        self.assertEqual(summary["wer"], 0.0)
        self.assertAlmostEqual(summary["wer_without_spelling_map"], 0.25)
        self.assertAlmostEqual(summary["plain_wer"], 0.25)

    def test_paired_difference_uses_matching_utterances(self):
        baseline = {"a": utterance("one two", "one two"), "b": utterance("three four", "three four")}
        candidate = {"a": utterance("one two", "one too"), "b": utterance("three four", "three four")}
        difference = benchmark.paired_difference(baseline, candidate, seed=1)
        self.assertAlmostEqual(difference["wer_delta"], 0.25)
        low, high = difference["wer_delta_95ci"]
        self.assertLessEqual(low, 0.25)
        self.assertGreaterEqual(high, 0.25)
        with self.assertRaises(ValueError):
            benchmark.paired_difference(baseline, {"a": candidate["a"]}, seed=1)


if __name__ == "__main__":
    unittest.main()
