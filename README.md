# Slot Birthday Context DB

スロット機種と版権キャラクターの誕生日を、**出典つき・検証状態つき**で保持するための小さなデータリポジトリです。

## 目的

- 「今日誕生日のスロキャラ」を即検索する
- 「今月の主人公誕生日」を抽出する
- 1キャラが複数機種に登場しても重複管理しない
- 誕生日が不明なキャラを推測で埋めない
- Claude Code / Codex / 通常のPythonから同じデータを扱う

## 初期カタログ

2026-08-23時点で、現行・直近導入・継続的に文脈上重要な機種を**100機種**、手作業で初期カタログ化しています。
これは第三者サイトのランキング転載ではなく、誕生日DBを育てるための「調査優先カタログ」です。

## データ構造

- `data/machines.csv` — 機種
- `data/characters.csv` — キャラと誕生日
- `data/machine_characters.csv` — 機種⇔キャラ対応
- `data/sources.csv` — 誕生日の出典
- `data/events.csv` — ジャグラーの日等。**キャラ誕生日とは別管理**
- `data/aliases.csv` — SAO/ヴヴヴ/カバネリ2等の通称
- `context/slot_birthdays.json` — AI/プログラム向け生成済みコンテキスト
- `context/slot_birthdays.md` — AIが読みやすい生成済みMarkdown

## 信頼度

`birthday_status`:

- `verified_primary` — 作品公式、権利元、メーカー等の一次情報
- `verified_secondary` — パチスロ専門DB等の二次情報で確認
- `unknown` — 未確認。**日付を推測しない**

通常検索は `verified_*` だけを返します。

## 使い方

```bash
python3 scripts/validate_data.py
python3 scripts/query_birthdays.py stats

# 今日（Asia/Tokyo）
python3 scripts/query_birthdays.py today

# 10月7日
python3 scripts/query_birthdays.py date 10-07

# 10月全部
python3 scripts/query_birthdays.py month 10

# 7日以内
python3 scripts/query_birthdays.py upcoming --days 7

# 機種名/版権名検索
python3 scripts/query_birthdays.py machine 東京喰種
python3 scripts/query_birthdays.py machine SAO  # aliases.csvで通称対応

# 主人公だけ
python3 scripts/query_birthdays.py --protagonists-only month 10

# 未確認も見たい
python3 scripts/query_birthdays.py --all-statuses machine からくり

# JSON
python3 scripts/query_birthdays.py --json date 12-20
```

## 朝の共有レポート

`scripts/morning_report.py` は「今日の誕生日 + 今後N日」を1つにまとめて出します。
毎朝の定期通知に流すことを想定した出力です。

```bash
python3 scripts/morning_report.py              # 今日 + 今後7日
python3 scripts/morning_report.py --days 14
python3 scripts/morning_report.py --protagonists-only
python3 scripts/morning_report.py --json
```

**該当が0件のときは何も出力しません。** 呼び出し側はこれを見て通知自体を抑止できます。
`--always` を付けると「該当なし」と明示します。

verified誕生日は年365日のうち96日（26%）にしか該当しないため、「今日だけ」だと
4日に3日は空振りします。7日窓にすると347日（95%）で何かが出ます。

## テスト

```bash
python3 -m unittest discover -s tests
```

## Claude Code

リポジトリ直下でClaude Codeを起動してください。`CLAUDE.md`に運用ルールがあります。

例:

```text
今日誕生日のキャラで、対応するスロット機種を出して
10月に主人公が誕生日を迎える機種だけ出して
東京喰種のキャラ情報を確認して
未確認誕生日のうち、優先度が高いものを洗い出して
```

## 更新フロー

1. キャラと版権の関係を確認
2. 一次ソースを優先して誕生日を確認
3. `data/sources.csv` に出典を追加
4. `data/characters.csv` の日付/status/sourceを更新
5. 必要なら `data/machine_characters.csv` に対応を追加
6. `python3 scripts/validate_data.py`
7. `python3 scripts/export_context.py`
8. 変更をcommit

## 重要

- 「記念日」「メーカーの日」「導入日」をキャラ誕生日に混ぜない
- 公式に誕生日設定が見つからなければ `unknown` のまま
- 同姓同名や作品違いは `franchise` で分離
- 日付形式は必ず `MM-DD`
- 2月29日は許可
