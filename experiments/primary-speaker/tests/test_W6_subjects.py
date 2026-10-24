"""W6 subject lists, the control pairing and the base pins (DESIGN 1, 2.1, 3)."""

from __future__ import annotations

import os
import unittest

from lfspk.personal import subjects as S


class TestPairing(unittest.TestCase):
    def test_lists(self):
        self.assertEqual(len(S.PILOT["F"]), 11)
        self.assertEqual(len(S.PILOT["M"]), 11)
        self.assertEqual(len(set(S.pilot_order())), 22)

    def test_derangement_same_sex(self):
        for s in S.pilot_order():
            b = S.control_donor(s)
            self.assertNotEqual(b, s)
            self.assertEqual(S.sex_of(b), S.sex_of(s))
        # a single cycle per sex: every subject is exactly one other subject's control donor
        donors = [S.control_donor(s) for s in S.pilot_order()]
        self.assertEqual(sorted(donors), sorted(S.pilot_order()))
        for sx in ("F", "M"):
            seen, cur = [], S.PILOT[sx][0]
            for _ in range(11):
                seen.append(cur)
                cur = S.control_donor(cur)
            self.assertEqual(cur, S.PILOT[sx][0])
            self.assertEqual(sorted(seen), sorted(S.PILOT[sx]))

    def test_select_rule(self):
        held = tuple(str(i) for i in range(1, 41))
        sex = {s: ("F" if int(s) % 2 else "M") for s in held}
        levels = {s: ("cross_project" if int(s) % 3 else "same_project_cross_chapter") for s in held}
        got = S.select_pilot(levels, sex, held)
        for sx in ("F", "M"):
            self.assertEqual(len(got[sx]), 11)
            self.assertTrue(all(levels[s] == "cross_project" and sex[s] == sx for s in got[sx]))
        levels = {s: "same_project_cross_chapter" for s in held}
        with self.assertRaises(ValueError):
            S.select_pilot(levels, sex, held)

    def test_base_pins_are_full_hashes(self):
        for v in S.BASES.values():
            self.assertEqual(len(v), 64)
            int(v, 16)

    def test_scoring_pool_excludes_pilot(self):
        held = tuple(sorted(set(S.pilot_order()) | {str(i) for i in range(90001, 90027)}, key=int))
        pool = S.scoring_interferers(held)
        self.assertEqual(len(pool), 26)
        self.assertFalse(set(pool) & set(S.pilot_order()))


@unittest.skipUnless(os.path.ismount("/mnt/hd"), "needs the corpus metadata")
class TestRealPilot(unittest.TestCase):
    def test_registered_list_recomputes(self):
        r = S.verify_pilot()
        self.assertEqual(len(r["held_out"]), 48)
        self.assertEqual(len(S.scoring_interferers(r["held_out"])), 26)


if __name__ == "__main__":
    unittest.main()
