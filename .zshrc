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
files=$(find ~/.my/aliases/ -type f -print)
for file in $files; do
  # shellcheck disable=SC1090
  [ -f "$file" ] && source "$file"
done

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
export PATH="/home/issei/.local/bin:$PATH"
eval "$(pyenv init --path)"
PATH=/home/issei/.local/bin:/home/issei/.pyenv/shims:/home/issei/.pyenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/usr/lib/wsl/lib:/mnt/c/Windows/system32:/mnt/c/Windows:/mnt/c/Windows/System32/Wbem:/mnt/c/Windows/System32/WindowsPowerShell/v1.0/:/mnt/c/Windows/System32/OpenSSH/:/mnt/c/Program Files (x86)/NVIDIA Corporation/PhysX/Common:/mnt/c/Program Files/NVIDIA Corporation/NVIDIA NvDLISR:/mnt/c/WINDOWS/system32:/mnt/c/WINDOWS:/mnt/c/WINDOWS/System32/Wbem:/mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/:/mnt/c/WINDOWS/System32/OpenSSH/:/mnt/c/PROGRA~1/JPKI:/mnt/c/Users/issei/AppData/Local/Microsoft/WindowsApps:/snap/bin

export PATH="/home/issei/.config/herd-lite/bin:$PATH"
export PHP_INI_SCAN_DIR="/home/issei/.config/herd-lite/bin:$PHP_INI_SCAN_DIR"
