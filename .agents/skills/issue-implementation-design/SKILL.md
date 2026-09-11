---
name: issue-implementation-design
description: 既存Issueからrepository facts、責務境界、設計判断、編集境界、検証方針を含む実装前設計のDraftを作る。issue-design-cycleのDesigner工程、または未レビューDraftを明示的に依頼された場合に使う。
---

# Issue Implementation Design

既存 Issue を implementation plan に変換する。production code と test は変更しない。標準のレビュー済み設計には `issue-design-cycle` を使い、この skill 単独の出力は `Draft / Unreviewed` と明記する。

## Preconditions

- 親 Issue、`AGENTS.md`、関連 docs、実装 entrypoint、近接 test を読む。
- 各受け入れ条件を `user-required` または `repo-required` に対応付ける。
- 観測不能、矛盾、未合意 proposal が必須化されている場合は `issue-design-loop` に戻す。
- package 依存追加、外部サービス更新、不可逆操作が必要なら、設計案と影響を示して承認前に停止する。

## Design Artifact

次を含める。

1. 対象 Issue と snapshot
2. Goal / Acceptance Criteria / Non-goals
3. Requirement Traceability（安定した Requirement ID、設計判断、validation）
4. Repository Facts（file / line、command、schema 等の evidence）
5. Proposed Design（data flow、interface、責務境界、error handling）
6. Decision Log
   - Decision ID
   - 対応 Requirement ID
   - 現実的な選択肢
   - 採用理由と evidence
   - 却下理由
   - trade-off と residual risk
7. Edit Boundaries（変更候補と変更しない領域）
8. Test Strategy（test level、対象 file、manual check）
9. Layer Split（必要な package / app / script / integration 境界だけ）
10. Risks / Open Questions / Proposals

formalizable な requirement には、formal artifact/path、declaration/theorem ID、proof check、canonical adapter、conformance Red、Requirement ID 対応 runtime test（または integration-only boundary と観測）を明記する。

新しい package、data format、cache、flag、script を選ぶ場合、既存経路では満たせない責務と新たに守る不変条件を記録する。隣接領域の一般化は必須 scope に混ぜない。

## Handoff

- `issue-design-cycle` 内では Draft / Revise artifact を Reviewer と Judge へ返す。
- 単独依頼では `Draft / Unreviewed` を返して停止する。
- Accepted 後は `issue-tdd-implement` が設計判断から test pattern を導出する。
- 実装中に repo facts と設計が矛盾した場合は、設計を無視せず cycle へ戻す。
