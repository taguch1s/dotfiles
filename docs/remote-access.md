# スマホからの遠隔操作

外出先のスマホから、自宅 PC の WSL 上の tmux に入って Claude Code を使う構成です。

```
スマホ ──(WoL で起動)──> Windows PC
スマホ ──Tailscale SSH──> WSL (tailscaled) ──> tmux ──> Claude Code
                                     awake-keeper ──> ~/.cache/awake/state
Windows: awake-watcher.ps1 ──(\\wsl.localhost で state を読む)──> SetThreadExecutionState (アイドルスリープ抑止)
```

経緯と調査記録: https://github.com/taguch1s/dotfiles/issues/15

## dotfiles で管理しているもの

| ファイル | 役割 |
|---|---|
| `.tmux.conf` | スマホ操作向けの tmux 設定（マウス操作、長い履歴） |
| `.local/bin/awake-hook` | Claude Code の hook。作業中は `~/.cache/awake/busy-<session_id>` を置き、終わったら消す |
| `.local/bin/awake-keeper` | 30秒ごとに条件を調べ、抑止理由（空なら抑止しない）を `~/.cache/awake/state` に書く |
| `.config/systemd/user/awake-keeper.service` | awake-keeper を常駐させる systemd user service |
| `windows/awake-watcher.ps1` | Windows 側の常駐。dev が起動中で state が3分以内に更新され中身があれば `ES_CONTINUOUS \| ES_SYSTEM_REQUIRED` を保持する |
| `.claude/settings.json` | 新規 PC 用の既定値。awake-hook を呼ぶ hook を含む |

awake-keeper がスリープを抑止する条件は次のいずれかです（state に `+` 区切りで書かれる）。

- `claude`: マーカーが30分以内に更新されている（`UserPromptSubmit` / `PreToolUse` で更新し、`Stop` / `SessionEnd` で削除。Esc 中断では Stop が走らずマーカーが残るので期限で打ち切る）
- `claude-tool`: `claude` プロセスの直下にシェルがいる（Bash ツールで長いコマンドを実行中。マーカーが古くなっても抑止を続ける）
- `ssh`: Tailscale SSH のセッションがある（`tailscaled be-child ssh` プロセス）
- `ssh-tmux`: SSH 経由で tmux に attach している
- `hc-working`: herdr-core（hc）に status が `working` の端末がある（エージェントが作業中）。`idle`・`done` などで待っているエージェントは数えない
- `hc-job`: hc の端末で処理が動いている。前面（`hc get` の `foreground`）がシェル以外のプログラムか、`-c` やスクリプトファイルを実行中のシェルなら数える。プロンプトで待つ対話シェルは数えない。また、`~/.local/share/hc-supervisor/heavy.lock`（重い処理の共有ロック）が保持されている間も数える（`/proc/locks` で判定し、ロックは取らない）

hc の判定は `~/.local/bin/hc` を直接呼び（service の PATH に `~/.local/bin` がないため）、各呼び出しに5秒の timeout を付けます。hc や core が応答しなければ、hc の条件を数えずにループを続けます。`awake-keeper --once` で1回だけ判定した理由を出せます。

いずれも成り立たなければ、Windows の電源設定どおり（AC で15分）にスリープします。

## 新しい PC でのセットアップ

### WSL 側（dotfiles で自動化）

```bash
make wsl            # /etc/wsl.conf（systemd=true）。反映には wsl --shutdown が必要
make link           # tmux・awake-* をリンク
make remote-access  # awake-keeper.service を有効化し、linger を設定
```

`~/.claude/settings.json` が既にある PC では、`make sync` で awake-hook を含む dotfiles 管理の hook だけが追加されます（管理外の hook・キーは残ります。`make diff` で事前に確認できます）。

確認方法:

```bash
journalctl --user -u awake-keeper -f   # state: claude / claude-tool / ssh / hc-working / hc-job / idle が出る
```

Windows 側（PowerShell。スタートアップにショートカットを作り、すぐ起動する）:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File \\wsl.localhost\dev\home\issei\dotfiles-main\windows\awake-watcher.ps1 -Mode Install
powershell -NoProfile -ExecutionPolicy Bypass -File $env:LOCALAPPDATA\awake-watcher\awake-watcher.ps1 -Mode Status
```

スクリプトを変更したら `-Mode Install` をやり直す（`%LOCALAPPDATA%\awake-watcher` にコピーして使うため）。

### 手作業の設定

- **Tailscale（WSL 内）**: tailscaled はエージェントを動かす dev ディストリに置く（[wsl-dev-distro.md](wsl-dev-distro.md) の手順 4。dev の作業ユーザーは sudo を使えないので、Windows 側から `wsl -d dev -u root -- tailscale up --ssh --hostname dev`）。admin の tailscaled は止めて tailnet から外す。スマホにも Tailscale を入れて同じ tailnet に参加させる
- **Wake on LAN**: BIOS/UEFI で WoL を有効にし、Windows のデバイスマネージャーで NIC の「Magic Packet でのウェイク」を有効にする。外出先からマジックパケットを送る方法は環境に合わせて用意する
- **Windows の電源設定**: スリープ方式が S3 であることを `powercfg /a` で確認する。Modern Standby（S0 低電力アイドル）の PC では、`ES_SYSTEM_REQUIRED` だけではスリープを防げない場合がある

## 実装上の注意

- dev ディストリは interop と automount が無効で `powershell.exe` を呼べない。そのため判定（WSL 側）と抑止（Windows 側）を state ファイルで分けている。以前の「WSL から powershell.exe を呼ぶ」方式は dev では exit 127 で常に失敗していた
- awake-watcher は dev が停止中なら `\\wsl.localhost` に触れない（触るとディストリが起動する）。`wsl.exe --list --running` で確認してから読む
- `ES_CONTINUOUS` の状態はスレッド単位なので、watcher は1プロセスで呼び続ける。プロセスが落ちれば抑止は自動で解ける
- 確認: 管理者 PowerShell で `powercfg /requests` の SYSTEM に powershell.exe が出る
- Claude Code の sandbox からはホスト側のプロセス一覧が見えない。動作確認は通常のターミナルで行う

herdr-core（Herdr app・スマホの Herdr アプリ）でオーケストレーターを動かす構成は [herdr-core-orchestration.md](herdr-core-orchestration.md) を参照してください。
