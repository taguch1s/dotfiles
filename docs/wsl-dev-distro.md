# dev ディストリ（エージェントを動かす境界）の作り方

hc（herdr-core）上の Claude Code は、権限確認なし（sandbox なし・`bypassPermissions`）で動かします。そのかわり、エージェントが触れる範囲を WSL のディストリビューション単位で区切ります。考え方と採らなかった案は [herdr-core-orchestration.md](herdr-core-orchestration.md) と Issue #26 にあります。

| ディストリ | 役割 | Windows のドライブ | Windows プログラムの起動 | 作業ユーザーの root |
| --- | --- | --- | --- | --- |
| `dev` | エージェントと日常の開発 | 見えない（VS Code 用の 2 ディレクトリだけ読み取り専用） | できない | なれない（root は Windows 側の `wsl -d dev -u root` だけ） |
| `admin`（今の `Ubuntu-24.04`） | 秘密情報と dev の境界設定の管理。エージェントは動かさない | 見える | できる | なれる |

dev の中であることは `/etc/dotfiles-role`（中身が `dev`）で判定します。root が書くファイルなので、dev のエージェントは書き換えられません。hc の起動ラッパーはこの印が `dev` のときだけ権限確認なしで起動し、印がないディストリ（admin）ではエージェントを起動しません。

## 作り方

前提: このリポジトリの `wsl/dev/setup-dev-distro.sh` を含む main が、admin の `~/dotfiles` に pull 済みであること（dev は admin の複製なので、そのまま dev にも入ります）。

### 1. admin を複製する（Windows の PowerShell）

export の前にディストリを止めます。動いている hc の監督役やワーカー、VS Code の接続も止まるので、区切りのよいときに行ってください。

```powershell
wsl --terminate Ubuntu-24.04
mkdir $env:USERPROFILE\wsl
wsl --export Ubuntu-24.04 $env:USERPROFILE\wsl\ubuntu-24.04.tar
wsl --import dev $env:USERPROFILE\wsl\dev $env:USERPROFILE\wsl\ubuntu-24.04.tar --version 2
```

- tar が大きい場合は `wsl --export Ubuntu-24.04 <file>.vhdx --format vhd` と `wsl --import dev <dir> <file>.vhdx --vhd` を使うと速くなります。
- import が終わったら tar は消してかまいません。

### 2. dev の境界を設定する（Windows の PowerShell）

```powershell
wsl -d dev -u root -- bash /home/issei/dotfiles/wsl/dev/setup-dev-distro.sh --distro dev
wsl --terminate dev
```

`setup-dev-distro.sh` が行うこと（何度実行しても同じ状態になります。変更前のファイルは `/root/dotfiles-dev-setup-backup/<日時>/` に退避されます）:

- `/etc/dotfiles-role` に `dev` を書く。
- `/etc/wsl.conf`: `[automount] enabled=false`、`[interop] enabled=false, appendWindowsPath=false`、`[user] default=issei`、`[boot] systemd=true`。
- `/etc/fstab`: VS Code Remote-WSL が使う 2 ディレクトリを読み取り専用で mount する。
  ```
  C:\Users\issei\.vscode\extensions /mnt/c/Users/issei/.vscode/extensions drvfs ro 0 0
  C:\Users\issei\vscode-remote-wsl /mnt/c/Users/issei/vscode-remote-wsl drvfs ro 0 0
  ```
  WSL 拡張は Windows 側の拡張ディレクトリにある `wslServer.sh` と、Windows 側に置いたサーバーの tarball を使うため、automount を切るとこの 2 つがないと接続できません。
- 作業ユーザーから root になる手段を外す: `sudo`・`admin`・`docker`・`lxd` グループから外す、`/etc/sudoers.d` のユーザー個別の設定（`90-issei-nopasswd` など）を消す、root のパスワードをロックする（`su` 不可）。
- Docker を止める（`docker.socket` など）。docker グループは root と同じ権限なので、dev では Docker を使いません。Docker が要る作業は admin で行います。
- 複製元と同じ `machine-id`・SSH ホスト鍵を作り直す。
- Tailscale の複製されたノード情報を退避する（そのままだと admin と同じノードが 2 つになる）。

### 3. 境界を確認する（Windows の PowerShell）

```powershell
wsl -d dev -- bash /home/issei/dotfiles/wsl/dev/verify-dev-boundary.sh
```

作業ユーザーの立場で、役割の印、root 相当のグループ、パスワードなしの sudo、PATH、`.exe` の起動、`/mnt` に見えるもの、VS Code 用 mount が読み取り専用か、を確かめます。すべて `OK` になれば完了です。

### 4. スマホからの経路を dev に移す

```powershell
wsl -d dev -u root -- tailscale up --ssh --hostname dev
```

表示される URL でログインします。そのあと admin の tailscaled を止め、tailnet から外します（admin の端末で `sudo tailscale logout` と `sudo systemctl disable --now tailscaled`）。スマホからは `dev` に Tailscale SSH で入ります（[remote-access.md](remote-access.md)）。

### 5. dev で使い始める

- VS Code: `code --remote wsl+dev /home/issei/<リポジトリ>`、または VS Code の「WSL に接続」で `dev` を選ぶ。
- Claude Code・gh・Codex の認証は admin から複製されています。Claude Code のログインが切れた場合は dev で `/login` し直してください（同じ認証を 2 つのディストリで更新し合うと、片方が切れることがあります）。
- Herdr app は dev の WSLg から起動します。hc の監督役は dev で起動します（`hc-supervisor`）。

## 運用

- dev の root 作業は、Windows 側から `wsl -d dev -u root` で行います。dev の中から root にはなれません。
- dev の境界設定（`/etc/wsl.conf`・`/etc/fstab`）を変えたら、`wsl --terminate dev` のあと `verify-dev-boundary.sh` で確かめます。
- WSL2 のディストリは同じ VM でネットワークを共有するため、admin の `127.0.0.1` で待ち受けるサービスに dev から届きます。admin には localhost のサービスを置かないでください（置くなら、dev から呼ばれる前提で操作を絞ります）。
- `/mnt/wsl` は全ディストリで共有される tmpfs です。秘密情報を置かないでください。
- dev をやめるときは `wsl --unregister dev`（dev の中身はすべて消えます）。

## 確認済みのこと（sbx-test、2026-11-14、WSL 2.7.14.0 / Windows 10.0.26200）

- `/mnt/c` に中身がなく、fstab の 2 ディレクトリだけが見え、書き込みは `Read-only file system`。
- `.exe` を直接実行できない。残っている interop の socket（`/run/WSL/*_interop`）経由でも Windows のプロセスを起動できない。
- `mount -t drvfs` は一般ユーザーでは不可。PATH に Windows のパスが入らない。
- VS Code Remote-WSL は fstab の読み取り専用 mount で接続でき、`wsl --terminate` 後も再接続できる。VS Code の Claude Code 拡張（2.1.325）は interop なしでログインして使える。
- Herdr app（WSLg）は interop なしで起動・使用でき、herdr-core の socket も作られる。
