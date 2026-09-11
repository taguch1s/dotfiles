---
name: issue-layer-implement
description: Accepted design artifactまたは合意済みplanとtest patternを、このpnpm monorepoのpackage・app・script・integration境界に沿う実装Unitへ分けて順に実装する。層別実装、特定layerの実装、実装分割に使う。
---

# Issue Layer Implement

必要な責務境界だけを選び、各 layer を test pattern と対応付けて順番に実装する。対称性のための空 layer や抽象化は作らない。

## Layers

- **market data**: `packages/market-data/` の型、validation、parse/load contract
- **simulation domain**: `packages/backtest-core/` の約定、注文、口座、集計ロジック
- **presentation**: `apps/web/` の表示、browser interaction、loading/empty/error state
- **conversion / operations**: `scripts/`、入力形式変換、再現可能な sample / docs
- **integration**: package 間 contract、end-to-end data flow、CI、manual verification

Issue に関係しない layer は省く。共有化は複数の既存 caller を確認してから行う。

## Workflow

1. Issue-driven では親 Issue と Accepted design artifact、直接依頼ではユーザー要求と合意済み plan / handoff を読み、各 layer を Requirement / Done ID と Decision ID へ対応付ける。
2. 外側の entrypoint から依存先をたどり、現行 data flow と近接 test を確認する。
3. `issue-tdd-implement` の test pattern plan から、依存順の layer plan を作る。
4. 各 layer で production code より先に focused test の Red を確認する。自動化できない場合は理由と manual check を先に書く。
5. 1 layer ずつ実装し、focused check を実行する。
6. 新しい layer が必要、または不要と判明したら plan を更新する。canonical design decision が変わる場合、Issue-driven では `issue-design-cycle`、直接依頼では canonical plan の設計工程へ戻す。

formalizable requirement は、formal artifact と adapter / runtime conformance を別 layer として追跡する。proof だけで runtime behavior を完了にしない。

## Boundaries

- `packages/backtest-core` は UI と provider 固有入力形式に依存させない。
- `packages/market-data` は simulation policy を持たない。
- `apps/web` は domain behavior を重複実装しない。
- `scripts/market-data` は変換 orchestration を担い、canonical domain type は package へ置く。
- application 側で大規模 data の sort / filter を追加せず、既存 data flow と性能影響を確認する。
- `.env`、実 market data、dependency は明示許可なしに変更しない。

ユーザーが特定 layer だけを依頼した場合はその scope だけを実行する。Issue 全体なら layer plan を示した後、依存順に停止せず進める。
