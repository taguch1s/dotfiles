---
name: git-commit
description: 作業ツリーと index の差分から今回の依頼に属する変更だけを責務ごとに整理し、日本語メッセージで安全に commit する。commit、変更の記録、PR作成前のcommitを依頼された場合に使う。
---

# Git Commit

今回の依頼に属する差分だけを、レビュー可能な責務単位で commit する。この skill の直接呼び出しは commit の明示許可として扱うが、push は含まない。

## Safety

- staged、unstaged、untracked をすべて確認する。
- ユーザーの無関係な差分を stage、復元、削除、commit しない。
- secret、credential、`.env`、意図しない生成物を含めない。
- `git add .`、`git add -A`、`--no-verify`、`--amend`、force push を使わない。
- hook 失敗時は迂回せず停止する。
- 「案だけ」「commit しない」と指定された場合は変更を記録しない。

## Workflow

1. 状態と全差分を確認する。

   ```bash
   git status --short
   git diff --stat
   git diff --cached --stat
   git diff
   git diff --cached
   git ls-files --others --exclude-standard
   ```

2. 会話上の依頼と差分を照合し、1責務として説明できる commit 単位へ分ける。
   - 同じ振る舞いの実装・テスト・文書は一体なら同じ commit でよい。
   - 独立して説明できる機能、修正、refactor、設定は分ける。
   - 1ファイルに複数責務が混在し、安全に patch staging できなければ停止して報告する。

3. untracked file は対象パスだけを追加する。

   ```bash
   git add -- <対象ファイル...>
   ```

   既存 staged 差分は勝手に解除せず、commit 時に `--only` と対象パスを使う。

4. commit 直前に対象だけを確認する。

   ```bash
   git diff HEAD --stat -- <対象ファイル...>
   git diff HEAD -- <対象ファイル...>
   git diff --check HEAD -- <対象ファイル...>
   ```

5. 日本語メッセージを作る。

   ```text
   <type>(<scope>): <変更内容の日本語要約>
   ```

   `type` は `feat`、`fix`、`refactor`、`test`、`docs`、`style`、`chore`、`perf` から実態に合うものを選ぶ。件名だけで意図が伝わらない場合は、確認済みの理由と主要差分を body に書く。

6. 対象パスを限定して commit する。

   ```bash
   git commit --only -m "<日本語の件名>" -- <対象ファイル...>
   ```

7. 全 commit と残差分を確認する。

   ```bash
   git status --short
   git log --oneline --decorate -n <作成数>
   ```

## Report

- commit hash と件名
- commit ごとの責務と対象 paths
- 実行した check と結果
- 残った差分と含めなかった理由
- push は未実行であること
