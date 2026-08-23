#!/usr/bin/env python3
"""朝の共有用レポート。今日の誕生日 + 今後N日分をまとめて出す。

該当が1件もなければ何も出力しない（呼び出し側が通知を抑止できるように）。
データは data/*.csv だけを見る。外部ネットワークにはアクセスしない。
"""
from __future__ import annotations
import argparse, json, sys
from datetime import datetime, date, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent))
from query_birthdays import load, build_rows  # noqa: E402

JST = ZoneInfo("Asia/Tokyo")
WEEKDAYS = "月火水木金土日"

RELATION_JA = {
    "protagonist": "主人公",
    "co_protagonist": "共同主人公",
    "co_lead": "共同主演",
    "major": "主要",
    "central": "中心人物",
    "representative": "看板",
}
STATUS_JA = {
    "verified_primary": "公式",
    "verified_secondary": "二次情報",
}


def relation_ja(relation: str) -> str:
    if not relation:
        return ""
    return "/".join(RELATION_JA.get(r, r) for r in relation.split(","))


def next_date_for(mmdd: str, today: date) -> date | None:
    """mmdd の次の到来日を返す。2月29日は平年ではスキップされる。"""
    m, d = map(int, mmdd.split("-"))
    for y in (today.year, today.year + 1):
        try:
            dt = date(y, m, d)
        except ValueError:
            continue
        if dt >= today:
            return dt
    return None


def collect(days: int, protagonists_only: bool = False):
    machines, chars, maps, _aliases = load()
    rows = build_rows(machines, chars, maps,
                      include_unknown=False,
                      protagonists_only=protagonists_only)
    today = datetime.now(JST).date()

    today_hits, upcoming = [], []
    for r in rows:
        dt = next_date_for(r["birthday_mmdd"], today)
        if dt is None:
            continue
        delta = (dt - today).days
        if delta == 0:
            today_hits.append(r)
        elif 1 <= delta <= days:
            upcoming.append({**r, "_date": dt, "_delta": delta})

    today_hits.sort(key=lambda x: x["character_name"])
    upcoming.sort(key=lambda x: (x["_delta"], x["character_name"]))
    return today, today_hits, upcoming


def fmt_date(dt: date) -> str:
    return f"{dt.month}月{dt.day}日({WEEKDAYS[dt.weekday()]})"


def render_text(today: date, today_hits, upcoming, days: int) -> str:
    out = []
    if today_hits:
        out.append(f"🎂 今日の誕生日 — {fmt_date(today)}")
        out.append("")
        for r in today_hits:
            rel = relation_ja(r["relation"])
            machines = " / ".join(r["machines"]) or "対応機種未登録"
            out.append(f'  {r["character_name"]}' + (f"  [{rel}]" if rel else ""))
            out.append(f"    {machines}")
            out.append(f'    ※{STATUS_JA.get(r["birthday_status"], r["birthday_status"])}')
            out.append("")

    if upcoming:
        out.append(f"📅 今後{days}日")
        out.append("")
        for r in upcoming:
            rel = relation_ja(r["relation"])
            machines = " / ".join(r["machines"]) or "対応機種未登録"
            status = STATUS_JA.get(r["birthday_status"], r["birthday_status"])
            head = f'  {r["_date"].month}/{r["_date"].day}({WEEKDAYS[r["_date"].weekday()]})'
            out.append(f'{head}  {r["character_name"]}' + (f"  [{rel}]" if rel else ""))
            out.append(f"        {machines}  ※{status}")
        out.append("")

    return "\n".join(out).rstrip()


def main():
    p = argparse.ArgumentParser(description="朝の誕生日レポート")
    p.add_argument("--days", type=int, default=7, help="今後何日先まで見るか（既定7）")
    p.add_argument("--protagonists-only", action="store_true", help="主人公/共同主人公のみ")
    p.add_argument("--json", action="store_true", help="JSONで出力")
    p.add_argument("--always", action="store_true",
                   help="該当0件でも「該当なし」を出力する（既定は無出力）")
    args = p.parse_args()

    if args.days < 0:
        p.error("--days は0以上")

    today, today_hits, upcoming = collect(args.days, args.protagonists_only)

    if args.json:
        payload = {
            "date": today.isoformat(),
            "window_days": args.days,
            "today": [{k: v for k, v in r.items() if not k.startswith("_")} for r in today_hits],
            "upcoming": [
                {**{k: v for k, v in r.items() if not k.startswith("_")},
                 "date": r["_date"].isoformat(), "days_ahead": r["_delta"]}
                for r in upcoming
            ],
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    if not today_hits and not upcoming:
        if args.always:
            print(f"{fmt_date(today)}時点で、今後{args.days}日以内に該当する誕生日はありません。")
        return

    print(render_text(today, today_hits, upcoming, args.days))


if __name__ == "__main__":
    main()
