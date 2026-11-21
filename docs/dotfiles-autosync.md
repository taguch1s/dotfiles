# dotfiles の自動同期（dotfiles-autosync）

Claude Code のセッションを開くと、`SessionStart` hook の `~/.local/bin/dotfiles-autosync` が
dotfiles の checkout（`~/.local/bin` のリンク先。この端末では `/home/issei/dotfiles-main`）を
`origin/main` に合わせ、新しいリンクと `~/.claude/settings.json` などの管理設定を反映する（#29）。
人が `git pull` / `make link` / `make sync` を覚えていなくても、次のセッションから修正が効く。

## いつ、何をするか

1. 前回の実行から 30 分（`DOTFILES_AUTOSYNC_INTERVAL` 秒、既定 1800）たっていなければ何もしない。
   同時に開いた複数のセッションは、ロックを取れた 1 本だけが実行する（ほかは何もしない）。
   実行した時刻は結果にかかわらず `${XDG_STATE_HOME:-~/.local/state}/dotfiles-autosync/state.json` に残す。
2. checkout が `main` で、作業ツリーが clean（未追跡ファイルも無い）なら、`git fetch origin main` し、
   `origin/main` が HEAD の子孫のときだけ `git merge --ff-only` する。force・rebase・stash はしない。
3. 更新後の checkout で `manage-dotfiles-configs.py plan` を実行し、ずれがあるものだけを反映する。
   - まだ何も無い target へのリンク配置（`link --missing-only`）。既存のファイルや別のリンクがある target は
     退避も置き換えもせず「未配置」と知らせる（置き換えるときは手で `make link`）。
   - 管理キーの同期（`make sync` と同じ。Codex の `[features]`、`~/.claude/settings.json` の管理 hook・`statusLine`）。
   origin に届かないときも、checkout が main・clean なら手元の内容でこの反映は行う。
4. 伝えることがあるときだけ、1 行を出す。何も無ければ何も出さない。全体の時間制限は 20 秒
   （`DOTFILES_AUTOSYNC_TIMEOUT`）で、超えたら git の子プロセスごと止める。どの失敗でも exit 0 で、
   セッションは通常どおり始まる。

出力の例:

```text
dotfiles: 2 commit 更新、リンク 1 件を追加、設定 1 件を同期
dotfiles: 更新していません（/home/issei/dotfiles-main に未コミットの変更があります）
dotfiles: 更新していません（/home/issei/dotfiles-main は main ではなく feature/x を checkout しています）
dotfiles: 更新していません（main と origin/main が分岐しています。/home/issei/dotfiles-main で merge してください）
dotfiles: origin を確認できません（fatal: unable to access ...）
dotfiles: 20 秒の時間内に終わらなかったため中断しました
```

`SessionStart` hook の stdout はセッションの文脈に入るため、出力は 1 行以内にしてある。

## 更新できないとき

| 表示 | 対応 |
| --- | --- |
| 未コミットの変更があります | `git -C ~/dotfiles-main status` で確認し、commit するか片付ける |
| main ではなく … を checkout しています | `dotfiles-main` は main 専用。作業は worktree で行い、`git -C ~/dotfiles-main switch main` |
| 分岐しています | `dotfiles-main` で `git merge origin/main`（force push はしない）して push |
| origin より N commit 先行（未 push） | `dotfiles-main` で `git push origin main` |
| リンク N 件は既存のファイルがあり未配置 | `make doctor` で確認し、置き換えてよければ `make link`（既存は `.dotfiles-backup-<時刻>` に退避） |
| 設定の同期に失敗 | `make diff` で確認し、`make sync` のエラーに従って直す |

間隔を待たずに今すぐ確かめるときは `dotfiles-autosync --force` を実行する。

## 自動で反映されるもの・手動のもの

| 対象 | 自動同期 | 手動 |
| --- | --- | --- |
| `dotfiles-main` の checkout | fast-forward だけ | 分岐・未コミット変更・main 以外のとき |
| `mode = "link"` | 中身は checkout の更新で追従。新しいエントリは target が空なら配置 | 既存ファイルの置き換え（`make link`）、消したエントリの古いリンクの片付け |
| `mode = "merge-toml-features"` / `"merge-json-managed"` | 管理キー・管理 hook を同期 | 競合・解析できない設定の修正 |
| `mode = "copy-if-missing"` | しない | `make codex-config` |
| `mode = "manual"`（`make wsl`、`make dev-mode`、dev ディストリの setup など） | しない | 各 make target・docs の手順 |
| Herdr 連携（`make integration`）、ツールの導入（`make bootstrap`）、Git hook（`make hooks`） | しない | 各 make target |

- 各ディストリは自分の checkout だけを更新する（admin ディストリへは書き込まない）。
- Codex 側のセッション開始では動かない（Claude Code の `SessionStart` だけ）。
- 同期で変わった `~/.claude/settings.json` の hook は、次に開くセッションから確実に効く。
  セッションの途中で更新されたスクリプトは、hook・CLI として次に呼ばれたときから新しい内容になる
  （実行中の長いプロセスは古いまま）。

## 登録と導入

リポジトリ版 `.claude/settings.json` の `SessionStart` に、管理 hook（`dotfiles.toml` の `hook_commands`）として
登録してある。Herdr の `herdr-agent-state.sh` など管理外の `SessionStart` hook は残る。

```json
{"type": "command", "command": "~/.local/bin/dotfiles-autosync || true", "timeout": 30}
```

この仕組みが入る前の端末では、一度だけ手で反映する。

```bash
git -C ~/dotfiles-main pull --ff-only
make -C ~/dotfiles-main link   # ~/.local/bin/dotfiles-autosync を配置
make -C ~/dotfiles-main sync   # SessionStart hook を ~/.claude/settings.json へ
```
