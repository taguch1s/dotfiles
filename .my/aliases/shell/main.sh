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
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias ll='ls -laFh'
alias which='which -a'
alias zmv='noglob zmv -W'
alias showclock='watch -n 60 date'
alias psqltsv='psql -AF $'\''\t'\'''

export HISTTIMEFORMAT="%F %T "
