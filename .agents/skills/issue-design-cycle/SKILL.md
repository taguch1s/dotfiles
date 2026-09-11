---
name: issue-design-cycle
description: 既存の親GitHub Issueを要求の正本とし、実装設計をDraft・独立Review・Judge・Reviseの最大3回で収束させる。設計プラン作成、設計レビュー、設計判断の記録、設計Sub-issue作成・更新を依頼された場合に使う。
---

# Issue Design Cycle

親 Issue の要求を変えず、後続セッションが会話履歴なしで利用できる Accepted design artifact を作る。production code、test、依存関係は変更しない。

Draft / Revise は `issue-implementation-design`、反証は `adversarial-review`、GitHub Sub-issue の作成は利用可能な issue 作成 skill に委ねる。この skill は正本、役割、gate、最大試行回数、永続化を管理する。

## Canonical Hierarchy

1. ユーザーの最新の明示指示
2. 親 Issue の Goal、Acceptance Criteria、Non-goals、制約
3. `AGENTS.md` と恒久 docs
4. 現在の repository facts
5. Accepted design artifact
6. 会話、仮説、未採用 proposal

設計中に要求追加が必要になった場合は推測で補わず、`issue-design-loop` へ戻す。

## Preconditions

- 親 Issue の URL / number、title、body、state、updated_at を確認する。
- `AGENTS.md`、関連 docs、実装 entrypoint、近接 test、worktree 状態を読み取りで確認する。
- 同じ親 Issue の既存設計 artifact を検索し、重複作成しない。
- GitHub への作成・更新は、ユーザーが明示的に依頼した場合だけ行う。

GitHub 更新が許可されない場合は、後続実装が必要なときだけ Git 管理外 handoff に保存する。保存先は `git rev-parse --git-path codex-handoffs` 配下とし、絶対 path を返す。設計本文だけの依頼なら ready-to-paste artifact を返してよい。

## Artifact Contract

```markdown
## Status
- Phase: Draft / Reviewing / Accepted / Blocked
- Parent issue:
- Parent snapshot: <updated_at と title/body digest>
- Cycle: <attempt>/3

## Goal / Acceptance Criteria / Non-goals
## Requirement Traceability
| Requirement ID | Source | Observable condition | Design decision | Validation | Status |
| --- | --- | --- | --- | --- | --- |

## Repository Facts
| Fact | Evidence | Design impact |
| --- | --- | --- |

## Proposed Design
## Decision Log
| ID | Requirement | Decision | Options | Adopted reason / evidence | Rejected reason | Consequences / risks |
| --- | --- | --- | --- | --- | --- | --- |

## Edit Boundaries
## Test Strategy
## Risks / Open Questions / Proposals
## Cycle Ledger
| Attempt | Review evidence | Judge decisions | Revision | Result |
| --- | --- | --- | --- | --- |
```

`formalizable` な row は artifact path、theorem ID、proof command、canonical adapter、conformance Red、Requirement ID に対応する runtime test を Traceability に記録する。Lean proof は親 Issue の要求、migration、integration 観測を置き換えない。

GitHub に保存する場合は、専用 Sub-issue を `[設計] <親Issue title>` として作り、親子関係を確認する。body は親 Issue への参照と `<!-- issue-design-cycle:v1 parent=OWNER/REPO#NUMBER -->` marker を持つ固定 container とし、設計版は full-content comment として追記する。既存 comment を削除・上書きしない。

各設計版 comment は parent digest、phase、attempt を marker に持つ。投稿直前・直後に親 Issue を再取得し、digest が変わった版は stale として採用しない。同じ現在 digest に Accepted 版が既にあれば再利用する。

## Cycle

1. **Designer**
   - `issue-implementation-design` で Draft / Revise を作る。
   - 全 Requirement を設計判断と validation へ対応付ける。
2. **Reviewer**
   - `adversarial-review` を fresh context で使う。
   - Issue fidelity、根拠、責務境界、data flow、失敗経路、testability、scope creep、代替案を反証する。
3. **Judge**
   - 各 finding を `Accept`、`Reject with Reason`、`Return to Parent Issue`、`Proposal`、`Review Process Gap` に分類する。
4. **Recorder**
   - 採用修正、Decision Log、traceability、ledger を一体で永続化する。

Designer と Reviewer を同時に実行しない。Reviewer は設計を編集せず、Designer は Judge が採用した finding だけを反映する。

## Gates

- **Source**: 親 Issue snapshot が最新で、要求を読み替えていない。
- **Traceability**: 全要求が設計判断と validation に対応し、余分な必須要件がない。
- **Evidence**: repo facts と外部仕様が再確認可能な根拠へ接地している。
- **Rationale**: 非自明な判断に現実的な選択肢、採否理由、影響がある。
- **Architecture**: 責務境界、data flow、failure path、既存経路との差が一貫する。
- **Implementability**: edit boundary、test strategy、layer split、risk が後続工程に十分。
- **Review**: actionable な High / Medium finding と判定に影響する未確認事項がない。
- **Persist**: Accepted 版、親 snapshot、cycle ledger の保存先を後続が特定できる。
- **Formal trace**: formalizable row ごとに proof、adapter、conformance、runtime evidence がそろう。

## Limit and Handoff

最大3 attempt。finding が収束し全 gate を通れば早期終了する。3回で収束しなければ `Blocked` とし、未解決事項、試行履歴、選択肢、影響、推奨案を返す。Accepted 時は親 Issue、artifact URL / path、attempt 数、主要判断、checks、残存 risk を報告し、`issue-tdd-implement` へ渡す。
