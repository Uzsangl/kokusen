import json, subprocess, sys, unittest
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from morning_report import next_date_for, relation_ja  # noqa: E402


class MorningReportTests(unittest.TestCase):
    def run_cli(self, *args):
        p = subprocess.run([sys.executable, str(ROOT / "scripts" / "morning_report.py"), *args],
                           capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def test_year_crossover(self):
        """12月末に実行しても1月の誕生日を拾う。"""
        today = date(2026, 12, 28)
        self.assertEqual(next_date_for("01-02", today), date(2027, 1, 2))
        self.assertEqual(next_date_for("12-30", today), date(2026, 12, 30))

    def test_today_is_included(self):
        today = date(2026, 8, 23)
        self.assertEqual(next_date_for("08-23", today), today)

    def test_leap_day_skips_to_next_leap_year(self):
        """平年に 02-29 は到来しない。翌年も平年なら None。"""
        self.assertEqual(next_date_for("02-29", date(2027, 1, 1)), date(2028, 2, 29))
        self.assertIsNone(next_date_for("02-29", date(2026, 3, 1)))

    def test_relation_labels(self):
        self.assertEqual(relation_ja("protagonist"), "主人公")
        self.assertEqual(relation_ja("co_lead,major"), "共同主演/主要")
        self.assertEqual(relation_ja(""), "")

    def test_silent_when_empty(self):
        """該当0件なら何も出力しない（通知抑止の契約）。"""
        self.assertEqual(self.run_cli("--days", "0").strip(), "")

    def test_always_flag_speaks_when_empty(self):
        self.assertIn("該当する誕生日はありません", self.run_cli("--days", "0", "--always"))

    def test_json_shape(self):
        payload = json.loads(self.run_cli("--days", "30", "--json"))
        self.assertIn("today", payload)
        self.assertIn("upcoming", payload)
        self.assertEqual(payload["window_days"], 30)
        for r in payload["upcoming"]:
            self.assertIn("days_ahead", r)
            self.assertTrue(1 <= r["days_ahead"] <= 30)
            # 内部キーが漏れていないこと
            self.assertFalse([k for k in r if k.startswith("_")])

    def test_only_verified_appears(self):
        payload = json.loads(self.run_cli("--days", "366", "--json"))
        for r in payload["today"] + payload["upcoming"]:
            self.assertIn(r["birthday_status"], {"verified_primary", "verified_secondary"})


if __name__ == "__main__":
    unittest.main()
