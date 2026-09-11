---
name: adversarial-review
description: コード差分、設計、調査結果を独立した懐疑的レビューで反証し、repository facts・実行結果・一次情報で再検証した指摘だけを返す。敵対的レビュー、独立レビュー、実装完了判定の検証に使う。
---

# Adversarial Review

成果物に欠陥があるという仮説から検証し、再検証に耐えた finding だけを返す。指摘数や好みではなく、要求違反と観測可能な影響を扱う。

## Contract

次を満たす。

1. Artifact、rubric、既存レビューコメントを混ぜずに記録する。
2. 中リスク以上では、成果物を作った会話履歴を渡さない fresh context の Reviewer を使う。
3. repository、テスト、実データ、公式一次情報で candidate を確かめる。
4. finding に severity、confidence、到達経路または再現条件、根拠、scope を付ける。

低リスクまたは独立 Reviewer を利用できない場合は同一 agent が工程を分けてよいが、`Independence: degraded` と理由を明記する。

## Procedure

1. Goal、Done、Non-goals と対象 diff / file / design を確認する。
2. 要求の更新順を確認し、古い要求が明示的に置換されていないか調べる。
3. 次の観点ごとに失敗条件を作る。
   - 要求・契約の欠落
   - empty、zero、最大値、重複、順序、型境界
   - error、timeout、partial failure、retry、rollback
   - state、fixture、cleanup、並行実行
   - 外部接続、permission、service degradation
   - assertion 不足、mock 過多、未到達 branch
   - 既存契約の回帰、scope 外変更
4. 各 candidate を実装経路と focused check で再検証する。
5. 到達不能、既存防御で防止済み、style の好み、根拠が一般論だけ、重複、Low confidence の candidate を棄却する。
6. 確認不能な事実は finding と断定せず `Unverified Claims` に分ける。
7. レビュー工程自体の不足は `Review Process Gaps` に分ける。

## Classification

- `High`: Goal、主要結論、data integrity、security、privacy、運用継続性を覆す。
- `Medium`: Done 前に修正が必要な correctness または要求違反。
- `Low`: correctness または明示要求へ影響する軽微な問題。好みは含めない。
- `High confidence`: 再現済み、または一次情報と到達可能な経路で確定。
- `Medium confidence`: 強い根拠があるが環境制約で完全再現できない。
- `Low confidence`: finding にせず未確認事項へ回す。

## Output

```markdown
## Adversarial Review

### Review Context
- Profile: focused / deep
- Independence: fresh / degraded（理由）
- Artifact:
- Rubric:
- Review inputs:

### Verification Matrix
| 観点 | 反証仮説 | 検証手順 / command / source | 結果または非該当理由 |
| --- | --- | --- | --- |

### Findings
| ID | Severity / Confidence | Scope | 概要 | 到達経路・再現条件 | 根拠 | 推奨 |
| --- | --- | --- | --- | --- | --- | --- |

### Unverified Claims
| ID | 未確認事項 | 理由 | 確認方法 | 判定への影響 |
| --- | --- | --- | --- | --- |

### Review Process Gaps
| ID | 不足 | 根拠 | 更新先 |
| --- | --- | --- | --- |

### 反証を試みたが壊せなかった点
...
```

finding が0件でも Verification Matrix と未確認事項を省略しない。

## Boundaries

- Accept / Reject、Go / No-Go の最終判定は Judge に委ねる。
- production code、設計、commit、PR thread を変更しない。
- 外部更新を伴う検証は、ユーザーが許可した範囲だけで行う。
