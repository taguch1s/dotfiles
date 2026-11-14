#!/usr/bin/env bash
# hc-claude が dev ディストリでだけ、権限確認なしの引数で claude を起動することを、偽の claude で検証する。
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
launcher="$repository_root/.local/bin/hc-claude"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

config="$fixture/config/herdr-core/claude"
mkdir -p "$fixture/bin" "$config"
cp "$repository_root/.config/herdr-core/claude/session-settings.json" "$config/"
touch "$config/worker-prompt.md" "$config/supervisor-prompt.md"
export XDG_CONFIG_HOME="$fixture/config" HC_CLAUDE_ROLE_FILE="$fixture/dotfiles-role" HC_CLAUDE_BIN="$fixture/bin/claude"
cat >"$HC_CLAUDE_BIN" <<'EOF'
#!/usr/bin/env bash
(IFS=$'\x1f'; printf '%s\n' "$*") >"$(dirname "$0")/args"
EOF
chmod +x "$HC_CLAUDE_BIN"

failures=0
ng() { printf 'NG   %s\n' "$*" >&2; failures=1; }
ok() { printf 'OK   %s\n' "$*"; }
args() { tr '\037' ' ' <"$fixture/bin/args"; }

echo dev >"$HC_CLAUDE_ROLE_FILE"
"$launcher" worker '依頼文'
expected="--model opus --permission-mode bypassPermissions --settings $config/session-settings.json --append-system-prompt-file $config/worker-prompt.md 依頼文"
[[ "$(args)" == "$expected" ]] && ok 'dev: ワーカーを bypassPermissions・hc 用 settings・役割のプロンプトで起動する' \
  || ng "ワーカーの引数が違う: $(args)"
"$launcher" supervisor
[[ "$(args)" == *"--append-system-prompt-file $config/supervisor-prompt.md" ]] && ok 'dev: 監督役は監督役のプロンプトで起動する' \
  || ng "監督役の引数が違う: $(args)"

rm -f "$fixture/bin/args"
echo admin >"$HC_CLAUDE_ROLE_FILE"
if "$launcher" worker x 2>"$fixture/err"; then ng 'admin で起動した'; else ok 'admin では起動しない'; fi
[[ ! -e "$fixture/bin/args" ]] && grep -q 'dev ディストリでだけ' "$fixture/err" && ok 'admin: claude を呼ばず理由を出す' \
  || ng "admin での拒否が違う: $(cat "$fixture/err")"
rm "$HC_CLAUDE_ROLE_FILE"
if "$launcher" worker x 2>/dev/null; then ng '印のないディストリで起動した'; else ok '印のないディストリでは起動しない'; fi

echo dev >"$HC_CLAUDE_ROLE_FILE"
if "$launcher" bogus 2>/dev/null; then ng '不明な役割を受け付けた'; else ok '不明な役割は拒否'; fi
rm "$config/worker-prompt.md"
if "$launcher" worker 2>/dev/null; then ng 'プロンプトがないのに起動した'; else ok 'link されていなければ起動しない'; fi

python3 - "$repository_root/.config/herdr-core/claude/session-settings.json" <<'EOF' && ok 'session-settings: sandbox なし・bypassPermissions・事故よけ hook' || ng 'session-settings の内容が違う'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["permissions"]["defaultMode"] == "bypassPermissions"
assert s["sandbox"]["enabled"] is False
commands = [h["command"] for g in s["hooks"]["PreToolUse"] for h in g["hooks"]]
assert any("hc-permission" in c and c.endswith(" hook") for c in commands)
assert "PermissionRequest" not in s["hooks"]
EOF

exit "$failures"
