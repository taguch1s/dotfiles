---
name: codex-conversation-audit
description: Local Codex conversation logsを匿名集計し、依頼傾向と協働上の摩擦を根拠にAGENTS.mdや開発フローを改善する。Codex会話ログ分析、協働ルール監査、過去sessionに基づくworkflow改善を依頼された場合に使う。
---

# Codex Conversation Audit

会話本文や秘密値を成果物へ複製せず、集計と必要最小限の匿名化した観察から協働ルールを改善する。

## Workflow

1. 対象 repository の `AGENTS.md`、関連 workflow、既存差分を確認する。
2. 次の command で aggregate JSON を作る。

   ```bash
   node .agents/skills/codex-conversation-audit/scripts/audit-logs.mjs --repo "$(pwd)"
   ```

   `--codex-dir <path>` で既定の `~/.codex` 以外を指定できる。script は本文、thread名、ID、URL、log path を出力しない。
3. 数値を事実として整理し、因果や感情は推論として分ける。signal は重複するため合計を母数にしない。
4. 定性確認が必要な signal だけ原logの前後を少量読む。`auth.json`、`.env`、shell snapshot、tool output は監査対象にしない。
5. 生の発言、URL、個人情報、秘密値を repository へ保存しない。
6. 再発防止ルールへ変換する時は、権限境界、根拠のない要件追加、質問への直接回答、複数成果物の完了照合、報告粒度、Subagent境界、計画合意、handoff を確認する。
7. `AGENTS.md` は短い強制ルールと恒久 docs への pointer に留め、既存ルールと矛盾する変更は同時に整合させる。
8. 集計scriptの構文、変更したskill、`git diff --check` を検証する。

## Rule Adoption

- 1回の不満や推測を恒久ルールにしない。複数事例、明示的な好み、重大な失敗のいずれかを根拠にする。
- 個別bugの直し方ではなく、依頼解釈、権限、検証、報告に再利用できる規則を書く。
- 新しい工程は、減らせる摩擦と増える運用コストを比較してから追加する。
- 報告には対象期間・件数、主要傾向、変更規則、検証結果を含める。
