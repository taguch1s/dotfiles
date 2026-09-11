---
name: issue-design-loop
description: 粗い依頼、調査結果、レビュー指摘をrepository factsに接地し、実装可能なGitHub Issueまたはready-to-paste本文へ変える。Issue設計、要件の壁打ち、受け入れ条件、sub-issue分割を依頼された場合に使う。
---

# Issue Design Loop

実装者が会話履歴を読まずに着手できる Issue を作る。既存 Issue の実装設計は `issue-design-cycle` に渡し、production code は変更しない。

## Workflow

1. `AGENTS.md`、関連 docs、実装 entrypoint、近接 test を先に確認する。
2. 要件候補を次に分類する。
   - `user-required`: ユーザーの明示要件
   - `repo-required`: 既存実装・規約から必須
   - `proposal`: 追加提案。合意前に受け入れ条件へ入れない
3. scope、観測可能な挙動、リスクを大きく変える点だけ質問する。回答可能な repository facts を質問しない。
4. 各受け入れ条件を要求または確認済み制約へ対応付ける。
5. 各要求を `formalizable`、`executable-schema`、`integration-only`、`prose-only` に分類し、理由を記録する。pure invariant を modelling convenience だけで downgrade しない。
6. 独立した振る舞い境界がある場合だけ sub-issue に分ける。ファイル単位の細分化はしない。

## Issue Body

次を含める。

- `目的`
- `背景 / 現状`（確認済み事実と evidence）
- `対象`
- `Non-goals`
- `要求トレーサビリティ`（user-required / repo-required / proposal）
- `要求分類`（formalizable / executable-schema / integration-only / prose-only と理由）
- `実装タスク`
- `受け入れ条件`（観測可能な表現）
- `確認方法`（対象 test / check / manual verification）
- `注意点 / 未決事項`

既知なら具体的な package、file、command、API、data flow を書く。「改善する」「堅牢にする」だけの条件は使わない。

## Repository-aligned Split

この monorepo では必要な境界だけを使う。

- domain / simulation: `packages/backtest-core/`
- market data contract / parser: `packages/market-data/`
- presentation: `apps/web/`
- data conversion / operations: `scripts/`、`data/`、`docs/`
- integration / review: package 間契約、回帰確認、CI、文書

新しい package、script、cache、flag、data format を提案する前に既存経路との差と新しい責務を示す。同じ振る舞いの重複なら追加しない。

## Output and Authorization

- 「設計」だけなら ready-to-paste の title / body と推奨 split を返す。
- GitHub Issue の作成・更新はユーザーが明示的に依頼した場合だけ行う。
- 作成時は利用可能な GitHub issue 作成 skill を使い、作成件数、number、URL、state、親子関係を確認する。
