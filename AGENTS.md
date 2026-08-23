# AGENTS.md

Use `CLAUDE.md` as the canonical repository policy.

Before changing birthday data:
1. Read `CLAUDE.md`.
2. Preserve source provenance.
3. Never invent unknown birthdays.
4. Run:
   `python3 scripts/validate_data.py`
   `python3 scripts/export_context.py`
5. Default factual outputs to verified birthdays only.
