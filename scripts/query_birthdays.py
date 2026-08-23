#!/usr/bin/env python3
from __future__ import annotations
import argparse, csv, json, sys
from pathlib import Path
from datetime import datetime, date, timedelta
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"

VERIFIED = {"verified_primary", "verified_secondary"}

def read_csv(name):
    with (DATA / name).open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))

def load():
    machines = {r["machine_id"]: r for r in read_csv("machines.csv")}
    chars = {r["character_id"]: r for r in read_csv("characters.csv")}
    maps = read_csv("machine_characters.csv")
    aliases = read_csv("aliases.csv")
    return machines, chars, maps, aliases

def normalize_mmdd(s):
    s = s.strip().replace("/", "-")
    parts = s.split("-")
    if len(parts) != 2:
        raise ValueError("日付は MM-DD 形式で指定してください（例: 10-07）")
    m, d = map(int, parts)
    # leap-year validation accepts 02-29
    date(2024, m, d)
    return f"{m:02d}-{d:02d}"

def char_machine_index(machines, chars, maps):
    by_char = {}
    for mp in maps:
        by_char.setdefault(mp["character_id"], []).append((machines[mp["machine_id"]], mp))
    return by_char

def format_rows(rows, as_json=False):
    if as_json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return
    if not rows:
        print("該当なし")
        return
    for r in rows:
        machine_text = " / ".join(r["machines"]) if r["machines"] else "対応機種未登録"
        print(f'{r["birthday_mmdd"]}  {r["character_name"]}  [{r["relation"]}]  {machine_text}  ({r["birthday_status"]})')

def build_rows(machines, chars, maps, include_unknown=False, protagonists_only=False):
    idx = char_machine_index(machines, chars, maps)
    out = []
    for cid, ch in chars.items():
        if not ch["birthday_mmdd"] and not include_unknown:
            continue
        if ch["birthday_status"] not in VERIFIED and not include_unknown:
            continue
        associations = idx.get(cid, [])
        if protagonists_only:
            associations = [(m, mp) for m, mp in associations
                            if mp["relation"] in {"protagonist","co_protagonist","co_lead"}]
            if not associations:
                continue
        relations = sorted({mp["relation"] for _, mp in associations})
        out.append({
            "character_id": cid,
            "character_name": ch["character_name"],
            "franchise": ch["franchise"],
            "birthday_mmdd": ch["birthday_mmdd"],
            "birthday_status": ch["birthday_status"],
            "relation": ",".join(relations) if relations else ch["notes"],
            "machines": sorted({m["machine_name"] for m, _ in associations}),
        })
    return out

def main():
    p = argparse.ArgumentParser(description="Slot character birthday context query")
    p.add_argument("--json", action="store_true", help="JSONで出力")
    p.add_argument("--all-statuses", action="store_true", help="未確認データも含める")
    p.add_argument("--protagonists-only", action="store_true", help="主人公/共同主人公だけ")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("today")
    d = sub.add_parser("date"); d.add_argument("mmdd")
    mo = sub.add_parser("month"); mo.add_argument("month", type=int)
    up = sub.add_parser("upcoming"); up.add_argument("--days", type=int, default=7)
    ma = sub.add_parser("machine"); ma.add_argument("query")
    ca = sub.add_parser("character"); ca.add_argument("query")
    sub.add_parser("stats")

    args = p.parse_args()
    machines, chars, maps, aliases = load()
    rows = build_rows(machines, chars, maps, args.all_statuses, args.protagonists_only)

    if args.cmd == "today":
        mmdd = datetime.now(ZoneInfo("Asia/Tokyo")).strftime("%m-%d")
        rows = [r for r in rows if r["birthday_mmdd"] == mmdd]
        rows.sort(key=lambda x: (x["birthday_mmdd"], x["character_name"]))
        format_rows(rows, args.json)
    elif args.cmd == "date":
        mmdd = normalize_mmdd(args.mmdd)
        rows = [r for r in rows if r["birthday_mmdd"] == mmdd]
        rows.sort(key=lambda x: x["character_name"])
        format_rows(rows, args.json)
    elif args.cmd == "month":
        if not 1 <= args.month <= 12:
            p.error("month は 1〜12")
        prefix = f"{args.month:02d}-"
        rows = [r for r in rows if r["birthday_mmdd"].startswith(prefix)]
        rows.sort(key=lambda x: (x["birthday_mmdd"], x["character_name"]))
        format_rows(rows, args.json)
    elif args.cmd == "upcoming":
        now = datetime.now(ZoneInfo("Asia/Tokyo")).date()
        wanted = set()
        for i in range(max(0,args.days)+1):
            dt = now + timedelta(days=i)
            wanted.add(dt.strftime("%m-%d"))
        rows = [r for r in rows if r["birthday_mmdd"] in wanted]
        # Sort by days ahead, not lexicographic (handles year crossover)
        def delta_for(mmdd):
            m,d = map(int, mmdd.split("-"))
            candidates=[]
            for y in (now.year, now.year+1):
                try:
                    dt=date(y,m,d)
                except ValueError:
                    continue
                if dt >= now:
                    candidates.append((dt-now).days)
            return min(candidates) if candidates else 9999
        rows.sort(key=lambda x: (delta_for(x["birthday_mmdd"]), x["character_name"]))
        format_rows(rows, args.json)
    elif args.cmd == "machine":
        q = args.query.casefold()
        expanded = {args.query}
        for a in aliases:
            if q == a["alias"].casefold():
                expanded.add(a["target_value"])
        eq = [x.casefold() for x in expanded]
        mids = {mid for mid,m in machines.items() if any(x in m["machine_name"].casefold() or x in m["franchise"].casefold() for x in eq)}
        charids = {mp["character_id"] for mp in maps if mp["machine_id"] in mids}
        rows = [r for r in rows if r["character_id"] in charids]
        # With --all-statuses, include mapped unknown birthdays too
        rows.sort(key=lambda x: (x["birthday_mmdd"] or "99-99", x["character_name"]))
        format_rows(rows, args.json)
    elif args.cmd == "character":
        q = args.query.casefold()
        rows = [r for r in rows if q in r["character_name"].casefold()]
        rows.sort(key=lambda x: (x["birthday_mmdd"] or "99-99", x["character_name"]))
        format_rows(rows, args.json)
    elif args.cmd == "stats":
        verified = sum(1 for ch in chars.values() if ch["birthday_status"] in VERIFIED and ch["birthday_mmdd"])
        primary = sum(1 for ch in chars.values() if ch["birthday_status"] == "verified_primary")
        secondary = sum(1 for ch in chars.values() if ch["birthday_status"] == "verified_secondary")
        unknown = sum(1 for ch in chars.values() if ch["birthday_status"] == "unknown")
        mapped_machines = len({mp["machine_id"] for mp in maps})
        result = {
            "machines": len(machines),
            "mapped_machines": mapped_machines,
            "characters": len(chars),
            "verified_birthdays": verified,
            "verified_primary": primary,
            "verified_secondary": secondary,
            "unknown_birthdays": unknown,
        }
        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            for k,v in result.items(): print(f"{k}: {v}")

if __name__ == "__main__":
    main()
