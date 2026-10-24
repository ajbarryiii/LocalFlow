"""Tests for the oracle-overlap diagnostic (synthetic data only)."""

import unittest

import numpy as np

from lfspk.harness import overlap as O


class OverlapDiagnosticTest(unittest.TestCase):
    def test_coverage_and_bins(self):
        act = np.zeros(100, bool)
        act[10:20] = True
        self.assertEqual(O.coverage(10, 20, act), 1.0)
        self.assertEqual(O.coverage(15, 25, act), 0.5)
        self.assertEqual(O.coverage(30, 40, act), 0.0)
        self.assertEqual(O.coverage(5, 5, act), 0.0)
        self.assertEqual([O.bin_of(x) for x in (0.0, 0.1, 0.25, 0.3, 0.5, 0.51, 1.0)],
                         ["0", "(0,.25]", "(0,.25]", "(.25,.5]", "(.25,.5]", "(.5,1]", "(.5,1]"])

    def test_kept_causes_on_the_decision_span(self):
        n = 100
        raw = np.zeros(n, bool)
        raw[20:30] = True
        padded = raw.copy()
        padded[16:34] = True
        primary = padded.copy()
        primary[34:50] = True  # a merged gap
        acts = {"raw": raw, "padded": padded, "primary": primary}
        tau = 0.5
        self.assertEqual(O.kept_cause((20, 30), acts, tau), "acoustic")
        self.assertEqual(O.kept_cause((30, 34), acts, tau), "padding")
        self.assertEqual(O.kept_cause((36, 44), acts, tau), "gap_merging")
        with self.assertRaises(ValueError):
            O.kept_cause((52, 60), acts, tau)  # not kept under the frozen labels

    def test_reviewer_case_padding_required_on_widened_span(self):
        # Overlap-r1 #1: target aligned [480, 500) ms, hypothesis span [480, 560);
        # raw-span acoustic coverage 0.25 would say "acoustic", but the decision
        # span [400, 640) has acoustic coverage 2/24 < 0.125 and padded 10/24.
        n = 100
        raw = np.zeros(n, bool)
        raw[48:50] = True
        padded = np.zeros(n, bool)
        padded[44:54] = True
        acts = {"raw": raw, "padded": padded, "primary": padded.copy()}
        self.assertAlmostEqual(O.coverage(48, 56, raw), 0.25)
        self.assertEqual(O.kept_cause((40, 64), acts, 0.125), "padding")

    def test_removed_causes(self):
        act = np.zeros(100, bool)
        act[20:30] = True
        self.assertEqual(O.removed_cause((40, 50), act, 0.2), "pause")
        self.assertEqual(O.removed_cause((28, 40), act, 0.2), "partial")
        with self.assertRaises(ValueError):
            O.removed_cause((20, 30), act, 0.2)

    def test_summarize(self):
        items = [
            {"group": "S4", "source": "interferer", "cov": 0.9, "cause": "acoustic", "raw_keep": True},
            {"group": "S4", "source": "interferer", "cov": 0.3, "cause": "gap_merging", "raw_keep": False},
            {"group": "S4", "source": "interferer", "cov": 0.0, "cause": None, "raw_keep": False},
            {"group": "S1", "source": "interferer", "cov": 0.0, "cause": None, "raw_keep": True},
            {"group": "S4", "source": "target", "cov": 0.0, "cause": "pause", "raw_keep": False},
            {"group": "S4", "source": "target", "cov": 1.0, "cause": None, "raw_keep": True},
            {"group": "S0", "source": "target", "cov": 0.05, "cause": "partial", "raw_keep": True},
        ]
        s = O.summarize(items, tau=0.125)
        p = s["pooled_S1-S4"]
        self.assertEqual((p["interferer_words"], p["kept"]), (4, 2))
        self.assertEqual(p["coverage_all_interferer"], {"0": 0.5, "(0,.25]": 0.0, "(.25,.5]": 0.25, "(.5,1]": 0.25})
        self.assertEqual(p["coverage_kept_interferer"]["(.5,1]"], 0.5)
        self.assertEqual(p["kept_explained_by_overlap_above_half"], 0.5)
        self.assertEqual(p["kept_causes"], {"acoustic": 0.5, "padding": 0.0, "gap_merging": 0.5})
        self.assertEqual(p["kept_causes_low_overlap"]["gap_merging"], 1.0)
        self.assertEqual(p["kept_raw_span_would_keep"], 0.5)
        self.assertEqual(p["dropped_interferer_raw_span_would_keep"], 0.5)
        self.assertEqual((p["correct_target_words"], p["removed"]), (2, 1))
        self.assertEqual(p["removed_causes"]["pause"], 1.0)
        self.assertEqual(s["S0"]["removed"], 1)
        self.assertEqual(s["S0"]["removed_raw_span_would_keep"], 1.0)  # widening diluted it


class _Stub:
    """FrozenSet stand-in over synthetic renders."""

    def __init__(self, rows, labels):
        self.manifest = rows
        self._labels = labels
        self.hash = "synthetic"
        self.plans = {r["speaker"]: {"test_project_in_train": True} for r in rows}

    def labels(self, row):
        return {"labels": self._labels[row["id"]]}


def _fixture(corpus, shift_some=True):
    from lfspk.harness.mix import SCENARIOS, MixtureGenerator
    from lfspk.harness.refs import mixture_record, placed_words

    gen = MixtureGenerator("dev", corpus)
    rows, labels, words = [], {}, {}
    for j, (spk, ti) in enumerate((s_, t_) for s_ in ["100", "101", "102", "103", "104", "105"] for t_ in range(3)):
        target = corpus.utterances[spk][ti]
        g = gen.render_paired(SCENARIOS, 10 + j, target=target)
        for scen, m in g.items():
            mid = f"{scen}-{spk}-{ti:02d}"
            F = m.labels.size
            tw = placed_words(corpus, m.meta["target"]["placements"], F, min_inside=0.0)
            iw = [placed_words(corpus, it["placements"], F) for it in m.meta["interferers"]]
            hyp = [[w.text, w.start, w.end] for w in tw] + [[w.text, w.start, w.end] for ws in iw for w in ws]
            if shift_some and tw and j == 0 and scen == "S0":
                w = tw[-1]  # one target timestamp shifted into the tail pause (still within the 0.5 s tolerance)
                hyp[len(tw) - 1] = [w.text, w.end + 0.3, w.end + 0.35]
            hyp.sort(key=lambda x: x[1])
            asr = {f"mix:{mid}": {"text": "", "words": hyp}, f"tdry:{mid}": {"text": "", "words": [[w.text, w.start, w.end] for w in tw]}}
            for k, ws in enumerate(iw):
                asr[f"idry:{mid}:{k}"] = {"text": "", "words": [[w.text, w.start, w.end] for w in ws]}
            row = {"id": mid, "scenario": scen, "rir_mode": "coherent", "speaker": spk, "half": "A" if spk in ("100", "101", "102") else "B",
                   "relation_at": {"3": "cross_project", "10": "cross_project", "30": None},
                   "files": {"interferers_dry": [f"x{k}" for k in range(len(iw))]}, "meta": m.meta}
            rows.append(row)
            labels[mid] = m.labels
            words[mid] = mixture_record(row, m.labels, m.target_active, asr, corpus)
    return rows, labels, words


class EndToEndTest(unittest.TestCase):
    def test_run_matches_the_evaluator_oracle(self):
        from lfspk.harness import evaluate as E
        from lfspk.harness.synthetic import SyntheticCorpus

        with SyntheticCorpus() as corpus:
            rows, labels, words = _fixture(corpus)
            fs = _Stub(rows, labels)
            res = O.run("synthetic", fs=fs, words=words, corpus=corpus)
            ev = E.compute_metrics("synthetic", None, "all", "oracle", boot=5, fs=fs, words=words)
            c = ev["conditions"]["builtin|clean|10"]
            self.assertEqual(res["tau"], c["oracle"]["tau"])
            self.assertGreater(res["tau"], 0.0)  # the budget binds: a non-trivial decision
            self.assertLess(res["pooled_S1-S4"]["kept"], res["pooled_S1-S4"]["interferer_words"])
            self.assertEqual(res["S0"]["removed"], 1)
            self.assertEqual(res["S0"]["removed_causes"]["pause"], 1.0)
            p, q = res["pooled_S1-S4"], c["oracle"]["pooled_S1-S4"]
            self.assertEqual(p["interferer_words"], q["n_interferer/all"])
            self.assertAlmostEqual(p["kept_fraction"], q["interferer_kept/all"])
            n_ref = c["oracle"]["pooled_all"]["n_ref/all"]
            removed_all = sum(res[g]["removed"] for g in ("S0", "S1", "S2", "S3", "S4") if g in res)
            self.assertAlmostEqual(removed_all / n_ref, c["oracle"]["pooled_all"]["target_removed/all"])
            for g in ("S0", "S4", "pooled_S1-S4"):
                if res[g]["kept"]:
                    self.assertAlmostEqual(sum(res[g]["kept_causes"].values()), 1.0)
                if res[g]["removed"]:
                    self.assertAlmostEqual(sum(res[g]["removed_causes"].values()), 1.0)

    def test_label_mismatch_in_an_excluded_row_is_caught(self):
        from lfspk.harness.synthetic import SyntheticCorpus

        with SyntheticCorpus() as corpus:
            rows, labels, words = _fixture(corpus, shift_some=False)
            rows[0]["relation_at"]["10"] = "same_chapter"  # excluded from the headline
            labels[rows[0]["id"]] = labels[rows[0]["id"]].copy()
            labels[rows[0]["id"]][:5] = 1 - (labels[rows[0]["id"]][:5] % 2)
            with self.assertRaises(SystemExit):
                O.run("synthetic", fs=_Stub(rows, labels), words=words, corpus=corpus)

    def test_uncalibrated_oracle_refused(self):
        from lfspk.harness.synthetic import SyntheticCorpus

        with SyntheticCorpus() as corpus:
            rows, labels, words = _fixture(corpus, shift_some=False)
            for w in words.values():
                for t in w["tokens"]:
                    if t[4] == "target":
                        t[5] = "S"  # no correctly recognised target word anywhere
            with self.assertRaises(SystemExit):
                O.run("synthetic", fs=_Stub(rows, labels), words=words, corpus=corpus)


if __name__ == "__main__":
    unittest.main()
