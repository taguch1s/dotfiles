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

## Agent terminal / WSL

Portable Herdr, Ghostty, Codex, and WSL settings live in this repository. They
exclude credentials, session state, caches, logs, and generated integration files.
Herdr/Ghostty/custom scripts are symlinked. Codex defaults are copied only when
no `~/.codex/config.toml` exists, because Codex adds machine-local hook state to
that file during normal use.

```bash
./.bin/bootstrap-agent-terminal.sh # installs make if needed, then runs bootstrap
# Once make is available:
make bootstrap  # install gh/Herdr/Codex where absent, link configs, install Herdr↔Codex integration
make wsl        # intentionally separate: writes /etc/wsl.conf and Windows ~/.wslconfig
make doctor     # verify commands, links, and the status script
```

Ghostty is available through Ubuntu's default repository only on sufficiently new
Ubuntu versions. On Ubuntu 24.04, the bootstrap reports the supported options
without silently installing a community package. To opt in to that package:

```bash
GHOSTTY_INSTALL=community-deb make bootstrap
```

After a fresh setup, authenticate separately with `gh auth login` and `codex login`.
