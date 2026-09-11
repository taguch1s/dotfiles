---
name: implementation-cycle
description: Goal、Done、Non-goalsとレビュー可能なUnitを固定し、Implement・Review・Judge・Recordの最大3回ループで設計済み実装を完了へ収束させる。自律実装、Unit実装、レビュー修正、Issueのend-to-end実装に使う。
---

# Implementation Cycle

設計済みの依頼を、独立検証できる論理 Unit へ変換し、全体の Done まで進める。commit はユーザーが明示的に依頼した場合だけ行う。

## Inputs and Canonical State

- Issue-driven: 親 Issue と現在の要求に同期した Accepted design artifact
- Direct request: ユーザーの明示要求と、合意済み plan または Git 管理外 handoff
- Repository constraints: `AGENTS.md` と参照先 docs

Issue-driven で要求が曖昧なら `issue-design-loop`、実装設計が不足するなら `issue-design-cycle` へ戻す。直接依頼では、ユーザーの要求を増やさず canonical plan の Goal / Done / Non-goals、変更境界、検証を補う。test pattern は `issue-tdd-implement`、責務境界は `issue-layer-implement`、独立 Review は `adversarial-review`、許可済み commit は `git-commit` を使う。

## Goal, Done, Non-goals, Unit

開始前に次を明文化する。

- **Goal**: 誰にどの観測可能な価値を届けるか。
- **Done**: どの behavior と check で達成を判定するか。
- **Non-goals**: 変更しない領域と proposal。
- **Unit**: Done の一部に対応する1責務の変更単位。

Unit は scope / non-scope、変更候補、Requirement / Decision ID、focused check を持ち、単独で実装・検証・取り消し可能にする。ファイルが小さいだけで分けず、複数責務を混ぜない。

Issue-driven の実行経路は Fast / Compact / Full とする。Fast は Full 必須境界がない既知パターンの1 Unit、Compact は契約が固定済みで Fast 条件を満たさない変更、Full は公開 contract、永続 data、外部 service、未確定要件を含む変更である。Full は Accepted design artifact、Compact は親 Issue の reviewed planning note、Fast は Issue 内 execution brief を正本にする。どの経路でも focused verification、Red / Green / Refactor、Review、Judge を省略しない。

## Preconditions

```bash
pwd
git status --short --branch
git worktree list
git remote -v
git branch -vv
```

upstream の鮮度が必要な場合だけ `git fetch --prune` を行う。自動で merge、rebase、pull しない。

確認事項:

- task に適した checkout / worktree である。
- 既存差分の所有者と今回の scope を分離できる。
- 必須 command と環境が利用できる。
- 外部更新、dependency、不可逆操作の権限が明確である。

既存差分があっても今回の path と安全に分離できるなら進める。上書きや誤 commit の危険がある場合だけ停止する。

## Unit Ledger

会話だけを正本にしない。Issue、PR、または `git rev-parse --git-path codex-handoffs` 配下の task handoff に次を保存する。小規模で1 turnに完結する変更では新規 handoff を作らなくてよい。

```markdown
## Cycle Goal
- Goal:
- Done:
- Non-goals:

| Unit | Doneへの寄与 | Scope / Non-scope | Focused check | Owner | Status | Attempts |
| --- | --- | --- | --- | --- | --- | --- |

### Findings
| Unit | Finding / evidence | Severity | Decision | Reason / follow-up |
| --- | --- | --- | --- | --- |

### Formal Trace
| Requirement ID | Artifact / theorem ID | Proof / freshness | Canonical adapter | Conformance Red | Runtime or integration observation |
| --- | --- | --- | --- | --- | --- |
```

Status は `Ready`、`Implementing`、`Reviewing`、`Fixing`、`Accepted`、`Recorded`、`Blocked` を使う。

## Role-separated Cycle

各 Unit を順番に処理する。

1. **Implement**
   - `issue-tdd-implement` の test pattern から Red → Green → Refactor を行う。
   - scope 内だけを変更し、focused check を実行する。
2. **Review**
   - Goal / Done、Unit scope、diff、実行 command と結果だけを `adversarial-review` に渡す。
   - Medium / High は成果物を作った履歴を渡さない fresh Reviewer を使う。
3. **Judge**
   - 全 finding を `Accept`、`Found to Fix`、`Reject with Reason` に分類する。
   - 判定へ影響する Unverified Claim と Review Process Gap も終了判断する。
4. **Record**
   - commit 許可がある場合は `git-commit` で1責務を記録する。
   - 許可がない場合は Unit を `Accepted` とし、diff と検証結果を completion report の対象にする。

Review 前に focused check が成功していなければ Implement へ戻す。未修正の `Accept`、未分類 finding、理由のない Reject がある間は Unit を Accepted にしない。

## Risk and Independence

- **Low**: 局所的・既知・容易に可逆。同一 agent の工程分離を許すが `Independence: degraded` と記録する。
- **Medium**: 複数 file、契約変更、複数案。fresh Reviewer を使う。
- **High**: 広い変更半径、migration、security、privacy、本番影響。実装前の計画合意と deep review を必須にする。

Subagent は独立した読み取り調査と Review に使う。同じ file の並行編集は行わない。

## Loop Limit

Implement → Review → Judge を1 attempt とし、1 Unit 最大3回。3回で収束しない場合は `Blocked` とし、finding、試行履歴、選択肢、影響、推奨案を提示する。無断で4回目へ進まない。

## Completion Gate

全 Unit 後に次を確認する。

- Goal と各 Done を最終 behavior / check へ再マッピングした結果
- Unit 間 contract、data flow、error handling の横断 Review
- `docs/operations/development-flow.md` に基づく test、check、build、manual verification
- formalizable row ごとの proof / freshness、canonical adapter、conformance、runtime test または integration observation
- 変更全体への `adversarial-review`
- 未実行 check と理由、残存 risk
- commit 許可時は commit 一覧、未許可時は意図した diff と既存差分の分離

全体 finding の修正は新しい Unit として通常 cycle へ通す。Done を確認するまで完了と報告しない。

## External Delivery

push / PR 更新が依頼範囲なら、親 Issue と PR を closing keyword で結び、push 後に双方を再取得する。unmerged で全 acceptance criteria を満たす `Closes #<issue>` PR は `open_expected` として Issue を Open に保つ。default branch merge 後に GitHub が Issue を close したときだけ `closed_confirmed` とする。部分対応は `Refs #<issue>` と残作業を記録し、Issue state の直接変更を完了根拠にしない。

## Stop and Ask

- Goal / Done / priority に複数の妥当な解釈がある。
- Non-goal へ広げなければ Done を満たせない。
- canonical artifact と repo facts が矛盾する。
- 既存差分を安全に分離できない。
- dependency、不可逆操作、外部権限、追加コストが必要。
- security、privacy、本番影響に人の判断が必要。
- 必須 check を実行できない、または3 attemptで収束しない。

停止時は確認済み事実、試したこと、選択肢と影響、推奨を示す。

## Completion Report

- Goal / Done と完了 Unit
- Unit ごとの attempt、主要 finding、Judge decision
- 変更 file と、許可時のみ commit hash / 件名
- 実行 command と結果
- 未実行項目と理由
- 残存 risk と manual follow-up
- Issue / PR URL、closing reference、read-back 結果、delivery status
