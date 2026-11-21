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
export HC_CLAUDE_STATE_DIR="$fixture/state" HOME="$fixture/home"
unset HC_TERMINAL_ID
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
expected="--model opus --effort medium --permission-mode bypassPermissions --settings $config/session-settings.json --append-system-prompt-file $config/worker-prompt.md 依頼文"
[[ "$(args)" == "$expected" ]] && ok 'dev: ワーカーを effort medium・bypassPermissions・hc 用 settings・役割のプロンプトで起動する' \
  || ng "ワーカーの引数が違う: $(args)"
"$launcher" supervisor
[[ "$(args)" == "--model opus --effort high "*"--append-system-prompt-file $config/supervisor-prompt.md" ]] && ok 'dev: 監督役は effort high・監督役のプロンプトで起動する' \
  || ng "監督役の引数が違う: $(args)"

# hc 上の監督役: claude が終わったとき入れ替えの印があれば、印の依頼文で起動し直す。
state="$fixture/state"
cat >"$fixture/bin/claude-restart-once" <<'EOF'
#!/usr/bin/env bash
dir="$(dirname "$0")"
printf '%s\n' "${*: -1}" >>"$dir/runs"
if [[ ! -e "$dir/restarted" ]]; then
  touch "$dir/restarted"
  [[ -f "$HC_CLAUDE_STATE_DIR/t5.pid" ]] || echo 'no pid file' >>"$dir/runs"
  printf '新しい依頼' >"$HC_CLAUDE_STATE_DIR/t5.restart"
fi
exit 3
EOF
chmod +x "$fixture/bin/claude-restart-once"
status=0
HC_TERMINAL_ID=t5 HC_CLAUDE_STATE_DIR="$state" HC_CLAUDE_BIN="$fixture/bin/claude-restart-once" \
  "$launcher" supervisor '最初の依頼' >/dev/null || status=$?
[[ "$(tr '\n' '|' <"$fixture/bin/runs")" == '最初の依頼|新しい依頼|' ]] \
  && ok 'hc 上の監督役: 入れ替えの印があれば、同じプロセスの中で印の依頼文で claude を起動し直す' \
  || ng "起動し直しが違う: $(cat "$fixture/bin/runs")"
[[ "$status" == 3 && ! -e "$state/t5.pid" && ! -e "$state/t5.restart" ]] \
  && ok 'hc 上の監督役: 印が無ければ claude の終了コードで終わり、印を片付ける' || ng "終わり方が違う: status=$status / $(ls "$state")"
rm -f "$fixture/bin/runs" "$fixture/bin/restarted"
HC_TERMINAL_ID=t6 HC_CLAUDE_STATE_DIR="$state" HC_CLAUDE_BIN="$fixture/bin/claude-restart-once" "$launcher" worker x >/dev/null || true
[[ ! -e "$state/t6.pid" ]] && ok 'ワーカーは入れ替えの仕組みを使わない（exec で claude に置き換わる）' || ng 'ワーカーが pid の印を書いた'

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
