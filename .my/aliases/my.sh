#!/bin/bash

# git
# shellcheck disable=SC2139
alias branchclean="git fetch --prune && git branch -v | grep \\[gone] | awk '{print $1}' | xargs git branch -d"
alias gitpush="git add -A && git commit -m 'fix' && git push"

# clear
alias clr='rm -f ~/.ssh/known_hosts*'
alias mclear='sync; echo 3 | sudo tee /proc/sys/vm/drop_caches'

# keygen
alias keygen='ssh-keygen -t ed25519 -C "" -f ./keygen -N ""'

# grep
alias grepclean="grep -v -e '^\s*#' -e '^\s*$'" # grepclean [file]

# cheat
alias cheat='vim ~/.my/cheatsheet.sh'
alias cheatvim='vim ~/.my/cheatsheet.vim.sh'
alias cheatk8s='vim ~/.my/cheatsheet.k8s.sh'

# tcpdump
alias mytcpdump='sudo tcpdump -ntq'
# (e.g., tcpdump -A -t -n -i eth1 port 80 and host 192.168.11.11)

# trap
alias mytrap="trap 'echo \"\$BASH_COMMAND\"' DEBUG"
alias deltrap="trap '' DEBUG"

# global ip
alias curlgip='curl inet-ip.info'
