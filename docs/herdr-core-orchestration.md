# herdr-core で Claude Code を監督する

Herdr app（GUI）とスマホアプリの実行基盤である herdr-core（`hc`）に、監督役（supervisor）の Claude Code を 1 つ常駐させ、ワーカーの Claude Code を複数動かす構成です。人が張り付かなくても、ワーカーは commit・push・PR 作成まで止まらずに進みます。

TUI 版 `herdr` と herdr-core は別の実行基盤です。TUI で起動したエージェントは Herdr app にもスマホにも表示されません。既存の `herdr-codex-orchestrate`（TUI 用）はそのまま残しています。

経緯と判断の記録: Issue #26（#21・#25 を置き換え）。

## 考え方: 境界は WSL ディストリ

権限の境界を、Claude Code の sandbox（コマンドごと）ではなく WSL のディストリビューション単位に置きます。

- **dev**: エージェントと日常の開発用。Windows のドライブは見えず（VS Code 用の 2 ディレクトリだけ読み取り専用）、Windows のプログラムは起動できず、作業ユーザーは root になれません。作り方は [wsl-dev-distro.md](wsl-dev-distro.md)。
- **admin**（今の `Ubuntu-24.04`）: 秘密情報と dev の境界設定を管理します。エージェントは動かしません。

境界の内側では権限確認をしません。hc 上の監督役・ワーカーは、sandbox なし・`bypassPermissions` で動きます。そのうえで、取り返しのつかない操作だけを 2 か所で止めます。

| 層 | 担当 | 内容 |
| --- | --- | --- |
| 1 | dev ディストリ | Windows・root・admin のファイルに届かない（境界） |
| 2 | `PreToolUse` hook（[hc-permission](../.local/bin/hc-permission) `hook`） | 事故よけ。少数の危険操作を理由付きで deny する。allow・ask は返さず、判断を auto mode や監督役に回さない |
| 3 | GitHub の ruleset | force push とブランチの削除をサーバー側で禁止する（下記「GitHub ruleset」） |

監督役は権限確認を代行しません。仕事は、判断と記録（仕様・設計を含めて 1 つに決めて `hc send` で返し、判断記録に残す）・ワーカーの起動・受理の 3 つです（[supervisor-prompt.md](../.config/herdr-core/claude/supervisor-prompt.md)）。

### 判断は監督役が決め、ユーザーは後から直す

権限確認がなくなったので、作業が止まるのは判断待ちのときだけです。そこでユーザーに事前承認を求めず、監督役が決めて進めさせ、決めたことを記録してユーザーが後から確かめて直す形にしています。

- ワーカーは仕様・設計の判断もユーザーに聞かず、`hc send supervisor` で相談します（skill の「ユーザーに確認する」も監督役への相談に読み替える）。
- 監督役は 1 つに決め、`~/.local/share/hc-supervisor/decisions.md` に `D-YYYYMMDD-HHMM` の ID で記録してから返します。記録には相談・決定・理由・退けた案・影響と直し方を書き、Issue から外れる判断や推測で決めた判断には「要確認: あり」を付けます。
- ワーカーは PR 本文の「監督役の判断」の節に ID と決定を書きます。監督役は完了報告にも判断の一覧を付けます。
- 直したいときは、監督役に「D-… は ○○ に直して」と頼みます。監督役は記録に訂正を追記し、動いているワーカーに伝えるか、直しのワーカーを起動します。
- ユーザーに回るのは、取り消しにくい外部操作（本番へのデプロイ、課金が発生する操作、ユーザー以外の人に通知が飛ぶ操作など）と、事故よけ hook に止められた操作が必要なものだけです。自分のリポジトリでの Issue・PR の作成、頼まれた作業の再開や順番は監督役が決めます。

### なぜ sandbox をやめたか

- sandbox は「1 セッション・1 作業ディレクトリ」を前提にコマンドごとに境界を張る。複数セッションの運用では、hc の socket、共通の認証情報、`.claude/settings.json`・`.git/config` への書き込みなど、境界をまたぐことが本来の仕事なので、例外が増え続けた（`excludedCommands` はパイプでつなぐと効かない、`~/.gitconfig` と gh 認証が見えず commit・push が通らない、`.claude/settings.json` が読み取り専用で bind mount され merge が `Device or resource busy` で止まる）。
- それで守れていたのは「作業ディレクトリの外をうっかり壊さない」ことだけで、秘密情報の持ち出し経路は開いていた。
- 権限確認のグレーゾーンを監督役に回す設計では、監督役の文脈が積み上がり、結局ユーザーに判断を丸投げした。
- Claude Code 公式も、無人実行ではプロセス全体を container / VM で囲うこと、auto mode は境界ではないことを示している（https://code.claude.com/docs/en/sandbox-environments）。

### 採らなかった案

- フック → auto mode → ユーザーの 3 段（旧方針）: 段 1 を除外形式にすると auto mode に何も回らず、絞ると auto mode の確認が大量に出る。
- ホワイトリスト方式のフック: sandbox の例外を足し続けたのと同じ保守になる。
- srt（sandbox-runtime）: dotfiles が管理する `.bashrc` などを無条件に書き込み禁止にし、Linux では AF_UNIX ソケットの作成を一律に禁止して hc が止まる。beta。
- 別 Linux ユーザー: egress を制限できず、主流でもない。
- ワーカーごとのコンテナ: hc の socket、worktree の絶対パスの mount、認証の受け渡しが重い（次点）。

### 残るリスク（受け入れる）

- 同一 VM・同一カーネル。悪意ある脱出は対象外。
- egress は無制限。gh トークンのスコープも当面は限定しない（`repo`・`gist` を含む）ため、持ち出しや他リポジトリへの書き込みは技術的には可能。
- 境界の内側にある Claude の認証情報と、作業に必要な gh 認証はエージェントから見える。
- 同じ境界の中なので、ワーカーは hc 経由で他のセッションに干渉できる（プロンプトで禁じているだけ）。
- WSL2 のディストリは同じ VM でネットワークを共有するため、admin の `127.0.0.1` のサービスに dev から届く。admin には localhost のサービスを置かない。
- hook はコマンド文字列の検査なので、スクリプト経由などの回避は防げない（事故よけであり防御線ではない）。force push とブランチ削除は ruleset でも止める。
- 秘密情報の扱いは対象外（境界の外に置き、操作だけを中継する仕組みを別に用意する）。

## 構成

```
あなた（PC の Herdr app / スマホの Herdr アプリ / ssh + hc attach）
  │ 依頼・質問への回答
  ▼
supervisor（dev、role=supervisor、親なし）
  │ hc run … claude-worker（--outlive-parent）     ▲ hc send supervisor（相談・報告）
  ▼                                               │
ワーカー（dev、role=worker）── commit・push・PR まで止まらない
```

| ファイル | 内容 |
| --- | --- |
| [hc-claude](../.local/bin/hc-claude) | 監督役・ワーカーの起動ラッパー。`/etc/dotfiles-role` が `dev` のときだけ `claude --model opus --effort <high|medium> --permission-mode bypassPermissions --settings session-settings.json --append-system-prompt-file <role>-prompt.md` を exec し（effort は監督役 high・ワーカー medium）、それ以外（admin）では起動を拒否する。文脈予算の閾値 `CLAUDE_CTX_GUARD_TOKENS` を役割ごとに渡す（下記「文脈予算とトークン記録」） |
| [hc-supervisor](../.local/bin/hc-supervisor) | 監督役の起動・状態表示・停止と、引き継いだワーカーの起動し直し（`resume-worker`）。dev でだけ起動する |
| [hc-permission](../.local/bin/hc-permission) | 事故よけの deny リスト（`hook` / `check`） |
| [templates/claude-supervisor.md](../.config/herdr-core/templates/claude-supervisor.md) / [claude-worker.md](../.config/herdr-core/templates/claude-worker.md) | `hc run` のテンプレート（`command: hc-claude supervisor|worker`） |
| [claude/session-settings.json](../.config/herdr-core/claude/session-settings.json) | hc 上のセッションの設定（`defaultMode: bypassPermissions`、`sandbox.enabled: false`、`PreToolUse` Bash → `hc-permission hook`、`UserPromptSubmit`・`PostToolUse` → `claude-context-guard`、`SessionEnd` → `claude-token-metrics record`） |
| [claude/supervisor-prompt.md](../.config/herdr-core/claude/supervisor-prompt.md) / [worker-prompt.md](../.config/herdr-core/claude/worker-prompt.md) | 役割のシステムプロンプト |
| [herdr-app/mods/supervisor-board](../.config/herdr-app/mods/supervisor-board/main.js) / [layouts/board.json](../.config/herdr-app/layouts/board.json) | Herdr app の監督役ボード。`board` レイアウト（main の複製）で Changes パネルの中身をこの mod に替える |

- bypassPermissions・sandbox なしは **hc-claude で起動したセッション（監督役・ワーカー）だけ**です。Herdr app で手動で開いたセッションや VS Code の Claude Code は、各ディストリの `~/.claude/settings.json` のまま動きます。
- `--settings` は user / project の設定より上、managed より下で効きます。`skipDangerousModePermissionPrompt`（bypassPermissions の初回確認を出さない）は `--settings` からは効かないため、dev の `~/.claude/settings.json` に `setup-dev-distro.sh` が入れます。
- `permissions.blockReadsOutsideWorkingDirectories: true` を `~/.claude/settings.json` に入れている場合、どの scope からも外せません。ワーカーのファイルツール（Read など）は worktree の外で止まります（Bash は対象外）。
- 報告先は名前の `supervisor` に固定しています。監督役を作り直しても、ワーカーの報告は新しい監督役に届きます。

### 事故よけの deny リスト

`hc-permission check '<コマンド>'` で判定を確かめられます。ルールを変えるときは `hc-permission` を編集し、`tests/test_hc_permission.py` に例を足します。

- 止めるもの: `sudo` / `su`（パスワード待ちで止まるため）、force push、リモートのブランチ・tag の削除と mirror push、`git reset --hard`、`git clean -f`、`git branch -D`、`git stash drop|clear`、`filter-branch` などの履歴書き換え、`git config --global|--system`、`gh repo delete|archive|rename|edit`、`gh release delete`、`gh secret|variable|ssh-key|gpg-key`、`gh auth logout|refresh|switch|token|setup-git`、`gh api` の DELETE と ruleset・ブランチ保護の変更、パッケージ・イメージの公開、`rm` での `/`・`~`・`$HOME`・`.`・`..`・`*`、`curl … | sh`、システム操作、`dd of=/dev`、`crontab -r`、`chmod 777`。
- 止めないもの: main への直接 push（dotfiles は main へ push する規約）、`gh pr merge`（ruleset で守る）、秘密情報のパターン（境界の外の話）、`hc keys` / `hc send --force`（同じ境界の中の干渉は許容）。

拒否されたセッションにはエラーが返るだけで、止まりません。ワーカーは別の方法を取るか、監督役に相談します。

### 文脈予算とトークン記録

hc 上の監督役・ワーカーでは、`session-settings.json` の hook で次の 2 つが動きます（Issue #30）。`~/.claude/settings.json` に同じ hook が入っているかどうかに関係なく動きます。

| 何を | hook | 結果 |
| --- | --- | --- |
| 文脈予算の警告 | `UserPromptSubmit`・`PostToolUse` → [claude-context-guard](../.local/bin/claude-context-guard) | 直近リクエストの文脈（input + cache 作成 + cache 読み込み）が閾値を超えると、handoff を促す警告が `additionalContext` としてセッションに入る。以後は前回の警告から `CLAUDE_CTX_GUARD_INTERVAL`（既定 50000）増えるたびに再警告する |
| トークン記録 | `SessionEnd` → [claude-token-metrics](../.local/bin/claude-token-metrics) `record` | セッションの終了時に `~/.local/share/claude-token-metrics/sessions.jsonl` へ 1 行追記する（`cwd` はそのセッションの作業ディレクトリ）。`claude-token-metrics report` で一覧できる。詳しくは [claude-token-metrics.md](claude-token-metrics.md) |

閾値は `hc-claude` が役割ごとに `CLAUDE_CTX_GUARD_TOKENS` として渡します。

| 役割 | 既定 | 上書きする環境変数 | 警告を受けたら |
| --- | --- | --- | --- |
| 監督役 | 150000 | `HC_CLAUDE_SUPERVISOR_CTX_GUARD_TOKENS` | handoff を書いて `hc-supervisor restart`（[supervisor-prompt.md](../.config/herdr-core/claude/supervisor-prompt.md) の「コンテキストの予算と作り直し」） |
| ワーカー | 120000 | `HC_CLAUDE_WORKER_CTX_GUARD_TOKENS` | handoff を更新して `【引き継ぎ】<path>` を監督役に送り、ターンを終える。監督役が同じ worktree で新しいワーカーを起動して続けさせる（下記「ワーカーの引き継ぎ」） |

- 上書き値は `hc-claude` を起動する環境に置きます。正の整数でなければ警告を出して既定を使います（起動は止めません）。
- 呼び出し元の `CLAUDE_CTX_GUARD_TOKENS` は使わず、必ず役割の値で上書きします。監督役の環境がワーカーに引き継がれても、ワーカーの閾値は監督役の値になりません。
- ワーカーを 120k にしているのは、実測（2026-11-22）でワーカーの文脈が開始時 51k から約 15 リクエストで 120k に達し、150k を超えた後も数十リクエスト続いていたためです。
- hook は失敗してもセッションを止めません（guard は常に exit 0、record は `|| true`）。

#### ユーザー設定と同じ hook を置いている理由

リポジトリ版 `.claude/settings.json`（`~/.claude/settings.json` の元）にも同じ hook があります。hc のセッションでは `~/.claude/settings.json` と `--settings` の両方が読まれますが、Claude Code は同じ hook（同じ command 文字列）を複数の設定ファイルに書いても 1 回だけ実行します（公式ドキュメント hooks の "If you define the same handler in more than one settings file, it runs once."。project 設定と `--settings` の組み合わせでは 1 回だけ動くことを実機で確認済み）。そのため command 文字列をユーザー設定と 1 文字も違わないように揃えています（`~/.local/bin/x` と `"$HOME/.local/bin/x"` は別の hook として両方動く）。`tests/test_hc_claude.sh` が両方のファイルの command 文字列が一致することを検査します。

両方に置くのは、`~/.claude/settings.json` が古いまま（同期前）の端末でも hc のセッションでは確実に動かすためです。もし二重に動いても、警告が 2 回出るか、`sessions.jsonl` に同じ `session_id` の行が 2 行増えるだけです（`report` は後の行を採用する）。

#### 実機で確かめる（dev）

`hc run` には環境変数を渡すオプションがないので、閾値を小さくしたワーカーは `env` を挟んで起動します。

```bash
hc run --name ctx-check --cwd ~/dotfiles -- env HC_CLAUDE_WORKER_CTX_GUARD_TOKENS=1000 hc-claude worker 'README.md を読んで 1 行で要約して'
# 返答の後、transcript に警告（additionalContext）が入ることを確かめる
grep -l 'claude-context-guard' ~/.claude/projects/-home-issei-dotfiles/*.jsonl
# Herdr app か hc attach ctx-check で開き、/exit で終了する（SessionEnd で記録される）
claude-token-metrics report --since "$(date +%F)"   # ctx-check のセッションが cwd ~/dotfiles で 1 行出る
```

`make link` で `~/.local/bin/claude-context-guard` と `~/.local/bin/claude-token-metrics` がリンクされている必要があります。

### ワーカーの引き継ぎ（文脈の区切り）

セッションは自分で `/clear` できず、ワーカーは他のエージェントを起動できません。そこで、文脈が閾値を超えたワーカーは handoff を残して止まり、監督役が同じ worktree で新しいワーカーを起動して続きから再開させます（Issue #31）。1 つの Issue を大きな文脈のまま最後まで進めず、毎リクエストの cache 読み込み（≒ リクエスト数 × 平均文脈）を下げるためです。新しいワーカーは開始時の約 51k を cache 作成として払い直します。

```
ワーカー A ── guard の警告 → 進行中の操作を区切る → handoff を更新
   │ hc send supervisor "【引き継ぎ】<handoff の絶対 path>"（これだけ送ってターンを終える）
   ▼
監督役 ── hc-supervisor resume-worker --from A --cwd <worktree> --handoff <path> "<同じ依頼文>"
   │ A が role=worker で working でないことを確かめる → A を kill・rm → 消えたことを確かめる
   │ 同じ worktree で新しいワーカーを起動（依頼文の先頭に【再開】<path>、ラベル handoffs=<回数>）
   ▼
ワーカー B ── handoff を読み、branch・HEAD・未 commit の変更と照合 → next safe action から再開
```

- 手順の正本はプロンプトです。ワーカー側は [worker-prompt.md](../.config/herdr-core/claude/worker-prompt.md) の「文脈の区切りと引き継ぎ」、監督役側は [supervisor-prompt.md](../.config/herdr-core/claude/supervisor-prompt.md) の「ワーカーの引き継ぎ（文脈の区切り）」。
- handoff は `issue-development-workflow` / `session-handoff` の形式（`workflow-progress/v1`）のまま、worktree の `git rev-parse --git-path codex-handoffs` の下（Git 管理外）に置きます。引き継ぐたびに同じファイルを更新します。
- 同じ worktree を 2 つのワーカーが同時に編集しないよう、`resume-worker` は前のワーカーを止めて消えたことを確かめてから起動します。前のワーカーがまだ `working`、`role=worker` でない、見つからない（回数が分からない）ときは、何も止めず起動もしません。
- `resume-worker` は handoff が `--cwd` の `codex-handoffs` の下にある既存ファイルの絶対 path であることを確かめます。中身（branch・HEAD・next safe action）が今の worktree と合うかは、新しいワーカーが確かめ、合わなければ推測で再開せず監督役に相談します。
- 引き継ぎ回数は新しいワーカーのラベル `handoffs` に残り、監督役が進捗ボードの「進行中」にも書きます。3 回を超える（4 回目の）引き継ぎは起動せず、監督役がユーザーに報告します。上限は `HC_SUPERVISOR_MAX_WORKER_HANDOFFS`（監督役の環境）で変えられます。
- 起動し直したワーカーの閾値は、テンプレート（`claude-worker`）どおり既定の 120000 です。

#### 実機で確かめる（dev、未実施）

小さな Issue で、閾値を下げた最初のワーカーを起動し、監督役に引き継がせます。

```bash
# 監督役のタブで: 依頼文には、リポジトリ・worktree・Issue・skill・完了条件（PR 作成まで）を書く
hc run --bg --outlive-parent --label role=worker --name small-issue --cwd <worktree> \
  -- env HC_CLAUDE_WORKER_CTX_GUARD_TOKENS=70000 hc-claude worker '<依頼文>'
```

- ワーカーが `【引き継ぎ】<path>` だけを送ってターンを終え、監督役が `resume-worker` で起動し直したワーカーが handoff の next safe action から再開して PR 作成まで進むこと。
- 前後のワーカーが同じ worktree で同時に動かないこと（`hc ls` で前のワーカーが消えてから新しいワーカーが出る）。
- `claude-token-metrics report` で、起動し直したワーカーの文脈が開始時の水準（約 50k〜60k）から始まっていること。

### フォルダ信頼（trust）

trust は git リポジトリのルートに付き、worktree はメイン checkout のルートを使います。リポジトリごとに 1 回 trust すれば、そのリポジトリの worktree では出ません。dev は admin の `~/.claude.json` を複製するので、既存のリポジトリは trust 済みです。新しいリポジトリで出たら、Herdr app かスマホで「Yes, I trust this folder」を選びます（既定は「No, exit」）。`$HOME` で起動したときの trust は保存されません。

## 導入（dev で行う）

前提: [wsl-dev-distro.md](wsl-dev-distro.md) の手順で dev を作り、`verify-dev-boundary.sh` がすべて OK であること。

```bash
make link          # hc-claude・hc-supervisor・hc-permission・テンプレート・役割ファイルをリンク
hc templates       # claude-supervisor / claude-worker が出ることを確認
hc-supervisor      # 監督役を起動。Herdr app のタブから実行すると、そのスペースに「supervisor」タブが出る
hc-supervisor status
hc-supervisor board  # 進捗ボードを表示（どのセッションからでも）
hc-supervisor stop # 止める（ワーカーは止まらない）
hc-supervisor restart  # 引き継ぎを書かせてから、同じ terminal の中で Claude Code を起動し直す（プロンプトや設定の変更を反映する）
hc attach supervisor   # 端末から見る場合。Ctrl+\ で離れる（止まらない）
```

初回は監督役の cwd（既定は `~/.local/share/hc-supervisor`）で trust のダイアログが出ます。↓ で「Yes, I trust this folder」を選んでから Enter を押してください。

Herdr app の端末での貼り付けは **Ctrl+Shift+V**（または右クリック）です。Ctrl+V は zsh で「次のキーを文字として入れる」になり、続けて Enter を押すと `command not found: ^M` になります。

### 旧構成（#21・#25）からの移行

1. 各ディストリ（admin・dev）の `~/.claude/settings.json` の `hooks.PermissionRequest` から、`hc-permission hook-worker` を呼ぶエントリを消す。旧 hook 名は何もしない（no-op）ので、消し忘れても動作は壊れません。
   ```bash
   python3 -m json.tool ~/.claude/settings.json >/dev/null && echo OK
   ```
2. 古いリンクを消す（`make link` は消えたファイルのリンクを片付けません）。
   ```bash
   rm -f ~/.local/bin/hc-supervisor-watch \
     ~/.config/herdr-core/claude/worker-settings.json \
     ~/.config/herdr-core/claude/supervisor-settings.json
   ```
3. admin で動いている監督役と watcher を止める（admin の端末で `hc kill supervisor-watch; hc kill supervisor`）。この変更を pull した後は、admin の `hc-supervisor` とテンプレートは起動を拒否します（`/etc/dotfiles-role` がないため）。動いている監督役はそのまま動き続けますが、権限代行の仕組み（watcher・`hc-permission show` / `approve`）はなくなっています。
4. `~/.local/state/hc-supervisor/`（旧構成の保留要求・監査ログ）は不要です。中身を見て消してかまいません。

## 使い方

- ワーカーを頼む: Herdr app かスマホで `supervisor` を開き、「~/mlbot-dev の Issue #12 と #13 を /issue-development-workflow で PR 作成まで進めて」のように頼みます。監督役はワーカーを `--outlive-parent` で起動し、結果を実測で確かめて報告します。
- ワーカーの文脈が閾値を超えると、`【引き継ぎ】<handoff>` が届き、監督役が同じ worktree で新しいワーカーに続きをさせます（上の「ワーカーの引き継ぎ」）。ユーザーの操作は要りません。引き継ぎが 3 回を超えたときだけ、監督役から報告が来ます。
- ワーカーが判断に迷うと `hc send supervisor` で相談が届き、監督役が仕様・設計を含めて 1 つに決めて返し、`~/.local/share/hc-supervisor/decisions.md` に記録します。後から見るときは監督役に「判断記録を見せて」と頼むか、ファイルを直接開きます。取り消しにくい外部操作と hook に止められた操作が必要なものだけ、監督役のタブに「【確認】…」として質問が出ます。
- 手動セッション: Herdr app で新しいタブを開いて使えます。権限確認は `~/.claude/settings.json` のとおりで、監督役は関与しません（相談したいときは `hc send supervisor`）。
- 監督役の作り直し（`hc-supervisor restart`）: プロンプトや設定を変えたときは、監督役に「再起動して」と頼むか、端末で `hc-supervisor restart` を実行します。ワーカーとのやり取りを止めずに入れ替わります。
  1. 動いている監督役が、進行中のワーカー・回答待ちの相談・未回答の質問を `~/.local/share/hc-supervisor/handoff.md` に書く（端末から実行したときは `【再起動の準備】` の依頼が届き、書き終えるまで最大 10 分待つ）。書かれなければ何も止めずに終わる。
  2. 監督役の terminal は消さず、その中の Claude Code だけを止めて起動し直す（最初の依頼文は起動時と同じ「監督を開始してください。」）。terminal のアドレス（tN）・名前・Herdr app のタブはそのままなので、監督役が起動したワーカーは新しい監督役の子のまま（`hc get <ワーカー>` の `parent` が変わらず、`hc wait --children` で待てる）。監督役が自分で実行したときは、親のない別の terminal（`supervisor-restart`）に切り離して行い、結果を `~/.local/share/hc-supervisor/restart.log` に残す。
     - 仕組み: 監督役の `hc-claude supervisor` は claude を `exec` せず子として動かし、`~/.local/state/hc-claude/<tN>.pid` に自分の pid を書く。`hc-supervisor restart` は `<tN>.restart` に依頼文を書いてから claude を SIGTERM で止め（15 秒で止まらなければ SIGKILL）、`hc-claude` が依頼文で claude を起動し直す。claude が自分で終わったとき（`/exit` など）は `.restart` が無いので、そのまま終わる。
     - 入れ替えられないとき（この仕組みより前の `hc-claude` で起動した監督役など、`<tN>.pid` が無い）は、従来どおり terminal を消して同じ名前・同じタブで作り直し、「新しい監督役の子になりません」と知らせる。この場合、それまでのワーカーの `parent` は消えた terminal を指したままになる。
  3. 新しい監督役は handoff を読み、`role=worker` の terminal の画面を確かめて、入れ替わりの間に届かなかった報告・相談を拾う。ワーカーは `--outlive-parent` なので動き続け、報告先は名前の `supervisor` なので新しい監督役に届く。入れ替わりの数秒に `hc send supervisor` が失敗したワーカーは、報告を画面に書いてターンを終える。
  文脈が大きくなったときも、監督役が同じ手順で自分を作り直します。
- `hc-supervisor` は監督役を `--keep` で起動します。herdr-core の再起動後、監督役の terminal はシェルになります。`hc-supervisor stop` の後に `hc-supervisor` で起動し直してください（シェルに引き継ぎの依頼を打ち込まないよう、`restart` は使いません）。

## 進捗ボード

監督役の画面に出た質問は、その後の出力で流れて見えなくなります。そこで、監督役は今の状態を 1 つのファイルにまとめ直し続けます。

- ファイル: `~/.local/share/hc-supervisor/board.md`（Git 管理外。書くのは監督役だけ）。節は「あなたの対応待ち」「次にやること」「進行中」「完了（直近 5 件）」「要確認の判断」。ユーザーに回した質問は、答えるまで「あなたの対応待ち」に残ります。書き方は [supervisor-prompt.md](../.config/herdr-core/claude/supervisor-prompt.md) の「進捗ボード」。
- 読む: どのセッションからでも `hc-supervisor board`（または `cat` で直接）。
- Herdr app: `board` レイアウトに切り替えると、タブバーの **Changes** ボタンが監督役ボードを開きます。上に hc の状態から自動で出す「あなたの対応待ち」（権限の確認などで止まっているセッション。手動セッションも含む）と「ワーカー」の一覧、下に `board.md` を表示します。行を押すとそのセッションへ移ります（ペインがなければ覗き窓で開く）。ワーカーが作業中なのに `board.md` が 30 分以上更新されていなければ、更新時刻を警告色で出します。

導入（`make link` の後、Herdr app を開いた状態で）:

```bash
herdr-app check ~/.config/herdr-app/mods/supervisor-board   # mod が読み込めるか
herdr-app do layout.switch '{"name":"board"}'               # board レイアウトにする（ctrl-shift-l でも切り替わる）
```

- レイアウトは main の複製です。Herdr app の更新で main が変わっても board には入りません。必要なら main を複製し直し、`changes` ブロックの `content` を `{"mod": "supervisor-board"}` に替えてください。
- mod はファイルごとにリンクしています（フォルダごとだと Herdr app が書く `jsconfig.json` と `*.d.ts` がリポジトリに入るため）。dotfiles 側を編集しても表示が変わらなければ、Herdr app を開き直してください。
- dev の WSLg で動かす Herdr app を前提にしています（`board.md` を Herdr app と同じマシンから読む）。Windows 版 Herdr app から dev を見る構成には対応していません。

## GitHub ruleset（ユーザーが設定する）

force push とブランチの削除を GitHub 側で禁止します。dotfiles と mlbot-dev の両方に設定します。hook はこの変更（`gh api` の ruleset 操作）を拒否するので、admin か Web UI で行います。

Web UI: リポジトリの Settings → Rules → Rulesets → New ruleset → New branch ruleset

- Ruleset name: `protect-history`、Enforcement status: Active
- Bypass list: 空
- Target branches: Include all branches
- Branch rules: 「Restrict deletions」と「Block force pushes」だけにチェック。「Require a pull request before merging」は付けない（dotfiles は main へ直接 push する）。

gh で設定する場合（admin で実行）:

```bash
for repo in taguch1s/dotfiles taguch1s/mlbot-dev; do
  gh api -X POST "repos/$repo/rulesets" --input - <<'EOF'
{
  "name": "protect-history",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~ALL"], "exclude": []}},
  "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}]
}
EOF
done
gh api repos/taguch1s/dotfiles/rulesets   # 確認
```

全ブランチで削除を禁止すると、マージ済みの作業ブランチもリモートから消せなくなります。消したいときは ruleset の Target を `main` などに絞るか、一時的に無効にします。PR の「Automatically delete head branches」も効かなくなります。

## 外出先から操作する

herdr-core の terminal は、どのクライアント（Herdr app、スマホアプリ、`hc attach`）からつないでも同じものを操作できます。

```
スマホ（Herdr アプリ）──Tailscale SSH──> dev（tailscaled）──> herdr-core ──> supervisor / ワーカー
```

1. dev で `tailscale up --ssh --hostname dev` 済みであること（[wsl-dev-distro.md](wsl-dev-distro.md) の手順 4、root 作業は `wsl -d dev -u root`）
2. スマホにも Tailscale を入れ、同じ tailnet に参加する
3. Herdr アプリで `dev` のマシンを追加する

スマホアプリが使えない場合は、Tailscale SSH で dev に入り、`hc attach supervisor` で操作できます（Ctrl+\ で離れる）。

Windows 版 Herdr app から見る場合は、dev をマシンとして追加します（`hc machine add --via 'wsl.exe -d dev -e sh -c' --name dev`）。dev の WSLg で Herdr app を起動する場合は不要です。

### 動かし続けるための条件

- PC がスリープすると止まります。awake-keeper（[remote-access.md](remote-access.md)）は Windows の `powershell.exe` を呼ぶため、Windows のドライブと interop がない dev では動きません。dev で長い作業を任せるときは、Windows の電源設定でスリープを止めておいてください（dev から抑止する仕組みは未対応）。
- WSL がアイドル停止しないよう、dev でも `loginctl enable-linger` を有効にしておきます（admin から複製されていれば有効のまま）。
- herdr-core は PC の再起動後に未完了の作業を再開しません。

## 確認状況

- テスト（`make check` で実行）: 事故よけのルールと hook の入出力は `tests/test_hc_permission.py`、起動ラッパーの role 判定・引数・役割ごとの閾値と、`session-settings.json` の hook は `tests/test_hc_claude.sh`、`hc-supervisor`（`resume-worker` の引数検査・止める順序・引き継ぎ回数を含む）は `tests/test_hc_supervisor.sh`（偽の `hc` を使用）。
- 実機で確認済み（hc 0.1.21、2026-11-14、旧構成で確認したもの）: `hc get --json` の形、Herdr app のラベル `herdr.space` / `herdr.tab` による配置、trust ダイアログ中は `hc run` の最初の依頼文が届かない（`first_message.sent: false`）こと。
- dev の境界（sbx-test、2026-11-14）: [wsl-dev-distro.md](wsl-dev-distro.md) の「確認済みのこと」。
- dev での実機確認が必要なもの（#26 の最後の受け入れ条件）:
  - ワーカーが commit・push・PR まで止まらずに進む（bypassPermissions の初回確認が出ない、テンプレートの依頼文が `hc-claude` の引数として claude に渡る）
  - `.claude/settings.json` を含む merge が通る
  - 事故よけの hook が効く（例: ワーカーで `git push --force` が理由付きで拒否される）
  - 仕様・設計の判断依頼に監督役が自分で回答し、`~/.local/share/hc-supervisor/decisions.md` に記録する
  - スマホ（Tailscale SSH）から dev の hc に届く
- dev での実機確認が必要なもの（#30）: 上の「実機で確かめる」の手順で、ワーカーに guard の警告が入ること、終了後に `sessions.jsonl` に 1 行増え `cwd` がその worktree になること。
- dev での実機確認が必要なもの（#31）: 「ワーカーの引き継ぎ」の「実機で確かめる」の 3 点。`resume-worker` が使う `hc get --json` のラベル（`role`・`handoffs`）と `status.state`、`hc run --timeout` の振る舞いは偽の `hc` でしか確かめていません。導入後、mlbot の Issue 数件で Issue 1 件あたりの重み付きコストと平均文脈を導入前（#17 のコメントの値）と比べ、引き継ぎ 1 回の追加コストより平均文脈の低下で得る分が大きいかを確かめます。
- 導入後の計測が必要なもの（#32）: [worker-prompt.md](../.config/herdr-core/claude/worker-prompt.md) の「ツール出力を絞る」。導入後のワーカー数件で、`claude-token-metrics session` / `report` の L2（`by_tool` の Bash の `raw_bytes` 中央値、`new_info_rate`）と 1 リクエストあたりの文脈増分を導入前（#32 の本文の値）と比べます。下がらなければ、hook で出力を切り詰める対策を別 Issue にします。
