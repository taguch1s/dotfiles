#!/bin/bash

# ubuntu22.04 default settings
if [ -x /usr/bin/dircolors ]; then
  # shellcheck disable=SC2015
  test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
  alias ls='ls --color=auto'
  alias grep='grep --color=auto'
  alias fgrep='fgrep --color=auto'
  alias egrep='egrep --color=auto'
fi
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# my settings
alias sudo='sudo '
alias ll='ls -laFh'
alias vi='vim'
alias zmv='noglob zmv -W'

# 挙動や出力を変える別名は、人が対話で使うシェルだけで定義する。
# AI エージェント（Claude Code は CLAUDECODE=1 を設定し、対話シェルの別名を引き継ぐ）や
# スクリプトでは、cp -i / rm -i が確認待ちで黙って何もせず、cat -n がファイルに行番号を混ぜる。
case $- in
  *i*) _my_interactive=1 ;;
  *) _my_interactive= ;;
esac
if [ -n "$_my_interactive" ] && [ -z "${CLAUDECODE:-}" ]; then
  alias cp='cp -i'
  alias mv='mv -i'
  alias rm='rm -i'
  alias which='which -a'
  alias cat='cat -n'
  alias less='less -NM'
fi
unset _my_interactive
alias showclock='watch -n 60 date'
alias psqltsv='psql -AF $'\''\t'\'''

export HISTTIMEFORMAT="%F %T "
