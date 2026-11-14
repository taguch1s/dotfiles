# herdr-core で Claude Code を指揮する

Herdr app（GUI）とスマホアプリの実行基盤である herdr-core（`hc`）で、オーケストレーター役の Claude Code 1 つがワーカー役の Claude Code を起動し、ワーカーの権限確認もまとめて判断する構成です。

TUI 版 `herdr` と herdr-core は別の実行基盤です。TUI で起動したエージェントは Herdr app にもスマホにも表示されません。既存の `herdr-codex-orchestrate`（TUI 用）はそのまま残しています。

## 仕組み

```
あなた（PC の Herdr app / スマホの Herdr アプリ / ssh + hc attach）
  │ hc-orch <repo> "<指示>"、エスカレーションへの回答
  ▼
orch-<repo>: claude-orchestrator（hc terminal）
  │ hc run --bg … claude-worker "Issue #12 …"      ▲ <hc>t3 issue-12 is blocked (permission)…</hc>
  ▼                                                │ <hc from="t3 issue-12">完了報告</hc>
issue-12 / issue-13: claude-worker（子 terminal、Issue ごとの worktree）
```

権限確認は次の 5 層で扱います。判断ルール（ポリシー）は [hc-permission](../.local/bin/hc-permission) の 1 か所にあり、1 と 3 は同じルールを使います。

| 層 | 担当 | 内容 |
| --- | --- | --- |
| 1 | ワーカーの `PermissionRequest` hook（コード） | 明確に無害なら allow、明確に危険なら deny を返す。どちらでもなければ保留要求（ツール名と入力）を `~/.local/state/hc-orchestrator/pending/<terminal>.json` に保存し、決定を返さずに通常の権限ダイアログへ回す |
| 2 | オーケストレーター（LLM） | 届いた `blocked (permission)` を `hc-permission show` で読み、`approve` / `deny` / `escalate` を選ぶ |
| 3 | `hc-permission approve`（コード） | 保留要求を危険ルールと再照合し、当たれば承認を拒否する。保留要求がない・古い・画面のダイアログと一致しない場合も拒否する |
| 4 | オーケストレーターの `PreToolUse` hook（コード） | 生の `hc keys`、`hc send --force`、保留要求・監査ログの直接操作、ポリシーファイルの編集を拒否し、`hc-permission` 経由に限定する |
| 5 | あなた | 迷うもの・取り消しにくい外部操作だけ、スマホから答えやすい形で質問が届く |

役割（オーケストレーター / ワーカー）は、テンプレートの `command` で `--append-system-prompt-file`（システムプロンプト）と `--settings`（hook と許可ルール）を渡して固定します。最初のメッセージだけで役割を伝える方式とは違い、会話の途中で役割の指示が薄れません。

| ファイル | 内容 |
| --- | --- |
| [templates/claude-orchestrator.md](../.config/herdr-core/templates/claude-orchestrator.md) / [claude-worker.md](../.config/herdr-core/templates/claude-worker.md) | `hc run` で使うテンプレート（起動コマンド） |
| [claude/orchestrator-prompt.md](../.config/herdr-core/claude/orchestrator-prompt.md) / [worker-prompt.md](../.config/herdr-core/claude/worker-prompt.md) | 役割のシステムプロンプト |
| [claude/orchestrator-settings.json](../.config/herdr-core/claude/orchestrator-settings.json) / [worker-settings.json](../.config/herdr-core/claude/worker-settings.json) | 役割ごとの hook と許可ルール |
| [hc-permission](../.local/bin/hc-permission) | ポリシー、両 hook、`show` / `approve` / `deny` / `escalate` / `trust` |
| [hc-orch](../.local/bin/hc-orch) | オーケストレーターの起動 |

### 自動判定の既定ルール

ワーカーの worktree（Claude Code を起動したディレクトリ）を基準に判定します。

- 自動で許可: 読み取り系コマンド、Read / Glob / Grep、worktree 内のファイル編集、テスト・lint・ビルド（`pytest`、`make check`、`pnpm test`、`cargo test` など）、lockfile に沿った依存の導入（`uv sync`、`pnpm install`）、`git add` / `commit`、自分のブランチへの通常の push、`gh pr create` / `view`、`gh issue view`、`/tmp` と `$TMPDIR` への書き込み
- 自動で拒否: `sudo`、force push、main などの既定ブランチへの push、`git reset --hard`、`git clean -f`、ブランチ・tag の削除、`gh pr merge`、リリース・パッケージ公開、`curl … | sh`、秘密情報（`~/.ssh`、`.env`、`printenv` など）へのアクセス、worktree の外への書き込み
- オーケストレーターへ回す: それ以外（ネットワークアクセス、新しいパッケージの追加、コマンド置換を含むもの、worktree の外への `cd`、WebFetch、MCP ツールなど）

ルールを変えるときは `hc-permission` を編集し、`tests/test_hc_permission_policy.py` に例を足します。

### 注意

- herdr-core のマニュアルは、`blocked` を「人の判断が必要」と位置づけています。この構成は、その判断の一部をあなたの代わりに hook とオーケストレーターへ任せるものです。`~/.local/state/hc-orchestrator/decisions.jsonl`（hook の自動判定も含む全判断の記録）を定期的に確認し、ルールが緩すぎないか見直してください。
- 第 4 層の拒否は、コマンド文字列に対する検査です。スクリプトを書いて間接的に実行するなどの回避は防げません。ワーカー側の第 1 層と第 3 層がコードで止めるので、危険な操作が承認されることはありませんが、オーケストレーターが「迷うもの」を承認できる点は変わりません。
- ワーカーは `--permission-mode default` で起動します。`~/.claude/settings.json` が auto mode などを既定にしていても、ワーカーでは権限確認が hook とオーケストレーターに届くようにするためです。`~/.claude/settings.json` の allow / deny ルールは従来どおり先に効きます。
- オーケストレーターを止めると子のワーカーも止まります（`--outlive-parent` を付けない限り）。
- 初回起動のフォルダ信頼（trust）ダイアログには、オーケストレーターが `hc-permission trust` で答えます。直接の親であり、画面に trust ダイアログが出ていて「1. Yes」が選ばれている場合だけ Enter を送ります。表示されたパスが依頼した worktree かどうかの確認は、オーケストレーター（LLM）に任せています。

## 使い方

hc の導入は `curl -fsSL https://releases.herdr.dev/core/install.sh | sh`（`make bootstrap` も未導入なら実行します）です。

```bash
make link        # テンプレート・役割ファイル・hc-permission・hc-orch をリンク
hc templates     # claude-orchestrator / claude-worker が出ることを確認

hc-orch ~/mlbot-dev "Issue #12 と #13 を /issue-development-workflow で PR 作成まで進める"
hc attach orch-mlbot-dev   # 端末から見る場合。Ctrl+\ で離れる（止まらない）
```

Herdr app やスマホのアプリでは、`orch-<リポジトリ名>` がサイドバーに出るので、そこから開きます。スマホから起動するときも、アプリで開いたシェルで同じ `hc-orch` の 1 行を実行します。

## 外出先から操作する

herdr-core の terminal は、どのクライアント（Herdr app、スマホアプリ、`hc attach`）からつないでも同じものを操作できます。PC の Herdr app で動かしているセッションを、外出先からそのまま引き継げます。

### スマホアプリ（Herdr、iPhone / iPad / Android）

スマホアプリは SSH で各マシンの herdr-core に直接つなぎます。Herdr のアカウントや中継サーバーはありません。この環境では、既存の [スマホからの遠隔操作](remote-access.md) の経路をそのまま使えます。

```
スマホ（Herdr アプリ）──Tailscale SSH──> WSL（tailscaled）──> herdr-core ──> orch / ワーカー
```

1. WSL で `sudo tailscale up --ssh` 済みであること（[remote-access.md](remote-access.md) の手作業の設定）
2. スマホにも Tailscale を入れ、同じ tailnet に参加する
3. Herdr アプリで WSL のマシン（Tailscale のデバイス一覧から選べる）を追加する

スマホからは、どのエージェントが待っているかの確認、本物の端末を開いての操作、テキスト・スクリーンショット・音声での返信ができます。スマホで見ても PC 側の画面サイズは変わりません。

### Windows の Herdr app から WSL のセッションを見る

Windows 版 Herdr app のローカル core は Windows 側にあります。WSL で動くセッションを同じサイドバーに出すには、WSL をマシンとして追加します（SSH サーバーは不要です）。

```powershell
hc machine add --via 'wsl.exe -d Ubuntu -e sh -c' --name wsl
```

スマホは WSL の herdr-core へ直接つなぐため、オーケストレーターとワーカーは WSL 側（`--on wsl` または WSL のシェルから `hc run`）で動かします。

### スマホアプリが使えない場合

Tailscale SSH で WSL に入り、`hc attach orch-<リポジトリ名>` で同じ terminal を操作できます（Ctrl+\ で離れる）。

### 動かし続けるための条件

- PC がスリープすると止まります。スリープ抑止は [remote-access.md](remote-access.md) の awake-keeper が担当しますが、判定対象は「Claude 作業中」と「SSH 経由の tmux」です。hc の terminal で Claude が作業している間は awake-hook のマーカーで抑止されます。
- WSL がアイドル停止しないよう、`loginctl enable-linger` を有効にしておきます（`make remote-access` が設定します）。
- herdr-core は PC の再起動後に未完了の作業を再開しません。

## 確認状況

- ポリシーの判定は `tests/test_hc_permission_policy.py`、hook の入出力と `hc-permission` のガード・監査ログは偽の `hc` を使う `tests/test_hc_permission.sh`、`hc-orch` は `tests/test_hc_orch.sh` で検証しています（`make check` で実行）。
- 次の点は hc を導入した後に実機で確認する必要があります。
  - Claude Code が hc の terminal 内で `blocked (permission)` を報告し、親に通知が届くこと
  - `--settings` で渡した hook が `~/.claude/settings.json` の hook と併合されて動くこと、hook に `HC_TERMINAL_ID` が引き継がれること
  - `hc-permission approve` / `deny` / `trust` の Enter / Esc が、実際のダイアログで意図した選択肢になること
  - スマホアプリからの接続
