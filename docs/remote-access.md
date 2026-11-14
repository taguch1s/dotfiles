# スマホからの遠隔操作

外出先のスマホから、自宅 PC の WSL 上の tmux に入って Claude Code を使う構成です。

```
スマホ ──(WoL で起動)──> Windows PC
スマホ ──Tailscale SSH──> WSL (tailscaled) ──> tmux ──> Claude Code
                                     awake-keeper ──> SetThreadExecutionState (Windows のアイドルスリープ抑止)
```

経緯と調査記録: https://github.com/taguch1s/dotfiles/issues/15

## dotfiles で管理しているもの

| ファイル | 役割 |
|---|---|
| `.tmux.conf` | スマホ操作向けの tmux 設定（マウス操作、長い履歴） |
| `.local/bin/awake-hook` | Claude Code の hook。作業中は `~/.cache/awake/busy-<session_id>` を置き、終わったら消す |
| `.local/bin/awake-keeper` | 60秒ごとに条件を調べ、成り立てば Windows のアイドルタイマーをリセットする |
| `.config/systemd/user/awake-keeper.service` | awake-keeper を常駐させる systemd user service |
| `.claude/settings.json` | 新規 PC 用の既定値。awake-hook を呼ぶ hook を含む |

awake-keeper がスリープを抑止する条件は次のどちらかです。

- Claude が作業中: マーカーが60分以内に更新されている（`UserPromptSubmit` / `PreToolUse` で更新し、`Stop` / `SessionEnd` で削除）
- SSH 経由で tmux に attach している: クライアントの環境変数に `SSH_CONNECTION` があるか、祖先プロセスに `sshd` / `tailscaled` がいる

どちらも成り立たなければ、Windows の電源設定どおり（AC で15分）にスリープします。

## 新しい PC でのセットアップ

### WSL 側（dotfiles で自動化）

```bash
make wsl            # /etc/wsl.conf（systemd=true）。反映には wsl --shutdown が必要
make link           # tmux・awake-* をリンク
make remote-access  # awake-keeper.service を有効化し、linger を設定
```

`~/.claude/settings.json` が既にある PC では、既定値はコピーされません（`copy-if-missing`）。その場合は `make diff` で差分を確認し、`hooks` の awake-hook 部分を手で追加してください。

確認方法:

```bash
journalctl --user -u awake-keeper -f   # state: claude / ssh-tmux / idle が出る
```

### 手作業の設定

- **Tailscale（WSL 内）**: WSL に tailscale を入れ、`sudo tailscale up --ssh` で Tailscale SSH を有効にする。スマホにも Tailscale を入れて同じ tailnet に参加させる
- **Wake on LAN**: BIOS/UEFI で WoL を有効にし、Windows のデバイスマネージャーで NIC の「Magic Packet でのウェイク」を有効にする。外出先からマジックパケットを送る方法は環境に合わせて用意する
- **Windows の電源設定**: スリープ方式が S3 であることを `powercfg /a` で確認する。Modern Standby（S0 低電力アイドル）の PC では、`ES_SYSTEM_REQUIRED` だけではスリープを防げない場合がある

## 実装上の注意

- WSL から `powershell.exe -Command '...'` を呼ぶと、引数中の `"` が落ちる。awake-keeper は `-EncodedCommand`（UTF-16LE の base64）で渡している
- Windows 側に常駐プロセスを置かず、毎回すぐ終わる呼び出しでアイドルタイマーをリセットしている。これにより、プロセスが残る問題が起きない
- Claude Code の sandbox からは `/mnt` の読み取りもホスト側のプロセス一覧も見えない。動作確認は通常のターミナルで行う

herdr-core（Herdr app・スマホの Herdr アプリ）でオーケストレーターを動かす構成は [herdr-core-orchestration.md](herdr-core-orchestration.md) を参照してください。
