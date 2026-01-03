#!/bin/bash

export TIME_STYLE='+%F %T'
export EDITOR='vim'
export VISUAL='vim'
unset LESS

# mise env
if [ -f ~/.local/bin/mise ]; then
  eval "$(~/.local/bin/mise activate bash)"
fi

# poetry env
# VENV_PATH=$(poetry env info --path --directory "$HOME/.my/poetry")
VENV_PATH="$HOME/.cache/pypoetry/virtualenvs"
for dir in "$VENV_PATH"/*/bin; do
  [[ -d "$dir" && ":$PATH:" != *":$dir:"* ]] && PATH="$PATH:$dir" # Because mise has a higher priority than poetry.
done

# thefuck
# eval "$(thefuck --alias)"
# shellcheck disable=SC2112,SC2155,SC2046,SC2086
function fuck() {
  TF_PYTHONIOENCODING=$PYTHONIOENCODING
  export TF_SHELL=bash
  export TF_ALIAS=fuck
  export TF_SHELL_ALIASES=$(alias)
  export TF_HISTORY=$(fc -ln -10)
  export PYTHONIOENCODING=utf-8
  TF_CMD=$(
    thefuck THEFUCK_ARGUMENT_PLACEHOLDER "$@"
  ) && eval "$TF_CMD"
  unset TF_HISTORY
  export PYTHONIOENCODING=$TF_PYTHONIOENCODING
  history -s $TF_CMD
}

# nodejs env
NODE_MODULE_PATH="$HOME/.my/nodejs/node_modules/.bin"
if [[ ":$PATH:" != *":$NODE_MODULE_PATH:"* ]]; then
  export PATH="$NODE_MODULE_PATH:$PATH"
fi

# golang env
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
if [[ ":$PATH:" != *":$GOROOT/bin:"* ]]; then
  export PATH="$GOROOT/bin:$PATH"
fi
if [[ ":$PATH:" != *":$GOPATH/bin:"* ]]; then
  export PATH=$GOPATH/bin:$PATH
fi

# GPG
GPG_TTY=$(tty)
export GPG_TTY
