#!/usr/bin/env python3
import csv, json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
DATA=ROOT/"data"
OUT=ROOT/"context"

def read(name):
    with (DATA/name).open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))

machines={r["machine_id"]:r for r in read("machines.csv")}
chars={r["character_id"]:r for r in read("characters.csv")}
sources={r["source_id"]:r for r in read("sources.csv")}
maps=read("machine_characters.csv")

assoc={}
for mp in maps:
    assoc.setdefault(mp["character_id"],[]).append({
        "machine_id":mp["machine_id"],
        "machine_name":machines[mp["machine_id"]]["machine_name"],
        "relation":mp["relation"],
        "priority":int(mp["priority"]) if mp["priority"] else None,
    })

rows=[]
for cid,ch in chars.items():
    if ch["birthday_status"] not in {"verified_primary","verified_secondary"}:
        continue
    rows.append({
        **ch,
        "source": sources.get(ch["source_id"],{}),
        "machines": sorted(assoc.get(cid,[]), key=lambda x:(x["priority"] or 999,x["machine_name"]))
    })
rows.sort(key=lambda r:(r["birthday_mmdd"],r["character_name"]))

(OUT/"slot_birthdays.json").write_text(json.dumps({
    "generated_from":"data/*.csv",
    "policy":"verified birthdays only",
    "characters":rows
}, ensure_ascii=False, indent=2), encoding="utf-8")

md=["# Verified Slot Character Birthdays","","> Generated file. Edit CSVs, then run `python3 scripts/export_context.py`.",""]
for r in rows:
    ms=", ".join(x["machine_name"] for x in r["machines"]) or "対応機種未登録"
    md.append(f'- **{r["birthday_mmdd"]}** {r["character_name"]} — {r["franchise"]} — {ms} — `{r["birthday_status"]}`')
(OUT/"slot_birthdays.md").write_text("\n".join(md)+"\n", encoding="utf-8")
print(f"exported: {len(rows)} verified character birthdays")
