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
  │ hc run … claude-worker[-sonnet]（--outlive-parent）  ▲ hc send supervisor（相談・報告）
  ▼                                                      │
ワーカー（dev、role=worker）── commit・push・PR まで止まらない
```

| ファイル | 内容 |
| --- | --- |
| [hc-claude](../.local/bin/hc-claude) | 監督役・ワーカーの起動ラッパー。`/etc/dotfiles-role` が `dev` のときだけ `claude --model <fable|opus|sonnet> --effort <high|medium> --permission-mode bypassPermissions --settings session-settings.json --append-system-prompt-file <role>-prompt.md` を exec し（effort は監督役 high・ワーカー medium。モデルは、監督役の既定が fable で `hc-claude supervisor --model opus` で opus、ワーカーの既定が opus で `hc-claude worker --model sonnet` で sonnet を選べる。下記「監督役のモデル」「ワーカーのモデル」）、それ以外（admin）では起動を拒否する。文脈予算の閾値 `CLAUDE_CTX_GUARD_TOKENS` を役割ごとに渡す（下記「文脈予算とトークン記録」） |
| [hc-supervisor](../.local/bin/hc-supervisor) | 監督役の起動・状態表示・停止と、引き継いだワーカーの起動し直し（`resume-worker`）。dev でだけ起動する |
| [hc-permission](../.local/bin/hc-permission) | 事故よけの deny リスト（`hook` / `check`） |
| [templates/claude-supervisor.md](../.config/herdr-core/templates/claude-supervisor.md) / [claude-worker.md](../.config/herdr-core/templates/claude-worker.md) / [claude-worker-sonnet.md](../.config/herdr-core/templates/claude-worker-sonnet.md) | `hc run` のテンプレート（`command: hc-claude supervisor|worker`、Sonnet のワーカーは `hc-claude worker --model sonnet`） |
| [claude/session-settings.json](../.config/herdr-core/claude/session-settings.json) | hc 上のセッションの設定（`defaultMode: bypassPermissions`、`additionalDirectories`（計測の記録。下記「作業ディレクトリの外の読み取り」）、`sandbox.enabled: false`、`PreToolUse` Bash → `hc-permission hook`、`UserPromptSubmit`・`PostToolUse` → `claude-context-guard`、`SessionEnd` → `claude-token-metrics record`） |
| [claude/supervisor-prompt.md](../.config/herdr-core/claude/supervisor-prompt.md) / [worker-prompt.md](../.config/herdr-core/claude/worker-prompt.md) | 役割のシステムプロンプト |
| [herdr-app/mods/supervisor-board](../.config/herdr-app/mods/supervisor-board/main.js) / [layouts/board.json](../.config/herdr-app/layouts/board.json) | Herdr app の監督役ボード。`board` レイアウト（main の複製）で Changes パネルの中身をこの mod に替える |

- bypassPermissions・sandbox なしは **hc-claude で起動したセッション（監督役・ワーカー）だけ**です。Herdr app で手動で開いたセッションや VS Code の Claude Code は、各ディストリの `~/.claude/settings.json` のまま動きます。
- `--settings` は user / project の設定より上、managed より下で効きます。`skipDangerousModePermissionPrompt`（bypassPermissions の初回確認を出さない）は `--settings` からは効かないため、dev の `~/.claude/settings.json` に `setup-dev-distro.sh` が入れます。
- `permissions.blockReadsOutsideWorkingDirectories: true` を `~/.claude/settings.json` に入れている場合、どの scope からも外せません。ファイルツール（Read など）は作業ディレクトリの外で拒否され、Bash も `bypassPermissions` のまま許可の確認で止まることがあります。hc のセッションでの扱いは下の「作業ディレクトリの外の読み取り」。
- 報告先は名前の `supervisor` に固定しています。監督役を作り直しても、ワーカーの報告は新しい監督役に届きます。

### 作業ディレクトリの外の読み取り

`~/.claude/settings.json` の `permissions.blockReadsOutsideWorkingDirectories: true` は、手動のセッションで作業ディレクトリの外を読ませないための設定です。hc のセッションも同じファイルを読むので、`bypassPermissions` でも次のように止まります（Issue #44。#17 の実機確認ではワーカーが約 10 回止まり、そのたびに監督役が `hc keys` で答えた）。

- ファイルツール（Read・Grep・Glob）: 作業ディレクトリの外は拒否。
- Bash（sandbox なしの hc のセッション）: 作業ディレクトリの外の path を引数・リダイレクト先に書いたコマンド、実行時に決まる path（シェル変数、`$(…)`、`xargs`）、インタープリタへのその場のコード（`python3 -c`、`python3 -` とヒアドキュメント、`bash -c` など）、解析器が追えないコマンド（`cd` を何度もする、サブシェル）、安全と分からない環境変数の前置き、許可リストにない `sed` のスクリプトは、許可の確認（ask）になる。この確認は auto mode の分類器でも通せず、sandbox がこの block を強制しているときだけ出ない。hc のセッションは sandbox なし（上記「なぜ sandbox をやめたか」）なので出る。

hc のセッションでの扱い:

| 方法 | 採否 | 根拠 |
| --- | --- | --- |
| `session-settings.json` で `blockReadsOutsideWorkingDirectories: false` | 採らない（効かない） | settings reference の Scope: "A `true` in any file applies"、`false` は "the same as unset; the block still applies if another file sets `true`"。settings の "Exceptions to managed settings precedence" でも `true` from any scope（v2.1.257 以降） |
| `session-settings.json` の `permissions.additionalDirectories` で計測の記録を足す | 採る | settings の "Lists merge instead of overriding"（リストは設定ファイルの間で足し合わされる。ユーザー設定の `additionalDirectories` は消えない）。`--settings` は user・project・local より上、managed より下。block の対象外になる作業ディレクトリから除かれるのは、リポジトリの設定（`.claude/settings.json` と追跡された `.claude/settings.local.json`）が足したものだけ |
| `hc-claude` の引数に `--add-dir` | 採らない | 対話セッションで信頼されていないフォルダを足すと、先に信頼の確認を出す（permissions の Working directories の注、v2.1.326 以降）。ワーカーが起動時に止まりうる。足したフォルダの `.claude/skills` なども読み込む |
| hc のセッションで sandbox を有効にする | 採らない | #26 の判断（上記「なぜ sandbox をやめたか」）と逆になる |

足したのは `~/.claude/projects`（transcript）、`~/.local/share/claude-token-metrics`（トークン記録）、`~/.local/share/hc-supervisor`（監督役の判断・ボード・handoff）の 3 つです。ユーザー設定（リポジトリ版 `.claude/settings.json`）は変えないので、手動で開いたセッションの読み取りの制限は弱まりません。`tests/test_hc_claude.sh` が、`session-settings.json` の `additionalDirectories` がこの 3 つだけであること、ユーザー設定の block が `true` のままであることを検査します（`hc-claude` が `--add-dir` を渡さないことは、起動引数の完全一致の検査で確かめています）。

`additionalDirectories` では、実行時に決まる path・その場のコード・解析器が追えないコマンドの確認は消えません。ワーカーには [worker-prompt.md](../.config/herdr-core/claude/worker-prompt.md) の「作業ディレクトリの外を読む」で、集計を scratchpad のスクリプト 1 本にして変数も `cd` もない 1 コマンドで実行する、`sed -i` ではなく Edit ツールを使う、などの書き方を指示しています。スクリプトで読むのも作業ディレクトリと上の 3 つだけにし、それ以外の外を読む必要があるときは監督役に相談させます。

根拠（2026-11-22 に確認、Claude Code 2.1.330）: [settings](https://code.claude.com/docs/en/settings)（"Lists merge instead of overriding"、"Exceptions to managed settings precedence"、`--settings` の位置）、[settings reference](https://code.claude.com/docs/en/settings-reference)（`permissions.additionalDirectories`、`permissions.blockReadsOutsideWorkingDirectories`、"Let one directory through the read or write block"）、[permissions](https://code.claude.com/docs/en/permissions)（"Working directories"、"Block file-tool reads and writes outside the working directories"）。Bash の確認の種類は、インストール済みの 2.1.330 のメッセージ（"names a path that is computed at run time"、"runs inline code"、"a command the shell parser cannot analyze asks the person"）で確かめました。

### 事故よけの deny リスト

`hc-permission check '<コマンド>'` で判定を確かめられます。ルールを変えるときは `hc-permission` を編集し、`tests/test_hc_permission.py` に例を足します。

- 止めるもの: `sudo` / `su`（パスワード待ちで止まるため）、force push、リモートのブランチ・tag の削除と mirror push、`git reset --hard`、`git clean -f`、`git branch -D`、`git stash drop|clear`、`filter-branch` などの履歴書き換え、`git config --global|--system`、`gh repo delete|archive|rename|edit`、`gh release delete`、`gh secret|variable|ssh-key|gpg-key`、`gh auth logout|refresh|switch|token|setup-git`、`gh api` の DELETE と ruleset・ブランチ保護の変更、パッケージ・イメージの公開、`rm` での `/`・`~`・`$HOME`・`.`・`..`・`*`、`curl … | sh`、システム操作、`dd of=/dev`、`crontab -r`、`chmod 777`。
- 止めないもの: main への直接 push（dotfiles は main へ push する規約）、`gh pr merge`（ruleset で守る）、秘密情報のパターン（境界の外の話）、`hc keys` / `hc send --force`（同じ境界の中の干渉は許容）。

拒否されたセッションにはエラーが返るだけで、止まりません。ワーカーは別の方法を取るか、監督役に相談します。

### 文脈予算とトークン記録

hc 上の監督役・ワーカーでは、`session-settings.json` の hook で次の 2 つが動きます（Issue #30）。`~/.claude/settings.json` に同じ hook が入っているかどうかに関係なく動きます。

| 何を | hook | 結果 |
| --- | --- | --- |
| 文脈予算の警告 | `UserPromptSubmit`・`PostToolUse` → [claude-context-guard](../.local/bin/claude-context-guard) | 直近リクエストの文脈（input + cache 作成 + cache 読み込み）が閾値を超えると「進行中の作業単位を終え、関連作業が続くときだけ handoff」、上限を超えると「残りの作業量にかかわらず安全な区切りで handoff」の警告が `additionalContext` としてセッションに入る。以後は前回の警告から `CLAUDE_CTX_GUARD_INTERVAL`（既定 50000）増えるたびに再警告し、上限を初めて超えたときは間隔に関係なく上限の警告を出す |
| トークン記録 | `SessionEnd` → [claude-token-metrics](../.local/bin/claude-token-metrics) `record` | セッションの終了時に `~/.local/share/claude-token-metrics/sessions.jsonl` へ 1 行追記する（`cwd` はそのセッションの作業ディレクトリ。`git.repo`・`git.branch`・`hc.terminal`・`hc.role`（`hc-claude` が export する `HC_CLAUDE_ROLE`）も入る）。`claude-token-metrics report` で一覧、`report --by task` で Issue ごとにまとめて見られる。詳しくは [claude-token-metrics.md](claude-token-metrics.md) |

閾値と上限は `hc-claude` が役割ごとに `CLAUDE_CTX_GUARD_TOKENS`（閾値）と `CLAUDE_CTX_GUARD_LIMIT_TOKENS`（上限）として渡します。hc の外（対話）では hook の既定（閾値 200000、上限 225000）が効きます。

| 役割 | 閾値 | 上限 | 上書きする環境変数 | 警告を受けたら |
| --- | --- | --- | --- | --- |
| 監督役 | 200000 | 225000 | `HC_CLAUDE_SUPERVISOR_CTX_GUARD_TOKENS`・`HC_CLAUDE_SUPERVISOR_CTX_GUARD_LIMIT_TOKENS` | 閾値: いまの対応を終えて関連作業が続くなら、上限: 残りにかかわらず、handoff を書いて `hc-supervisor restart`（[supervisor-prompt.md](../.config/herdr-core/claude/supervisor-prompt.md) の「コンテキストの予算と作り直し」） |
| ワーカー | 180000 | 225000 | `HC_CLAUDE_WORKER_CTX_GUARD_TOKENS`・`HC_CLAUDE_WORKER_CTX_GUARD_LIMIT_TOKENS` | 閾値: 進行中の Unit を終えて関連作業が続くなら（最後の Unit の commit・push・PR・完了報告だけなら完了する）、上限: 残りにかかわらず、handoff を更新して `【引き継ぎ】<path>` を監督役に送り、ターンを終える。監督役が同じ worktree で新しいワーカーを起動して続けさせる（下記「ワーカーの引き継ぎ」） |

- 上書き値は `hc-claude` を起動する環境に置きます。正の整数でなければ警告を出して既定を使います（起動は止めません）。
- 呼び出し元の `CLAUDE_CTX_GUARD_TOKENS`・`CLAUDE_CTX_GUARD_LIMIT_TOKENS` は使わず、必ず役割の値で上書きします。監督役の環境がワーカーに引き継がれても、ワーカーの値は監督役の値になりません。
- 「関連作業が続く」の目安は、残りがおよそ 25 リクエスト以上続く見込みかどうかです（下の試算の合算で、200k のとき handoff が得になる残りが 22〜26 リクエスト）。目安であり、数える義務はありません。

#### 閾値と上限の根拠（Issue #61、2026-11-28 の実測）

2026-11-15 以降の 264 セッション（メインの会話のみ）の usage を、API 単価比（入力 1、1 時間 cache 作成 2、output 5、cache 読み込みは Opus 5.5 が 0.05・Fable 5.2 が 0.025）で重み付けして集計しました。

| 項目（中央値） | 対話（59） | ワーカー（130） | 監督役（6） |
| --- | --- | --- | --- |
| 開始時の文脈 | 49k | 55k | 51k |
| 1 リクエストあたりの文脈増加（平均） | 1.7k | 1.7k | 2.2k |
| 旧閾値（150k / 120k / 150k）を超えたセッション | 26 | 63 | 4 |
| 超過後に実行したリクエスト数 | 4 | 7 | 3 |
| handoff 1 回の固定費 F（書き出し＋再開後の状況把握＋新セッション） | 約 27〜31 万 | 約 15〜20 万 | データなし |

- 長い作業を閾値 T ごとに区切り続けると、1 リクエストあたりの余分なコストは `F / n + r · g · n / 2`（n: 1 セッションのリクエスト数、r: cache 読み込みの単価比、g: 1 リクエストの文脈増加）で、最小になるのは `n* = sqrt(2F / (r·g))`、`T* = 再開直後の文脈 + g·n*` です。最適な T* は対話で約 208〜218k、ワーカーで約 181〜197k、全役割の合算で約 174〜206k でした。余分なコストは 150k〜250k でほぼ平ら（100k で最適比 +74%）です。
- 閾値は対話・監督役 200k、ワーカー 180k にしました（監督役はデータが 6 セッションしかないので対話にそろえた）。旧閾値のワーカー（120k）は約 24 リクエストごとに handoff の固定費を払い、余分なコストが最適より 3〜4 割多かった。対話の超過後に残っていた作業は中央値 4 リクエストで、handoff が得になる残り（69〜80）に届かないため、閾値を超えても作業単位を終えて関連作業が続くときだけ handoff します。
- 上限は役割共通の 225k です。Issue の proposal（対話・監督役 300k、ワーカー 250k）から外し、自動 compact の手前に置きました。Claude Code 2.1.329〜2.1.331 の自動 compact は全 3 件が文脈約 243〜246k で起きており（Opus 5.5 のワーカー 2 件、Fable 5.2 の対話 1 件）、300k / 250k では警告より先に compact が起きます。225k なら compact まで約 18k（8〜10 リクエスト）の余裕で handoff を書けます。Claude Code の版が変わって compact の位置が動いたら、上限を見直してください。
- #31 の「1 つの Issue を大きな文脈のまま最後まで進めない」方針は緩めました。#31 は cache 読み込みを入力の 0.1 倍で見積もっていた時点の判断で、Opus 5.5 の 0.05 倍では文脈を持ち越すコストが半分になり、handoff の固定費の方が重くなるためです。
- 限界: 重みは API 単価比で、サブスクリプションの使用率の重み付けは未確定（#20）。再開後の状況把握は最初の Edit/Write までのコストで近似し、対話（n=7）と監督役（記録なし）は精度が低い。旧閾値で打ち切られたデータなので、引き上げ後の分布は実測していない。長い文脈での応答品質の低下は計算に入れていない。
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

タスク単位の記録（#48）は、Issue のワーカーを 1 件動かして確かめます。

```bash
# ワーカーの SessionEnd の後（監督役がワーカーの terminal を閉じた後）
tail -n 1 ~/.local/share/claude-token-metrics/sessions.jsonl | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["git"], r["hc"], r["ctx_budget"])'
# git.repo・git.branch（feature/issue-<n>-…）、hc.role = worker、hc.terminal（tN）、ctx_budget 180000 が入る
claude-token-metrics report --by task --since "$(date +%F)"   # <repo>#<n> の行が出る（監督役は supervisor の行）
```

`make link` で `~/.local/bin/claude-context-guard` と `~/.local/bin/claude-token-metrics` がリンクされている必要があります。

### ワーカーの引き継ぎ（文脈の区切り）

セッションは自分で `/clear` できず、ワーカーは他のエージェントを起動できません。そこで、文脈が閾値を超えて作業単位を終えた時点で関連作業が続くワーカー（または上限を超えたワーカー）は handoff を残して止まり、監督役が同じ worktree で新しいワーカーを起動して続きから再開させます（Issue #31、#61）。毎リクエストの cache 読み込み（≒ リクエスト数 × 平均文脈）を下げるためですが、新しいワーカーは開始時の約 55k を cache 作成として払い直し、状況把握にもコストがかかるので、残りが短いときは handoff せずに終えます（上の「閾値と上限の根拠」）。

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
- 起動し直したワーカーの閾値は、テンプレート（`claude-worker` / `claude-worker-sonnet`）どおり既定（閾値 180000、上限 225000）です。
- 起動し直したワーカーのモデルは、前のワーカーのラベル `model` と同じです（下記「ワーカーのモデル」）。

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

### 監督役のモデル

- 監督役のモデルは Fable（既定）か Opus で、起動のときに選びます（ユーザーの判断、2026-11-27。それまでは opus 固定）。
- `hc-supervisor start --model <fable|opus>` で選びます。fable はテンプレート `claude-supervisor`、opus は `claude-supervisor-opus`（`hc-claude supervisor --model opus`）で起動し、terminal のラベル `model` に残します。`hc-claude` は、許可しない名前を警告して fable で起動します。
- `hc-supervisor restart --model <fable|opus>` は、同じ terminal のままモデルも替えます（`<状態>/<tN>.model` に名前を書き、`hc-claude` が起動し直す claude に渡す）。`--model` を付けなければ、いまのモデルのままです。terminal を作り直す場合は、ラベル `model`（無い・不正なら fable）で起動します。
- モデルを選べるようになる前に起動した監督役は、同じ terminal のままではモデルを替えられません（古い `hc-claude` が動いているため）。`hc-supervisor stop` → `hc-supervisor start --model ...` で起動し直します。

### ワーカーのモデル

監督役は、ワーカーを起動するたびにモデル（Opus / Sonnet）を選びます（Issue #33）。既知パターンの局所変更を単価の安い Sonnet に回し、1 セッションあたりの使用量を下げるためです。監督役自身は判断の質を優先して Opus のままです。

- 選び方の正本は [supervisor-prompt.md](../.config/herdr-core/claude/supervisor-prompt.md) の「モデルの選び方」です。`issue-development-workflow` の経路の見立てで、Full → Opus、Compact / Fast → Sonnet、迷ったら Opus。Sonnet で同じ作業が 2 回うまくいかなければ（失敗・ブロック・差し戻し）、Sonnet で続けずユーザーに報告し、Opus で起動し直すことを推奨します。
- 起動: Opus は従来どおり `claude-worker`、Sonnet は `claude-worker-sonnet` テンプレート（`command: hc-claude worker --model sonnet`）で起動し、どちらもラベル `model=<opus|sonnet>` を付けます。`hc run` は呼び出し元の環境変数を terminal に渡さないので、モデルは環境変数ではなくテンプレート（= `hc-claude` の引数）で渡します。
- `hc-claude worker --model <名前>`: 役割の直後に置きます。許可は `opus` と `sonnet` だけで（Claude Code の `--model` が受け付ける別名。`claude --help` で確認）、それ以外は警告して opus で起動します（起動は止めない）。`--model` を付けなければ opus で、従来の挙動と同じです。監督役（`hc-claude supervisor`）への `--model` は警告して無視します。
- 引き継ぎ（`resume-worker`）は、前のワーカーのラベル `model` と同じモデルで起動します（ラベルが無い・不正なら opus）。`--model <opus|sonnet>` で明示もできますが、監督役のプロンプトでは、ラベルの無いワーカーのモデルを補うときだけ使い、引き継ぎでモデルを変えません（途中でのモデル切り替えは #33 の対象外）。許可しない `--model` は、前のワーカーを止めずに拒否します。
- 比べ方: 監督役は進捗ボードの「進行中」「完了」に `[<モデル> / <経路>]` と差し戻しの回数を書き、ワーカーは PR 本文に `ワーカー: <モデル>（監督役の見立て: <経路>）` を書きます。Issue 1 件あたりのコストは `claude-token-metrics report` の `by_model` で、完了率と差し戻しの回数は PR とボードで、Opus の作業と比べます。単価・使用率の換算は推測で決めず、#20 の calibrate（`by_model`）の実データで確かめます。

### ワーカーの同時数

監督役が同時に動かすワーカーの数は、固定の上限ではなく、起動の直前のホストの資源から決めます（Issue #54）。以前は監督役のプロンプトに「既定で 3 つまで」とあるだけでしたが、3 つ動かしても CPU は 25% 程度で、メモリが 90% 程度まで使われていました。dev と admin は同じ WSL2 VM（[`windows/.wslconfig`](../windows/.wslconfig): memory 10GB、swap 4GB、論理 CPU 20）を共有し、`/proc/meminfo` は VM 全体の値なので、admin の Docker なども差し引かれた空きで決まります。

`hc-supervisor capacity [--json]`（読み取りだけ。admin でも使える）が、今あと何個ワーカーを起動してよいか（`slots`）と、効いている制約（`limit_by`）、根拠の値を出します。

| 制約（`limit_by` の名前） | 式 | 入力 |
| --- | --- | --- |
| `memory` | `floor((MemAvailable − reserve) / worker_mem)`、`reserve = max(reserve_min, MemTotal × reserve_pct)` | `/proc/meminfo` |
| `memory_pressure` | `some avg10 > psi_limit` なら 0、それ以外は制約なし | `/proc/pressure/memory`（無ければ無視） |
| `cpu` | `floor((nproc × cpu_target − load1) / worker_cpu)` | `/proc/loadavg`、`nproc`（CPU affinity の数） |
| `max_workers` | `max_workers − 動いている role=worker の数` | `hc ls --json`（`state` が `finished` のものは数えない） |

`slots = max(0, min(各制約))`。`limit_by` は最小の値を出した制約で、同じ値の制約が複数あればカンマで並べます。

| 値 | 既定 | 環境変数（監督役の環境） |
| --- | --- | --- |
| `worker_mem`（1 ワーカーのメモリの見積もり） | 1536 MiB | `HC_SUPERVISOR_WORKER_MEM_MB` |
| `reserve_min`（予約の下限） | 1536 MiB | `HC_SUPERVISOR_MEM_RESERVE_MB` |
| `reserve_pct`（予約の MemTotal に対する割合） | 15 | `HC_SUPERVISOR_MEM_RESERVE_PCT` |
| `worker_cpu`（1 ワーカーの CPU の見積もり） | 1.0 | `HC_SUPERVISOR_WORKER_CPU` |
| `cpu_target`（使ってよい CPU の割合） | 0.8 | `HC_SUPERVISOR_CPU_TARGET` |
| `psi_limit`（メモリの PSI の閾値） | 10 | `HC_SUPERVISOR_PSI_MEM_LIMIT` |
| `max_workers`（資源に関係ない上限） | 8 | `HC_SUPERVISOR_MAX_WORKERS` |
| 値が読めない制約の slots | 1 | `HC_SUPERVISOR_FALLBACK_SLOTS` |

- 値が読めないとき（`/proc` が読めない、`hc ls --json` が失敗する・形が違う）は、その制約を安全側の値（既定 1）にし、`unknown` と理由を出して終了コード 0 で終わります。使えない環境変数の値（数でない、負）は既定値にして `notes` に出します。
- 既定値の根拠: Claude Code 1 セッションは常駐で 0.5〜1GB、テストや `uv sync` の間はさらに増えるので、1 ワーカー 1.5GiB と見積もります。10GB の VM では MemTotal が約 9.7GiB で、予約は 1.5GiB（15% の 1.46GiB より下限が大きい）です。空きが 5.2GiB なら `memory` は 2、3 ワーカーでメモリ 90% 程度（空き約 1GiB）なら 0 になります。CPU は 20 × 0.8 = 16 から load1 を引くので、普段は効きません。
- 変え方: capacity は監督役が Bash ツールで実行するので、上の環境変数は Bash ツールが読み込むシェルの設定（dev の `~/.zshrc` など）に `export` で書き、`hc-supervisor restart` で監督役を作り直して反映します（`hc run` は呼び出し元の環境変数を terminal に渡しません）。試すだけなら `HC_SUPERVISOR_WORKER_MEM_MB=1024 hc-supervisor capacity` のように前に付けます。重い処理を遠隔に回して 1 ワーカーあたりの使用量が下がったら、`HC_SUPERVISOR_WORKER_MEM_MB` を下げます。
- 監督役の使い方（[supervisor-prompt.md](../.config/herdr-core/claude/supervisor-prompt.md) の「同時に動かす数」）: 起動の前に capacity を 1 回測り、`slots` 個まで続けて起動します。起動直後のワーカーはまだメモリを使っていないので、続けて起動する間は測り直しません。足りない分は進捗ボードの「次にやること」に `待機（<limit_by>）` で並べ、ワーカーが終わって `hc wait --children any` から戻ったときに測り直します。空きを待つポーリングはしません。ワーカーの自動停止・自動起動はしません（判断は監督役）。
- 検証用: `HC_SUPERVISOR_PROC_DIR`（`/proc` の代わり）と `HC_SUPERVISOR_NPROC`（CPU の数）で入力を差し替えられます。`tests/test_hc_supervisor.sh` が、偽の `/proc` と偽の `hc ls --json` で各制約が効く場合と値が読めない場合を確かめます。

### 報告・相談の形と受理の確認

監督役は、メッセージが届くたびに自分の文脈（実測で平均 80k〜109k）を読み直します。監督役のコストは、ほぼ「リクエスト数 × 平均文脈」なので、ワーカーからのメッセージの数と長さ、受理での確認の回数を減らします（Issue #34）。相談の禁止や回数の上限は設けません（判断の質を下げないため）。

- ワーカー（[worker-prompt.md](../.config/herdr-core/claude/worker-prompt.md) の「報告と相談の形」）: 監督役に送るのは `【相談】`・`【完了】`・`【中断】`・`【引き継ぎ】` だけで、途中経過は送りません。相談は同じ Unit の論点を番号付きで 1 通にまとめ、回答に左右されない作業は待たずに進めます。完了・中断の報告は `PR:`・`検証:`・`未解決:`・`判断:`・`詳細:` の各 1 行で、長い内容はファイルに書いて `詳細:` に path を書きます。`【引き継ぎ】<path>` の 1 行（#31）は変えていません。
- 監督役（[supervisor-prompt.md](../.config/herdr-core/claude/supervisor-prompt.md) の「待ち方」「受理時の確認の型」）: 待つのは `hc wait --children any` だけで、`reason: timeout` では何も読まずに待ち直します。受理では、`gh pr view --json state,isDraft,mergeable,headRefOid,body,statusCheckRollup` と `git -C <worktree> status`・`log` を 1 回の Bash 呼び出しで出し、要る値だけを確かめます（実測は省きません）。`hc read` で画面を読むのは、報告が欠けたときだけです。複数の論点がある相談には、論点ごとに判断記録を残して 1 通で返します。

### フォルダ信頼（trust）

trust は git リポジトリのルートに付き、worktree はメイン checkout のルートを使います。リポジトリごとに 1 回 trust すれば、そのリポジトリの worktree では出ません。dev は admin の `~/.claude.json` を複製するので、既存のリポジトリは trust 済みです。新しいリポジトリで出たら、Herdr app かスマホで「Yes, I trust this folder」を選びます（既定は「No, exit」）。`$HOME` で起動したときの trust は保存されません。

## 導入（dev で行う）

前提: [wsl-dev-distro.md](wsl-dev-distro.md) の手順で dev を作り、`verify-dev-boundary.sh` がすべて OK であること。

```bash
make link          # hc-claude・hc-supervisor・hc-permission・テンプレート・役割ファイルをリンク
hc templates       # claude-supervisor / claude-worker / claude-worker-sonnet が出ることを確認
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
- herdr-core は、最初に `hc` を呼んだプロセスの環境変数で起動し、terminal はその環境を引き継ぎます。`hc-supervisor` が `first message NOT sent: it exited before it was ready` で失敗し、その terminal の画面（`hc read <tN>`）が `sh: 1: hc-claude: not found` なら、core の PATH に `~/.local/bin` がありません（実機 2026-11-28。PC の再起動直後に systemd の `awake-keeper` が `hc ls` で core を起動していた。いまの `awake-keeper` は core が動いていなければ `hc` を呼ばない）。対話シェルで `hc server stop` の後に `hc server start` を実行して core を起動し直してから、`hc-supervisor` を実行してください。動いている terminal のプログラムは止まります（`--keep` の terminal はシェルになります）。

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

- テスト（`make check` で実行）: 事故よけのルールと hook の入出力は `tests/test_hc_permission.py`、起動ラッパーの role 判定・引数・ワーカーのモデル（`--model` の検査とテンプレート）・役割ごとの閾値と、`session-settings.json` の hook・読める範囲（`additionalDirectories`）は `tests/test_hc_claude.sh`、`hc-supervisor`（`resume-worker` の引数検査・止める順序・引き継ぎ回数・モデルの引き継ぎ、`capacity` の各制約と値が読めない場合を含む）は `tests/test_hc_supervisor.sh`（偽の `hc` を使用）。
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
- dev での実機確認と導入後の計測が必要なもの（#33）: 監督役が `claude-worker-sonnet` で起動したワーカーの transcript の model が Sonnet になること、`claude-worker` では Opus のままであること（hc のテンプレートの `command` に `--model sonnet` を足しても引数として渡ることは、偽の `hc` でしか確かめていません）。導入後、Sonnet で実行した Issue の PR までの完了率・差し戻しの回数と Issue 1 件あたりのコスト（`by_model`）を、Opus の場合と比べます。
- dev での実機確認が必要なもの（#48）: 上の「実機で確かめる」のタスク単位の記録。ワーカーの SessionEnd の行に `git.*`・`hc.role` = worker・`hc.terminal` が入り、`report --by task` にその Issue の行が出ること。過去の transcript での確認（2026-11-22、一時の `XDG_DATA_HOME` で `rescan --since 2026-11-21` → `report --by task`）: 28 セッションを 19 タスクにまとめ、`mlbot-dev#238`・`dotfiles#48` などが Issue ごとの行になり、`restart.kind` は fresh 15・resume_worker 8・resume_supervisor 5、`cache_rewrite_by_cause` は idle 4・tool_wait 5 でした。#48 より前の記録には `hc` が無いので、監督役のセッションは `supervisor` ではなく `cwd:~/.local/share/hc-supervisor` の行になり、merge 後に worktree を消した #46・#47 は `git.repo` が取れず `?#46`・`?#47` になります。
- dev での実機確認が必要なもの（#44）: cwd が dotfiles の worktree のワーカーで、`~/.claude/projects` の transcript と `~/.local/share/claude-token-metrics/sessions.jsonl` を読む集計（Read ツールと、scratchpad のスクリプトを `python3 <絶対 path>` で実行する Bash の両方）が許可の確認なしで通ること。`--settings` の `additionalDirectories` が block の対象外になることは公式ドキュメントの記述（リストの足し合わせと、除かれるのはリポジトリの設定だけ）とインストール済みの 2.1.330 のコードの読解からの判断で、hc のワーカーではまだ確かめていません。`~/` で書いた entry が展開されることも同時に確かめます（ユーザー設定の `additionalDirectories` は `~/` の entry で効いている）。通らなければ `hc-claude` で `--add-dir` を渡す案（信頼の確認が出ないか確かめる）に切り替えます。
- dev での実機確認が必要なもの（#54）: `hc-supervisor capacity` が使う `hc ls --json` の形（配列か `{"terminals": [...]}` か、各 terminal に `labels.role`・`state` があるか）は、この sandbox で core を起動できず偽の `hc` でしか確かめていません。形が違うと `max_workers` が安全側の 1 になり（`unknown` に出る）、`slots` が 1 に抑えられます。dev で `hc-supervisor capacity --json` の `unknown` が空で `running_workers` が `hc ls` のワーカー数と合うことを確かめます。既定の見積もり（1 ワーカー 1.5GiB）は、導入後に複数ワーカーを動かしたときの MemAvailable の減り方で見直します。
- 導入後の計測が必要なもの（#34）: 上の「報告・相談の形と受理の確認」。導入後の監督役で、`claude-token-metrics report` の受理 1 件あたりのリクエスト数と平均文脈を、導入前（#34 の本文の値: 103 リクエスト・平均文脈 109k、31 リクエスト・平均 80k）と比べます。受理の確認の `gh pr view --jq` は、CI の無い PR（このリポジトリ）と CI のある公開リポジトリの PR（成功・失敗・実行中・StatusContext の `PENDING`）で出力を確かめました。
