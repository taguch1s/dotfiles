# dotfiles
環境設定用のファイル群

## 導入手順

参考: https://github.com/melanmeg/dotfiles/blob/7b105ea84a3bb9165d836375bb34b4858fbb5502/README.md

- 対象環境: Ubuntu 24.04 AMD x64

```bash
git clone https://github.com/taguch1s/dotfiles.git
./dotfiles/.bin/dotfiles --backup --gitconfig-shared
```

```bash
git config --global user.email "you@example.com"
git config --global user.name "Your Name"
git config --global credential.helper store
```

- dotsrepl の導入: https://github.com/melanmeg/dotsrepl

```bash
$ dotsrepl -h
Rust CLI for Dotfiles.

Usage: dotsrepl [OPTIONS] --path <PATH>

Options:
  -p, --path <PATH>       Path to dotfiles
  -f, --force             Force overwrite
  -b, --backup            Backup dotfiles
  -l, --link              Link to homedir
  -g, --gitconfig-shared  git config (.gitconfig_shared)
  -h, --help              Print help
  -V, --version           Print version
```

```bash
$ ./.bin/dotsrepl -p . -bg
```

- mise
```bash
$ mise self-update
$ mise plugin up
$ mise up
$ mise cache c
$ mise cache p
$ mise prune
```

## フォント
- 0xProto: https://github.com/0xType/0xProto/blob/main/fonts/0xProto-Regular.ttf
- source-han-code-jp: https://github.com/adobe-fonts/source-han-code-jp/releases/download/2.012R/SourceHanCodeJP.ttc

## エージェント用端末 / WSL

このリポジトリでは、移植可能な Herdr・Ghostty・Codex・WSL の設定を管理します。
認証情報、セッション状態、キャッシュ、ログ、生成された連携ファイルは含めません。

Herdr、Ghostty、独自スクリプトはシンボリックリンクで配置します。Codex は通常利用時に
マシン固有のフック状態を `~/.codex/config.toml` へ追加するため、既存設定がない場合だけ
ポータブルな既定値をコピーします。

```bash
./.bin/bootstrap-agent-terminal.sh # 必要なら make を導入してから bootstrap を実行
# make 導入後は以下だけで実行できます。
make bootstrap  # 未導入の gh/Herdr/Codex を導入し、設定リンクと Herdr↔Codex 連携を行う
make wsl        # /etc/wsl.conf と Windows 側 ~/.wslconfig を書き込むため、意図的に分離
make doctor     # コマンド、リンク、ステータススクリプトを検証
```

Ghostty が Ubuntu の標準リポジトリから導入できるのは十分に新しいバージョンだけです。
Ubuntu 24.04 では、bootstrap はコミュニティパッケージを暗黙には導入せず、対応方法だけを
表示します。そのパッケージを利用する場合は、明示的に次を指定してください。

```bash
GHOSTTY_INSTALL=community-deb make bootstrap
```

新規セットアップ後は、`gh auth login` と `codex login` を個別に実行して認証してください。
