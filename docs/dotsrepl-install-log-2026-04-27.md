     1	# dotsrepl + zsh セットアップ記録 (2026-04-27)
     2	
     3	## 目的
     4	- `dotsrepl` を使って `~/dotfiles` をホームディレクトリへ展開する
     5	- `zsh` を使用可能にする
     6	
     7	## 実施内容
     8	1. dotsrepl をインストール
     9	- 配置先: `~/.local/bin/dotsrepl`
    10	- 取得URL (x86_64):
    11	  - `https://github.com/melanmeg/dotsrepl/releases/download/v1.0/dotsrepl-1.0-x86_64-unknown-linux-musl`
    12	- 実行権限を付与: `chmod +x ~/.local/bin/dotsrepl`
    13	- バージョン確認結果: `dotsrepl 0.1.0`
    14	
    15	2. dotfiles をホームへ展開
    16	- 実行コマンド:
    17	  - `~/.local/bin/dotsrepl -p ~/dotfiles -b -g -f`
    18	- オプション意図:
    19	  - `-b`: 既存ファイルを `~/.dotbackup` にバックアップ
    20	  - `-g`: `git config --global include.path ~/.gitconfig_shared` を設定
    21	  - `-f`: 既存ファイルがあっても上書き
    22	- 結果: `Install completed!!!!`
    23	
    24	3. zsh をインストール
    25	- コマンド:
    26	  - `sudo apt-get update`
    27	  - `sudo apt-get install -y zsh`
    28	- 確認:
    29	  - `command -v zsh` => `/usr/bin/zsh`
    30	  - `zsh --version` => `zsh 5.9 (x86_64-ubuntu-linux-gnu)`
    31	
    32	## 次回への知見 / 注意点
    33	- `chsh -s $(command -v zsh) $USER` は対話的に `Password:` を要求する場合がある。
    34	  - 自動化コンテキストでは入力待ちで止まるため、非対話実行には不向き。
    35	- 今回は最終的に `getent passwd $USER` でログインシェルが `/usr/bin/zsh` であることを確認できた。
    36	- dotfiles 適用後に期待したPATHへ反映されない場合は、再ログインまたは新規シェル起動で環境を再読込する。
    37	- `dotsrepl` の表示バージョンがリリースタグ (`v1.0`) と一致しないことがあるため、URL固定で取得した事実を記録しておく。
    38	
    39	## 簡易確認コマンド
    40	- `~/.local/bin/dotsrepl -V`
    41	- `getent passwd $USER | awk -F: '{print $7}'`
    42	- `zsh -i -c 'echo $ZSH_VERSION'`
     1	
     2	## 実行後に見えた課題
     3	- `zsh -i -c 'echo $ZSH_VERSION'` 実行時に以下の警告が出た:
     4	  - `/home/issei/.zshrc:24: command not found: pyenv`
     5	- これは `zsh` 自体の起動失敗ではないが、`pyenv` 前提の設定があるため、必要に応じて `pyenv` を導入するか `.zshrc` 側で存在チェックを入れる。
