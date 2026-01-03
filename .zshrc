# If not running under zsh, do nothing (avoids bash errors)
if [ -z "$ZSH_VERSION" ]; then
  return 0 2>/dev/null || :
fi

# 環境変数
export LANG=ja_JP.UTF-8
export LSCOLORS=gxfxcxdxbxegedabagacad


# ================================
#  load settings
# ================================
if [ -d "$HOME/.my/aliases" ]; then
  while IFS= read -r -d '' file; do
    # shellcheck disable=SC1090
    [ -r "$file" ] && source "$file"
  done < <(find "$HOME/.my/aliases" -type f -name '*.sh' -print0)
fi

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
export PATH="/home/issei/.local/bin:$PATH"
eval "$(pyenv init --path)"
export PATH="/home/issei/.local/bin:/home/issei/.pyenv/shims:/home/issei/.pyenv/bin:$PATH"

export PATH="/home/issei/.config/herd-lite/bin:$PATH"
export PHP_INI_SCAN_DIR="/home/issei/.config/herd-lite/bin:$PHP_INI_SCAN_DIR"
