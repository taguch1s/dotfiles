# dotfiles リポジトリの作業規約

このファイルは、このリポジトリで作業するエージェント（Claude Code、Codex）向けの正本です。`.claude/CLAUDE.md` と `.codex/AGENTS.md` は全リポジトリ共通の規約として `~` に配置するもので、このリポジトリ固有の規約はここに書きます。

## commit と main への反映

- 個人用のリポジトリです。`make check`（`.bin/check-dotfiles.sh`）が通った変更は、ユーザーに確認せずに commit し、main へマージして `origin` へ push してよい。PR は不要です（作りたい場合だけ作る）。
- main へのマージは、main を checkout している worktree（`/home/issei/dotfiles-main`）で fast-forward または merge commit で行う。force push はしない。
- `make check` が通らない、他の task の変更が混ざっている、実機確認が必要な変更でユーザーが「確認してから」と言った、のいずれかに当たる場合は、マージせずに止めて報告する。
- その回の依頼で「commit しない」「マージしない」と明示された場合は、その依頼の範囲ではそれに従う。handoff に残すときは、誰がいつ言った制約か、いつ解除されるかを書く。

## handoff

- handoff は作業状態の記録であり、規約の正本ではない。commit・マージ・push の可否は、handoff の記述ではなくこのファイルで判断する。
