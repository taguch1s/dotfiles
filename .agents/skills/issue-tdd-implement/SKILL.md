---
name: issue-tdd-implement
description: Accepted design artifactまたは合意済み実装planからtest patternを先に設計し、Red・Green・Refactorで実装する。TDD、回帰test追加、実装前test計画、test先行実装を依頼された場合に使う。
---

# Issue TDD Implement

設計判断を observable test pattern へ変換し、production code より先に失敗を確認する。GitHub Issue は必須ではない。

## Preconditions

- Issue-driven では親 Issue と現在の親 snapshot に一致する Accepted design artifact を読む。
- 直接依頼では、ユーザーの明示要求と、Goal / Done / Non-goals・変更境界・検証を含む合意済み plan または Git 管理外 handoff を正本として読む。
- `AGENTS.md`、関連 docs、近接 test を読む。
- `pwd`、`git status -sb`、`git worktree list` で専用 checkout と既存差分を確認する。
- Issue-driven artifact が missing、stale、未レビュー、要求トレーサビリティ不足なら `issue-design-cycle` へ戻す。直接依頼の plan が実装判断に不足する場合は、production code を変更せず不足する設計だけを補う。
- package 依存追加、外部更新、不可逆操作は承認前に行わない。

## Test Pattern Plan

production code を編集する前に次を記録する。

- 観測する振る舞い
- Requirement / Done ID と Design Decision ID。直接依頼に ID がなければ plan 内で安定した ID を付ける。
- positive、negative、boundary、regression case
- test level: unit / package contract / integration / manual
- 追加・変更する test file
- mock / fake の境界と、実実装で確認すべき境界
- 最小の実行 command
- Red で期待する failure signal
- 対応する implementation layer

formalizable row では production code 前に conformance Red を追加し、proof / freshness、canonical adapter、Requirement ID 対応 runtime test を test pattern に含める。proof が通ることだけを runtime conformance としない。

リポジトリの package scripts、test runner、workspace 構成を確認して最小 command を選ぶ。script 名、package 名、test path を記憶で決めず、現在の `package.json` と `AGENTS.md` を確認する。

## Red → Green → Refactor

1. 次の layer と test pattern を1つ選ぶ。
2. focused test を先に追加し、意図した理由で失敗することを確認する。
3. その test を通す最小の production change を実装する。
4. focused test を再実行する。
5. passing behavior を保って naming、duplication、placement を整理する。
6. layer の check と、変更半径に応じた repository-defined check を実行する。

test が最初から成功した場合、既存 behavior が要求を満たすか、assertion が不足しているかを確認してから実装判断を更新する。自動 test が不適切な UI 表示などは、理由と具体的な manual verification を先に記録する。

設計判断と矛盾する事実が見つかった場合は production code を進めない。Issue-driven なら `issue-design-cycle`、直接依頼なら canonical plan の設計工程へ戻す。test pattern または layer split だけが変わる場合は、その計画を更新して続行する。

## Report

- 使用した Requirement / Decision 対応付き test pattern plan
- Red の command と実際の failure
- Green / Refactor の command と結果
- 未実行 test と理由
- manual verification と残存 risk
