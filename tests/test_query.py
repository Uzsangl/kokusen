import csv, subprocess, sys, unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

class RepoTests(unittest.TestCase):
    def run_cli(self,*args):
        p=subprocess.run([sys.executable, str(ROOT/"scripts"/"query_birthdays.py"), *args],
                         capture_output=True,text=True,encoding="utf-8")
        self.assertEqual(p.returncode,0,p.stderr)
        return p.stdout

    def test_kaneki(self):
        out=self.run_cli("date","12-20")
        self.assertIn("金木研",out)
        self.assertIn("L 東京喰種",out)

    def test_kirito(self):
        out=self.run_cli("date","10-07")
        self.assertIn("キリト",out)
        self.assertIn("ソードアート・オンラインII",out)

    def test_unknown_hidden_by_default(self):
        out=self.run_cli("machine","からくり")
        self.assertEqual(out.strip(),"該当なし")
        out2=self.run_cli("--all-statuses","machine","からくり")
        self.assertIn("才賀勝",out2)

    def test_catalog_has_100(self):
        with (ROOT/"data"/"machines.csv").open(encoding="utf-8-sig",newline="") as f:
            self.assertEqual(len(list(csv.DictReader(f))),100)

if __name__=="__main__":
    unittest.main()
