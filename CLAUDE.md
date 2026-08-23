# CLAUDE.md — Slot Birthday Context

このリポジトリは、スロット機種と版権キャラクターの誕生日を出典付きで管理する。

## 最優先ルール

1. **誕生日を推測・創作しない。**
2. ユーザーに事実として返す日付は原則 `verified_primary` / `verified_secondary` のみ。
3. `unknown` は「未確認」と明示し、日付を補完しない。
4. 一次情報（作品公式・出版社・権利元・遊技機メーカー）を優先。
5. 二次情報しかない場合は `verified_secondary` のままにする。
6. キャラ誕生日と、メーカー記念日/シリーズ記念日を混同しない。記念日は `data/events.csv`。
7. 新規追加・修正後は必ず `python3 scripts/validate_data.py` を実行。
8. CSVを更新したら `python3 scripts/export_context.py` で `context/` を再生成する。

## ユーザーの典型的な意図

「今日誕生日のスロキャラ」
→ `python3 scripts/query_birthdays.py today`

「10月の主人公誕生日」
→ `python3 scripts/query_birthdays.py --protagonists-only month 10`

「この機種の誕生日キャラ」
→ `python3 scripts/query_birthdays.py machine "<機種名>"`

「来週の誕生日」
→ `python3 scripts/query_birthdays.py upcoming --days 7`

「朝の共有」「今日なんかある？」
→ `python3 scripts/morning_report.py`
出力が空なら該当0件。**その場合は通知しない**（「該当なし」を毎朝送らない）。

## データ編集

### characters.csv
- `birthday_mmdd`: `MM-DD`
- `birthday_status`: `verified_primary | verified_secondary | unknown`
- verifiedなら `source_id` 必須
- unknownなら `birthday_mmdd` は空欄

### machine_characters.csv
`relation` の推奨値:
- `protagonist`
- `co_protagonist`
- `co_lead`
- `major`
- `central`
- `representative`

主人公がプレイヤーアバター等で固定されない作品は、無理に固有名を主人公として作らない。

## 外部検索で新規検証するとき

優先順:
1. 作品公式
2. 出版社/権利元
3. パチスロメーカー公式
4. 公式ゲーム/公式商品告知
5. パチスロ専門キャラ誕生日DB
6. その他二次情報

出典URLと確認日を必ず保存する。

## 禁止

- Wikipedia/Fandom等だけを根拠に `verified_primary` にしない
- Google検索スニペットだけで確定しない
- 「たぶん」「一般にそう言われる」で日付を埋めない
- 既存verifiedデータを出典なしで上書きしない
