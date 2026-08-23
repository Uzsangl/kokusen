#!/usr/bin/env python3
import csv, sys, re
from pathlib import Path
from datetime import date

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"

def read(name):
    with (DATA/name).open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))

def validate_mmdd(s):
    if not re.fullmatch(r"\d{2}-\d{2}", s):
        return False
    m,d = map(int,s.split("-"))
    try:
        date(2024,m,d)  # leap year permits 02-29
        return True
    except ValueError:
        return False

def main():
    machines=read("machines.csv")
    chars=read("characters.csv")
    maps=read("machine_characters.csv")
    sources=read("sources.csv")
    errors=[]

    for rows, field, label in [(machines,"machine_id","machine"),(chars,"character_id","character"),(sources,"source_id","source")]:
        vals=[r[field] for r in rows]
        dup={v for v in vals if vals.count(v)>1}
        if dup: errors.append(f"duplicate {label} ids: {sorted(dup)}")

    names=[r["machine_name"] for r in machines]
    dup_names={v for v in names if names.count(v)>1}
    if dup_names: errors.append(f"duplicate machine names: {sorted(dup_names)}")

    mids={r["machine_id"] for r in machines}
    cids={r["character_id"] for r in chars}
    sids={r["source_id"] for r in sources}

    for r in chars:
        status=r["birthday_status"]
        bday=r["birthday_mmdd"]
        sid=r["source_id"]
        if bday and not validate_mmdd(bday):
            errors.append(f'invalid birthday {r["character_id"]}: {bday}')
        if status.startswith("verified"):
            if not bday: errors.append(f'verified without birthday: {r["character_id"]}')
            if not sid: errors.append(f'verified without source: {r["character_id"]}')
            if sid and sid not in sids: errors.append(f'unknown source: {r["character_id"]} -> {sid}')
        if status=="unknown" and bday:
            errors.append(f'unknown status with birthday populated: {r["character_id"]}')

    seen=set()
    for r in maps:
        key=(r["machine_id"],r["character_id"])
        if key in seen: errors.append(f"duplicate mapping: {key}")
        seen.add(key)
        if r["machine_id"] not in mids: errors.append(f'unknown machine mapping: {r}')
        if r["character_id"] not in cids: errors.append(f'unknown character mapping: {r}')

    if len(machines) != 100:
        errors.append(f"expected 100 initial machines, got {len(machines)}")

    if errors:
        print("VALIDATION FAILED")
        for e in errors: print("-",e)
        sys.exit(1)
    print(f"OK: {len(machines)} machines, {len(chars)} characters, {len(maps)} mappings, {len(sources)} sources")

if __name__=="__main__":
    main()
