---
name: session-handoff
description: 作業状態を Git 管理外のhandoffへ圧縮し、別セッションが会話履歴なしで安全に再開できる状態を残す。
---

# Session Handoff

handoff は要求・設計の正本ではない。親 Issue、Accepted design artifact、PR、Git diff、remote state を優先し、矛盾は `Open questions / blockers` に記録する。

## 70,000 input-token 運用閾値

これは Codex / プラットフォームの自動 compact 閾値を変更する機能ではない。Herdr status が報告する最新の `input_tokens` に基づく、手動の安全な handoff 規約である。

- Unit 完了の直前、長時間の test / build / 調査 / 外部操作の直前、commit・push・PR 操作の直前に最新値を確認する。
- `input_tokens >= 70_000` のとき handoff を始める。値が取れない、欠けている、数値でないときは閾値未満として扱い、推測で handoff や session 切替を行わない。
- 到達後は新しい作業 Unit を始めない。進行中の atomic operation（test、commit、push など）は安全に完結させる。完結できなければ、実行済み command、結果、残った安全な次の action を handoff に記録する。
- handoff を保存したら、最終報告に次セッションの再開 prompt をそのまま示す。最終報告を返すことや現在の session を終了することは session 切替ではない。
- ユーザーが当該 task について 70k 到達時の fresh continuation（新規 top-level tab）を明示的に許可している場合だけ、既存の Herdr preflight を再実行し、`herdr-codex-orchestrate --new-top-level --cwd "$PWD" "<handoff の Next-session prompt>"` で新しい Codex session を起動する。launcher が返した tab ID / main agent 名を handoff に記録し、`herdr tab get <tab-id>` と Herdr status から main agent の `agent_session.value` を再取得する。その ID が起動元と異なる非空値であることを確認して初めて fresh continuation とする。確認前に旧 session を終了・継続済み報告してはならない。
- 明示許可がない場合、handoff は Herdr の tab / pane 作成・終了や session 切替を許可しない。handoff と prompt を提示して現在の session を終了し、次の起動はユーザーの指示を待つ。UI 操作は `AGENTS.md` の Herdr 規約に従う。

開始時に `AGENTS.md`、対象 Issue / PR、既存 handoff を読み、次を再取得する。

```bash
pwd
git status -sb
git worktree list
git branch --show-current
git diff --stat
```

保存先は `git rev-parse --git-path codex-handoffs` 配下の `<task-slug>.md` とする。tracked `docs/` や session ごとの新規ファイルは使わず、1 file 50 KiB 未満を目安に同じ handoff を更新する。

## workflow-progress/v1

Issue 起点の作業では、同じ handoff に `workflow-progress/v1` の JSON block をちょうど一つ置く。これは handoff を正本へ昇格させず、現在の Unit、local review evidence、次の安全な action、remote sync の pending を再開時に判別できるようにする進捗証跡である。

````markdown
<!-- workflow-progress/v1:start -->
```json
{
  "version": "workflow-progress/v1",
  "issue": {"repository": "OWNER/REPO", "number": 123, "url": "https://github.com/OWNER/REPO/issues/123"},
  "git": {"branch": "feature/issue-123-example", "head": "<40-lowercase-hex-sha>"},
  "current_unit": {"id": "U1", "status": "in_progress", "next_action": "…"},
  "units": [{"id": "U1", "status": "in_progress", "required_for_delivery": true, "review": {"kind": "light", "outcome": "pending", "independence": "fresh", "degraded_reason": null, "reviewed_head": null, "evidence": []}}],
  "final_review": {"kind": "full", "outcome": "pending", "independence": "fresh", "reviewed_head": null, "evidence": []},
  "remote_sync": {"status": "pending", "pending_actions": ["…"]},
  "delivery": {"intent": "none", "state": "not_requested", "pr_url": null, "read_back_evidence": [], "pause_reason": null}
}
```
<!-- workflow-progress/v1:end -->
````

Required invariants are a nonempty unique `units` array; exactly one Unit whose `id` equals `current_unit.id` and whose status equals `current_unit.status`; and at least one Unit with `required_for_delivery=true`. `status` is `planned|in_progress|blocked|accepted`; review `outcome` is `pass|fail|pending`; `independence` is `fresh|degraded`; `remote_sync.status` is `pending|posted|not_applicable`; and `delivery.intent` is `none|commit|pr` with `delivery.state` in `not_requested|in_progress|pr_read_back_pass|blocked|paused`. A degraded review records a nonblank `degraded_reason`.

Each passing required Unit review has `kind=light`, `outcome=pass`, `reviewed_head` equal to the reviewed Git HEAD, and exactly one evidence item. Each passing final review has `kind=full`, `outcome=pass`, `independence=fresh`, `reviewed_head` equal to delivery HEAD, and exactly one evidence item. Evidence is a same-handoff locator, not a URL or arbitrary file path:

For `delivery.intent=pr`, pre-PR `state=in_progress` is valid so the local review gate can run before creation. Terminal states are exactly `pr_read_back_pass|blocked|paused`, and every terminal state requires an empty `current_unit.next_action`. Only `pr_read_back_pass` requires a nonempty `pr_url` and exactly one `read_back_evidence` item resolving to a same-handoff `kind=delivery` marker immediately followed by `### PR read-back evidence: …`; `paused` requires `pause_reason=user_instruction`. These delivery fields record evidence and do not authorize a new review, pane, tab, or agent.

````markdown
<!-- workflow-review-section/v1 id="workflow-review-unit-U1" unit="U1" kind="light" reviewed_head="<40-lowercase-hex-sha>" -->
### Review evidence: Unit U1

<!-- workflow-review-section/v1 id="workflow-review-final" kind="full" reviewed_head="<40-lowercase-hex-sha>" -->
### Review evidence: Final delivery
````

The Unit evidence item is `{"locator":"workflow-review-unit-U1","summary":"…"}`; its unique marker must name that Unit, `kind=light`, matching head, and be immediately followed by `### Review evidence: Unit U1`. The final item uses only `workflow-review-final`, with no `unit`, `kind=full`, matching head, and immediately followed by `### Review evidence: Final delivery`. Invalid, duplicated, unrelated, wrong-kind, wrong-Unit, or wrong-head locators are not review evidence.

Update this one handoff at session start, after every Unit commit/review, before long-running work, and before push/PR. Keep `remote_sync.status=pending` with an explicit next action until an authorized post-push Issue/PR marker and concise summary have been posted; remote sync never becomes a local-gate prerequisite.

```markdown
# Handoff: <task title>

- Repository / worktree:
- Branch:
- Parent Issue / design artifact / PR:

## Goal / Done / Non-goals
## Canonical references
## Completed units / commits / checks
## Confirmed decisions / rejected proposals
## Worktree / branch / current diff
## Current unit and exact next action
## Open questions / blockers / residual risks
## Next-session prompt
```

生ログ、長い diff、secret、token、個人情報は残さない。次セッション用 prompt には絶対 worktree path、handoff path、親 Issue / PR、最初に読む正本、最初の状態確認 command、現在 Unit の exact next action、停止条件を含める。保存後に path、Issue / PR、branch、commit、check 結果を実データと照合する。
