# dotfiles
環境設定用のファイル群

## Procedure

refs: https://github.com/melanmeg/dotfiles/blob/7b105ea84a3bb9165d836375bb34b4858fbb5502/README.md

- Ubuntu 24.04 AMD x64

```bash
git clone https://github.com/melanmeg/dotfiles.git
./dotfiles/.bin/dotfiles --backup --gitconfig-shared
```

```bash
git config --global user.email "you@example.com"
git config --global user.name "Your Name"
git config --global credential.helper store
```

- Install: https://github.com/melanmeg/dotsrepl

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

## font
- 0xProto: https://github.com/0xType/0xProto/blob/main/fonts/0xProto-Regular.ttf
- source-han-code-jp: https://github.com/adobe-fonts/source-han-code-jp/releases/download/2.012R/SourceHanCodeJP.ttc
