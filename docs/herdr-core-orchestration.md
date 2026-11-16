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
- ユーザーに回るのは、取り消しにくい外部操作（デプロイ、課金、外部サービスへの書き込みなど）と、事故よけ hook に止められた操作が必要なものだけです。

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
| [hc-claude](../.local/bin/hc-claude) | 監督役・ワーカーの起動ラッパー。`/etc/dotfiles-role` が `dev` のときだけ `claude --model opus --effort <high|medium> --permission-mode bypassPermissions --settings session-settings.json --append-system-prompt-file <role>-prompt.md` を exec し（effort は監督役 high・ワーカー medium）、それ以外（admin）では起動を拒否する |
| [hc-supervisor](../.local/bin/hc-supervisor) | 監督役の起動・状態表示・停止（dev でだけ起動） |
| [hc-permission](../.local/bin/hc-permission) | 事故よけの deny リスト（`hook` / `check`） |
| [templates/claude-supervisor.md](../.config/herdr-core/templates/claude-supervisor.md) / [claude-worker.md](../.config/herdr-core/templates/claude-worker.md) | `hc run` のテンプレート（`command: hc-claude supervisor|worker`） |
| [claude/session-settings.json](../.config/herdr-core/claude/session-settings.json) | hc 上のセッションの設定（`defaultMode: bypassPermissions`、`sandbox.enabled: false`、`PreToolUse` Bash → `hc-permission hook`） |
| [claude/supervisor-prompt.md](../.config/herdr-core/claude/supervisor-prompt.md) / [worker-prompt.md](../.config/herdr-core/claude/worker-prompt.md) | 役割のシステムプロンプト |

- bypassPermissions・sandbox なしは **hc-claude で起動したセッション（監督役・ワーカー）だけ**です。Herdr app で手動で開いたセッションや VS Code の Claude Code は、各ディストリの `~/.claude/settings.json` のまま動きます。
- `--settings` は user / project の設定より上、managed より下で効きます。`skipDangerousModePermissionPrompt`（bypassPermissions の初回確認を出さない）は `--settings` からは効かないため、dev の `~/.claude/settings.json` に `setup-dev-distro.sh` が入れます。
- `permissions.blockReadsOutsideWorkingDirectories: true` を `~/.claude/settings.json` に入れている場合、どの scope からも外せません。ワーカーのファイルツール（Read など）は worktree の外で止まります（Bash は対象外）。
- 報告先は名前の `supervisor` に固定しています。監督役を作り直しても、ワーカーの報告は新しい監督役に届きます。

### 事故よけの deny リスト

`hc-permission check '<コマンド>'` で判定を確かめられます。ルールを変えるときは `hc-permission` を編集し、`tests/test_hc_permission.py` に例を足します。

- 止めるもの: `sudo` / `su`（パスワード待ちで止まるため）、force push、リモートのブランチ・tag の削除と mirror push、`git reset --hard`、`git clean -f`、`git branch -D`、`git stash drop|clear`、`filter-branch` などの履歴書き換え、`git config --global|--system`、`gh repo delete|archive|rename|edit`、`gh release delete`、`gh secret|variable|ssh-key|gpg-key`、`gh auth logout|refresh|switch|token|setup-git`、`gh api` の DELETE と ruleset・ブランチ保護の変更、パッケージ・イメージの公開、`rm` での `/`・`~`・`$HOME`・`.`・`..`・`*`、`curl … | sh`、システム操作、`dd of=/dev`、`crontab -r`、`chmod 777`。
- 止めないもの: main への直接 push（dotfiles は main へ push する規約）、`gh pr merge`（ruleset で守る）、秘密情報のパターン（境界の外の話）、`hc keys` / `hc send --force`（同じ境界の中の干渉は許容）。

拒否されたセッションにはエラーが返るだけで、止まりません。ワーカーは別の方法を取るか、監督役に相談します。

### フォルダ信頼（trust）

trust は git リポジトリのルートに付き、worktree はメイン checkout のルートを使います。リポジトリごとに 1 回 trust すれば、そのリポジトリの worktree では出ません。dev は admin の `~/.claude.json` を複製するので、既存のリポジトリは trust 済みです。新しいリポジトリで出たら、Herdr app かスマホで「Yes, I trust this folder」を選びます（既定は「No, exit」）。`$HOME` で起動したときの trust は保存されません。

## 導入（dev で行う）

前提: [wsl-dev-distro.md](wsl-dev-distro.md) の手順で dev を作り、`verify-dev-boundary.sh` がすべて OK であること。

```bash
make link          # hc-claude・hc-supervisor・hc-permission・テンプレート・役割ファイルをリンク
hc templates       # claude-supervisor / claude-worker が出ることを確認
hc-supervisor      # 監督役を起動。Herdr app のタブから実行すると、そのスペースに「supervisor」タブが出る
hc-supervisor status
hc-supervisor stop # 止める（ワーカーは止まらない）
hc-supervisor restart  # 引き継ぎを書かせてから作り直す（プロンプトや設定の変更を反映する）
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
- ワーカーが判断に迷うと `hc send supervisor` で相談が届き、監督役が仕様・設計を含めて 1 つに決めて返し、`~/.local/share/hc-supervisor/decisions.md` に記録します。後から見るときは監督役に「判断記録を見せて」と頼むか、ファイルを直接開きます。取り消しにくい外部操作と hook に止められた操作が必要なものだけ、監督役のタブに「【確認】…」として質問が出ます。
- 手動セッション: Herdr app で新しいタブを開いて使えます。権限確認は `~/.claude/settings.json` のとおりで、監督役は関与しません（相談したいときは `hc send supervisor`）。
- 監督役の作り直し（`hc-supervisor restart`）: プロンプトや設定を変えたときは、監督役に「再起動して」と頼むか、端末で `hc-supervisor restart` を実行します。ワーカーとのやり取りを止めずに入れ替わります。
  1. 動いている監督役が、進行中のワーカー・回答待ちの相談・未回答の質問を `~/.local/share/hc-supervisor/handoff.md` に書く（端末から実行したときは `【再起動の準備】` の依頼が届き、書き終えるまで最大 10 分待つ）。書かれなければ何も止めずに終わる。
  2. 古い監督役を止め、同じ名前 `supervisor`・Herdr app の同じタブで起動し直す。監督役が自分で実行したときは、親のない別の terminal（`supervisor-restart`）に切り離して行い、結果を `~/.local/share/hc-supervisor/restart.log` に残す。
  3. 新しい監督役は handoff を読み、`role=worker` の terminal の画面を確かめて、入れ替わりの間に届かなかった報告・相談を拾う。ワーカーは `--outlive-parent` なので動き続け、報告先は名前の `supervisor` なので新しい監督役に届く。入れ替わりの数秒に `hc send supervisor` が失敗したワーカーは、報告を画面に書いてターンを終える。
  文脈が大きくなったときも、監督役が同じ手順で自分を作り直します。
- `hc-supervisor` は監督役を `--keep` で起動します。herdr-core の再起動後、監督役の terminal はシェルになります。`hc-supervisor stop` の後に `hc-supervisor` で起動し直してください（シェルに引き継ぎの依頼を打ち込まないよう、`restart` は使いません）。

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

- テスト（`make check` で実行）: 事故よけのルールと hook の入出力は `tests/test_hc_permission.py`、起動ラッパーの role 判定と引数は `tests/test_hc_claude.sh`、`hc-supervisor` は `tests/test_hc_supervisor.sh`（偽の `hc` を使用）。
- 実機で確認済み（hc 0.1.21、2026-11-14、旧構成で確認したもの）: `hc get --json` の形、Herdr app のラベル `herdr.space` / `herdr.tab` による配置、trust ダイアログ中は `hc run` の最初の依頼文が届かない（`first_message.sent: false`）こと。
- dev の境界（sbx-test、2026-11-14）: [wsl-dev-distro.md](wsl-dev-distro.md) の「確認済みのこと」。
- dev での実機確認が必要なもの（#26 の最後の受け入れ条件）:
  - ワーカーが commit・push・PR まで止まらずに進む（bypassPermissions の初回確認が出ない、テンプレートの依頼文が `hc-claude` の引数として claude に渡る）
  - `.claude/settings.json` を含む merge が通る
  - 事故よけの hook が効く（例: ワーカーで `git push --force` が理由付きで拒否される）
  - 仕様・設計の判断依頼に監督役が自分で回答し、`~/.local/share/hc-supervisor/decisions.md` に記録する
  - スマホ（Tailscale SSH）から dev の hc に届く
