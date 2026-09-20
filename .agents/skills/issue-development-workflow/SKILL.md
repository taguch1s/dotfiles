---
name: issue-development-workflow
description: GitHub Issueを要求の正本として、設計・TDD・層別実装・review・commit・PR作成を既存Skillへ委譲しつつ、通常の局所変更を根拠のないfindingで止めずに完了へ進める。Issue起点のend-to-end実装、実装フローの一括実行、reviewとcommit判断の統括時に使用する。
---

# Issue Development Workflow

`$issue-development-workflow <Issue URL または番号>` を、Issue 起点の開発フローの一つの入口として使う。親 Issue の要求を実現するために既存 Skill を順に統括するものであり、それらの専門手順を複写・置換しない。

## 正本と開始条件

正本の優先順位は、最新の明示指示、親 Issue の目的・受け入れ条件・非対象・制約、`AGENTS.md` と恒久文書、repository facts、planning artifact、会話の順とする。最新のユーザー仕様判断は Decision Ledger に記録し、以降の設計・review では前提として扱う。同じ選択肢を再度の停止理由として提示しない。

開始時の worktree 確認と作成・再開・切替は `$shared-codex-workflow` へ明示的に委譲する。対象 repository の `AGENTS.md` と追跡された worktree policy を正本として、Git root、branch、worktree list、working-tree status を確認し、同じ worktree を並行編集しない。

この委譲で行う読み取り確認は次のとおりである。

```bash
pwd
git status --short --branch
git worktree list
git remote -v
```

- Issue が曖昧または受け入れ条件を観測できない場合は `$issue-design-loop` に戻す。
- Fast / Compact / Full を、不確実性と変更境界で選ぶ。Full は公開契約、永続データ、認可、主要 UI、外部設定・service、未確定要件を含む場合に使う。Fast は既知パターンの一つの局所 Unit、Compact は契約が固定済みで複数の実装判断を持つ場合に使う。
- Full は `$issue-design-cycle` の Accepted design artifact、Compact は親 Issue の reviewed planning note、Fast は Issue の execution brief を使う。適切な artifact がない場合、production code を変更しない。
- `$issue-tdd-implement` で test pattern と Red / Green / Refactor を、`$issue-layer-implement` で必要な layer だけを決める。Fast でも focused verification を省略しない。
- 通常の commit 単体は `$git-commit` の直接呼び出しを明示許可として扱い、push は含めない。PR 作成を明示依頼された場合は、その delivery に必要な commit、push、PR 作成、read-back までを一体の範囲として実行する。これ以外の外部操作、Issue 更新、外部設定変更は依頼範囲だけに限る。GitHub 上の Issue を読む権限と更新権限を混同しない。

## 実行モード

通常モードを既定にする。局所的で可逆な変更、既知の実装パターン、明確な受け入れ条件は通常モードで進める。設計の Full 経路であっても、次の厳格モード条件がなければ機械的に厳格化しない。

厳格モードは、security / privacy、不可逆操作、production data・設定への影響、migration、権限拡大、またはユーザーが明示した場合だけ使う。厳格モードでは追加の独立検証、承認、rollback / rollout の確認を、実際のリスクに対応する範囲で要求する。手続き、fixture の拡張、review 回数自体を厳格化の理由にしない。

## 通常モードの Unit

1. Goal、Done、Non-goals、対象 Unit、focused check を Issue / planning artifact に対応付ける。
2. `$issue-tdd-implement` と必要な `$issue-layer-implement` に従って、最小の変更を実装し focused check を実行する。
3. `$adversarial-review` に、Goal / Done、Unit scope、diff、実行 command と結果を渡して light review する。中リスク以上は fresh reviewer を使う。低リスクで利用できない場合だけ `Independence: degraded` と理由を記録する。
4. `$session-handoff` の同じ handoff を更新し、`workflow-progress/v1` に accepted Unit の `kind=light` review、reviewed HEAD、independence、evidence locator、current Unit、next safe action を記録する。passing evidence は同一 handoff の `workflow-review-section/v1` marker と直後の Unit heading に結び、任意の URL・ファイルパス・prose を evidence にしない。
5. 下記の分類で Judge する。Blocking がなければ、追加調査、再review、Stop and Ask を挟まず Unit を受け入れる。
6. 通常の commit 単体は `$git-commit` の明示許可がある場合だけ一責務の commit にする。PR 作成が明示依頼されている場合は `$git-commit` と `$pr-description` を使い、必要な commit、push、PR 作成、read-back までを完了させる。

## workflow-progress/v1 と local review gate

Issue 起点の Full / Compact workflow は `$session-handoff` が定める同一 handoff の `workflow-progress/v1` を更新する。Unit review と delivery review を混同しない。

- 各 delivery-required Unit が accepted になる前に `light` review を記録する。`outcome=pass` の review は reviewed HEAD と、`workflow-review-unit-<Unit ID>` の同一-handoff locator を持つ。`degraded` には理由を残す。
- delivery 前には変更全体に対する fresh `full` review を実行し、delivery HEAD と `workflow-review-final` locator を記録する。final review は degraded にしない。
- Unit / final evidence locator は一意で、marker の Unit、kind、reviewed HEAD、直後の見出しが JSON review と一致しなければ evidence として扱わない。
- session start、各 Unit の commit/review 後、長時間処理前、push/PR 前には同じ handoff を更新する。70k token 閾値と continuation の規約は `$session-handoff` を優先し、ここで変更しない。

導入済み repository の通常の `pre-push` は、tracked `.githooks/workflow-progress.toml` の exact `issue_branch` mapping から `git rev-parse --git-path codex-handoffs` 配下の一つの handoff を選び、local validator に渡す。pre-push を選ぶのは、review evidence が remote delivery の直前の delivery HEAD と一致しなければならず、pre-commit はそれより早く最終 HEAD を決定的に gate できないためである。`feature|fix|chore/no-issue/*` は明示的な no-Issue path、その他は exact の理由付き `out_of_scope_branch` だけが non-adoption になる。`feature|fix|chore/issue-<positive-number>-*` で mapping がない場合、および未知 branch は fail closed であり、環境変数や handoff の総当たりで選ばない。validator / hook の実装・導入は対応 Unit が完了するまでこの Skill だけでは行わない。

push 後の AI review marker と短い要約の Issue/PR 投稿は `remote_sync` の後続 action であり、local gate の前提ではない。未投稿なら `pending` と次の action を handoff に残す。`--no-verify` と GitHub UI merge は local hook では防げず、CI / branch protection は本 workflow の non-goal である。

### Review の分類と Judge

reviewer の finding を次のいずれかへ必ず分類する。

| 分類 | 条件 | 現在の Unit への扱い |
| --- | --- | --- |
| Blocking | 受け入れ条件違反の再現、既存契約との直接矛盾、安全ポリシー違反、または実行済み check の失敗があり、到達経路または再現手順と根拠を示せる | scope 内で修正して focused check と必要な review を再実行する |
| Non-blocking note | 将来懸念、一般論、未確認の可能性、style、根拠のない fixture / test 拡張、または現在の Done を妨げない改善 | 残存リスクとして記録するが、commit / PR を止めない |
| Out-of-scope follow-up | 有益だが Issue の Goal、Done、または Unit scope 外 | 追跡先または提案として分離し、現在の Unit を止めない |

`Blocking` には「影響が大きそう」だけでは足りない。根拠が実データ、現在の仕様、既存実装、test 結果、安全ポリシーのいずれかに接地していることを確認する。確認できない候補は `Non-blocking note` または `Unverified Claim` とし、現在の PR を止めない。既決仕様と矛盾する review は Decision Ledger を根拠に reject する。

同じ実装欠陥を修正しても解消できない場合だけ、その Unit の attempt を数える。review 手順の改善、fixture の追加、検証環境の都合、Non-blocking note、Out-of-scope follow-up は attempt を消費せず、再実装の理由にしない。3 回の同一欠陥の修正後も Blocking が残る場合だけ、事実、試行、選択肢、影響、推奨を示して停止する。

Decision Ledger は Issue / PR が更新許可されている場合は対応する canonical artifact に、許可されていない場合は `$session-handoff` の Git 管理外 handoff に残す。

```markdown
| ID | 決定した仕様 / 制約 | 根拠 | 後続reviewでの扱い |
| --- | --- | --- | --- |
| D-1 |                     |      | 前提として扱い、再提案しない |
```

## 完了と delivery

全 Unit 後は `$implementation-cycle` の Completion Gate を使い、Done と実行結果、未実行 check、残存リスクを対応付ける。integration や外部接続の検証は、変更した契約と対象 repository の規約が要求する場合だけ実行する。

全受け入れ条件を evidence で満たす PR だけ `Closes #<issue>` を使う。部分対応は `Refs #<issue>` と残作業を記録し、Issue を直接 close / reopen しない。未merge の qualifying PR は `open_expected`、default branch merge 後も親 Issue が Open の場合は `needs_classification` として read-back 結果を報告する。

## 評価シナリオ

この入口を変更・利用する際は、次の判断を机上で照合する。

| 状況 | 期待する分類 | 理由 |
| --- | --- | --- |
| ユーザーが `30d` を月間 alias と明示決定し、実装と focused test がその決定に一致する | Non-blocking note または Reject with Reason | 別 alias の理論的な併存は、既決仕様を覆す再現根拠にならない |
| 未確認の alias 併存を「将来壊れるかもしれない」とだけ指摘する | Non-blocking note | 現在の受け入れ条件違反、既存契約との矛盾、check 失敗の証拠がない |
| focused test が受け入れ条件と異なる値を返して失敗する | Blocking | 失敗 command、再現条件、要求違反を直接示せる |
| より多い fixture や境界 test を提案するが、現行の Done と check は通っている | Out-of-scope follow-up | 有益な提案でも現在の Unit を止める根拠ではない |
| 同じ再現済みの受け入れ条件違反を3回修正しても解消できない | Blocking / Stop and Ask | 同一実装欠陥が attempt 上限に達し、仕様または方針判断が必要になる |

## Report

完了時は、Issue URL、選択した経路と実行モード、Unit ごとの結果、Decision Ledger の新規項目、Blocking / Non-blocking note / Out-of-scope follow-up の判断、実行 command と結果、未実行 check と理由、残存リスクを返す。commit、push、PR、Issue 更新は実行した場合だけ識別子と read-back 結果を添える。
