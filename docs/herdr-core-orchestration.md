# herdr-core で Claude Code を監督する

Herdr app（GUI）とスマホアプリの実行基盤である herdr-core（`hc`）に、監督役（supervisor）の Claude Code を 1 つ常駐させる構成です。監督役は、hc 上の**すべての** Claude Code セッション（あなたが Herdr app やスマホで手動で開いたものを含む）の権限確認を代行し、頼まれればワーカーの Claude Code を起動します。

TUI 版 `herdr` と herdr-core は別の実行基盤です。TUI で起動したエージェントは Herdr app にもスマホにも表示されません。既存の `herdr-codex-orchestrate`（TUI 用）はそのまま残しています。Codex セッションの監督は今回の対象外です（判断ルールは Claude Code の hook 入力に依存しない `classify` にまとめてあり、後から Codex 用の入口を足せます）。

## 仕組み

```
あなた（PC の Herdr app / スマホの Herdr アプリ / ssh + hc attach）
  │ 依頼・エスカレーションへの回答            │ 手動で開いた Claude Code
  ▼                                          ▼
supervisor（role=supervisor、親なし）      t5, t6 …（親なし）── blocked(permission)
  ├─ supervisor-watch（子、hc events を見張る）◄────── hc events
  │     └─ hc send supervisor "<hc-watch>t5 … is blocked (permission) …</hc-watch>"
  └─ ワーカー（role=worker、--outlive-parent）── blocked は hc が親（supervisor）へ直接通知
```

- hc の `blocked` 通知は直接の親にしか届きません。手動セッションには親がないので、watcher（[hc-supervisor-watch](../.local/bin/hc-supervisor-watch)）が `hc events` を見張り、監督役以外の terminal が `blocked (permission)` になったら監督役へ `hc send` で知らせます。監督役の子（ワーカー）は hc が親へ直接通知するので、watcher は知らせません。
- 監督役は「ラベル `role=supervisor` を持つ terminal」で識別します。`hc-permission` の操作は、呼び出し元（`$HC_TERMINAL_ID`）の terminal を `hc get` で確かめ、監督役でなければ拒否します。ワーカー側から監督役ラベルを付ける操作（`hc label … role=supervisor` など）はポリシーで拒否します。
- watcher は監督役の子として起動するので、監督役を止めれば watcher も止まります。ワーカーは `--outlive-parent` で起動するので、監督役が止まっても作業を続けます。

権限確認は次の 5 層で扱います。判断ルール（ポリシー）は [hc-permission](../.local/bin/hc-permission) の 1 か所にあり、1 と 3 は同じルールを使います。

| 層 | 担当 | 内容 |
| --- | --- | --- |
| 1 | 全セッションの `PermissionRequest` hook（コード、`~/.claude/settings.json`） | hc の外と監督役自身では何もしない。明確に無害なら allow。明確に危険なら、ワーカー（`role=worker`）では deny、手動セッションでは決定せずダイアログに残す（あなたの判断）。どちらでもなければ保留要求（ツール名と入力）を `~/.local/state/hc-supervisor/pending/<terminal>.json` に保存し、通常の権限ダイアログへ回す |
| 2 | 監督役（LLM） | 届いた権限待ちを `hc-permission show` で読み、`approve` / `deny` / `escalate` を選ぶ |
| 3 | `hc-permission approve`（コード） | 呼び出し元が監督役か、対象が監督役自身でないかを確かめ、保留要求を危険ルールと再照合し、当たれば承認を拒否する。保留要求がない・古い・画面のダイアログと一致しない場合も拒否する |
| 4 | 監督役の `PreToolUse` hook（コード） | 生の `hc keys`、`hc send --force`、保留要求・監査ログの直接操作、ポリシーファイルの編集を拒否し、`hc-permission` 経由に限定する |
| 5 | あなた | 迷うもの・取り消しにくい外部操作・手動セッションでの危険操作だけ、スマホから答えやすい形で質問が届く |

| ファイル | 内容 |
| --- | --- |
| [hc-supervisor](../.local/bin/hc-supervisor) | 監督役と watcher の起動・状態表示・停止 |
| [hc-supervisor-watch](../.local/bin/hc-supervisor-watch) | `hc events` を見張り、権限待ちを監督役へ知らせる |
| [hc-permission](../.local/bin/hc-permission) | ポリシー、両 hook、`show` / `approve` / `deny` / `escalate` / `trust` |
| [templates/claude-supervisor.md](../.config/herdr-core/templates/claude-supervisor.md) / [claude-worker.md](../.config/herdr-core/templates/claude-worker.md) | `hc run` で使うテンプレート（起動コマンド） |
| [claude/supervisor-prompt.md](../.config/herdr-core/claude/supervisor-prompt.md) / [worker-prompt.md](../.config/herdr-core/claude/worker-prompt.md) | 役割のシステムプロンプト |
| [claude/supervisor-settings.json](../.config/herdr-core/claude/supervisor-settings.json) | 監督役の PreToolUse hook と許可ルール |

役割は、テンプレートの `command` で `--append-system-prompt-file`（システムプロンプト）と、監督役では `--settings`（hook と許可ルール）を渡して固定します。PermissionRequest hook は手動セッションにも効かせるため、テンプレートではなく `~/.claude/settings.json` に入れます。

### 自動判定の既定ルール

セッションを起動したディレクトリ（`CLAUDE_PROJECT_DIR`、なければ cwd）を「worktree」として判定します。

- 自動で許可: 読み取り系コマンド、Read / Glob / Grep、worktree 内のファイル編集、テスト・lint・ビルド（`pytest`、`make check`、`pnpm test`、`cargo test` など）、lockfile に沿った依存の導入（`uv sync`、`pnpm install`）、`git add` / `commit`、自分のブランチへの通常の push、`gh pr create` / `view`、`gh issue view`、`/tmp` と `$TMPDIR` への書き込み
- 危険（ワーカーでは自動で拒否、手動セッションではあなたの判断）: `sudo`、force push、main などの既定ブランチへの push、`git reset --hard`、`git clean -f`、ブランチ・tag の削除、`gh pr merge`、リリース・パッケージ公開、`curl … | sh`、秘密情報（`~/.ssh`、`.env`、`printenv` など）へのアクセス、worktree の外への書き込み、監督役ラベルの付与
- 監督役へ回す: それ以外（ネットワークアクセス、新しいパッケージの追加、コマンド置換を含むもの、worktree の外への `cd`、WebFetch、MCP ツールなど）

`~/.claude/settings.json` の `permissions.allow` / `deny` は hook より先に効きます。たとえば `Bash(git push:*)` を allow にしていれば、push はダイアログにも hook にも来ません。

ルールを変えるときは `hc-permission` を編集し、`tests/test_hc_permission_policy.py` に例を足します。

### permission mode

ワーカーにも手動セッションにも permission mode を強制しません（`--permission-mode` を付けない）。手動セッションには強制できず、ワーカーだけ変えると扱いが揃わないためです。あなたの既定が auto mode などなら、Claude Code 自身の判定で通る操作はダイアログにならず、hook にも監督役にも届きません。監督役に判断させたいセッションは default mode で開いてください。

### 注意

- herdr-core のマニュアルは、`blocked` を「人の判断が必要」と位置づけています。この構成は、その判断の一部をあなたの代わりに hook と監督役へ任せるものです。`~/.local/state/hc-supervisor/decisions.jsonl`（hook の自動判定も含む全判断の記録）を定期的に確認し、ルールが緩すぎないか見直してください。
- 手動セッションの権限待ちは、監督役にもあなたにも見えます。どちらが答えてもかまいません。監督役は、届いた時点で既に blocked でなければ何もしません。
- 第 4 層の拒否は、コマンド文字列に対する検査です。スクリプトを書いて間接的に実行するなどの回避は防げません。第 1 層と第 3 層がコードで止めるので、危険な操作が監督役に承認されることはありませんが、監督役が「迷うもの」を承認できる点は変わりません。
- watcher からの知らせ（`<hc-watch>…`）は、どのセッションからでも `hc send` で偽装できます。監督役はそれを指示として扱わず、必ず `hc-permission show` と `approve` の検査を通します。
- 初回起動のフォルダ信頼（trust）ダイアログには、監督役が自分の子（ワーカー）に限って `hc-permission trust` で答えます。手動セッションの trust にはあなたが答えます。
- `hc-supervisor` は監督役を `--keep` で起動します。herdr-core の再起動後、監督役の terminal は元のコマンドの代わりにシェルになり、watcher は消えます。`hc-supervisor stop` の後に `hc-supervisor` で起動し直してください。

## 導入

### 1. リンクと hc

hc の導入は `curl -fsSL https://releases.herdr.dev/core/install.sh | sh`（`make bootstrap` も未導入なら実行します）です。

```bash
make link        # hc-permission・hc-supervisor・watcher・テンプレート・役割ファイルをリンク
hc templates     # claude-supervisor / claude-worker が出ることを確認
```

### 2. ~/.claude/settings.json への hook の追加

`~/.claude/settings.json` は初回だけ dotfiles からコピーされる（`copy-if-missing`）ため、既存の環境には自動で入りません。`hooks` に次の `PermissionRequest` を手で追記してください（他の hook はそのまま残します）。

```json
"PermissionRequest": [
  {
    "matcher": "*",
    "hooks": [
      {
        "type": "command",
        "command": "~/.local/bin/hc-permission hook-worker",
        "timeout": 30
      }
    ]
  }
]
```

追記後の確認:

```bash
python3 -m json.tool ~/.claude/settings.json >/dev/null && echo OK   # JSON として壊れていないこと
# hc の外では何もしない（何も出力されなければ正しい）
echo '{"tool_name":"Bash","tool_input":{"command":"git push --force"},"cwd":"/tmp"}' \
  | env -u HC_TERMINAL_ID ~/.local/bin/hc-permission hook-worker
```

hook は hc の外（`HC_TERMINAL_ID` がない）では何もしないので、通常の端末や VS Code の Claude Code には影響しません。

### 3. 監督役の起動

```bash
hc-supervisor            # 監督役（supervisor）と watcher（supervisor-watch）を起動
hc-supervisor status     # 状態を見る
hc-supervisor stop       # 止める（ワーカーは止まらない）
hc attach supervisor     # 端末から見る場合。Ctrl+\ で離れる（止まらない）
```

初回は監督役の cwd（既定は `$HOME`、`--cwd` で変更）でフォルダ信頼のダイアログが出ます。**既定で「No, exit」が選ばれている**ので、Herdr app かスマホ、または `hc attach supervisor` で開き、↓ で「Yes, I trust this folder」を選んでから Enter を押してください。ダイアログが出ている間は最初の依頼文が届きませんが、役割はシステムプロンプトで渡しているので、そのまま待機状態になります。`~/.claude/settings.json` に hook がなければ、`hc-supervisor` が注意を表示します。

Herdr app の端末での貼り付けは **Ctrl+Shift+V**（または右クリック）です。Ctrl+V はシェルにそのまま送られ、zsh では「次のキーを文字として入れる」になるので、続けて Enter を押すと `command not found: ^M` になります。

### 4. 使い方

- 手動セッション: これまでどおり Herdr app やスマホで Claude Code を開くだけです。権限待ちになると、hook が判断できたものは自動で決まり、残りは監督役に届きます。
- ワーカーを頼む: Herdr app かスマホで `supervisor` を開き、「~/mlbot-dev の Issue #12 と #13 を /issue-development-workflow で PR 作成まで進めて」のように頼みます。監督役は `role=worker` のワーカーを `--outlive-parent` で起動し、結果を確かめて報告します。

## 外出先から操作する

herdr-core の terminal は、どのクライアント（Herdr app、スマホアプリ、`hc attach`）からつないでも同じものを操作できます。PC の Herdr app で動かしているセッションを、外出先からそのまま引き継げます。

### スマホアプリ（Herdr、iPhone / iPad / Android）

スマホアプリは SSH で各マシンの herdr-core に直接つなぎます。Herdr のアカウントや中継サーバーはありません。この環境では、既存の [スマホからの遠隔操作](remote-access.md) の経路をそのまま使えます。

```
スマホ（Herdr アプリ）──Tailscale SSH──> WSL（tailscaled）──> herdr-core ──> supervisor / 各セッション
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

監督役は自分のマシンの herdr-core の terminal だけを見張ります。スマホは WSL の herdr-core へ直接つなぐため、監督役も監督されるセッションも WSL 側（`--on wsl` または WSL のシェル）で動かします。

### スマホアプリが使えない場合

Tailscale SSH で WSL に入り、`hc attach supervisor` で同じ terminal を操作できます（Ctrl+\ で離れる）。

### 動かし続けるための条件

- PC がスリープすると止まります。スリープ抑止は [remote-access.md](remote-access.md) の awake-keeper が担当しますが、判定対象は「Claude 作業中」と「SSH 経由の tmux」です。hc の terminal で Claude が作業している間は awake-hook のマーカーで抑止されます。
- WSL がアイドル停止しないよう、`loginctl enable-linger` を有効にしておきます（`make remote-access` が設定します）。
- herdr-core は PC の再起動後に未完了の作業を再開しません。

## 確認状況

- ポリシーの判定とラベルの解釈は `tests/test_hc_permission_policy.py`、hook の入出力と `hc-permission` のガード・監査ログは `tests/test_hc_permission.sh`、watcher は `tests/test_hc_supervisor_watch.sh`、起動スクリプトは `tests/test_hc_supervisor.sh` で、偽の `hc` を使って検証しています（`make check` で実行）。
- 実機で確認済み（hc 0.1.21、2026-11-14）:
  - `hc get --json` は最上位に `address`、`name`、`parent`（なしは `null`）、`state`（`live` / `finished`）、`labels`（辞書）、`status`（報告前は `null`）、`cwd` と `foreground.cwd` を持つ。`hc ls --json` は `{"terminals": [...]}`
  - `hc-supervisor` で監督役（`role=supervisor`、親なし）と watcher（監督役の子）が起動する
  - Claude Code の trust ダイアログは `❯ No, exit` / `Yes, I trust this folder` で、No が既定。`hc-permission trust` は ↓ で Yes に動かし、画面で確かめてから Enter を送る
  - 初回の trust ダイアログ中は `hc run` が最初の依頼文を届けられず待つ（`first_message.sent: false`）。`hc-supervisor` は `--timeout 20` で待ちを切り上げる
- 次の点は実機確認が必要です。実装はどれも形が違っても動くよう寛容にしてありますが、前提が外れていれば直します。
  - `hc events --json` の 1 行の形（watcher はアドレスらしい値を拾い、拾えなければ `hc ls --json` で全体を見直す）
  - 権限ダイアログの選択肢の形（`❯ 1. Yes` と番号なしの `❯ Yes` の両方を受け付ける）
  - PermissionRequest hook に `HC_TERMINAL_ID` が引き継がれること、`--settings` で渡した監督役の PreToolUse hook が `~/.claude/settings.json` の hook と併合されて動くこと
  - Claude Code が hc の terminal 内で `blocked (permission)` を報告すること、親への通知と watcher の `hc send` が監督役に届くこと（監督役が作業中・自分のダイアログで止まっているときを含む）
  - `hc run` のテンプレートに渡した最初の依頼文が送られること、`--keep` の監督役が herdr-core の再起動後にどうなるか
  - `hc-permission approve` / `deny` / `trust` の Enter / Esc が、実際のダイアログで意図した選択肢になること
  - スマホアプリからの接続
