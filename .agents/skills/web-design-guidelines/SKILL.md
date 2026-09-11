---
name: web-design-guidelines
description: Web UI codeを最新のWeb Interface Guidelinesに照らしてaccessibility、interaction、visual UXの問題をfile:lineで監査する。UI review、accessibility check、design audit、UX reviewを依頼された場合に使う。
metadata:
  author: vercel
  version: "1.0.0"
  argument-hint: <file-or-pattern>
---

# Web Interface Guidelines

## Workflow

1. 次の一次ソースから最新 guidelines を取得する。

   ```text
   https://raw.githubusercontent.com/vercel-labs/web-interface-guidelines/main/command.md
   ```

   internet access が利用できない場合は、古い記憶で代用せず未確認と報告する。
2. ユーザー指定の file / pattern を読む。未指定なら repository から対象 UI entrypoint を調べ、範囲が一意なら進める。結果を大きく変える場合だけ質問する。
3. 取得した guideline の全 rule を対象へ適用する。
4. guideline が指定する terse な `file:line` format で finding を返す。

レビュー依頼は読み取りと報告までとし、明示されていない UI 編集は行わない。
