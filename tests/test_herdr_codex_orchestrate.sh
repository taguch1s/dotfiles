#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
launcher="$repository_root/.local/bin/herdr-codex-orchestrate"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mock_bin="$fixture/bin"
mock_state="$fixture/state"
mock_log="$fixture/herdr.log"
mkdir -p "$mock_bin" "$mock_state"

cat >"$mock_bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$MOCK_HERDR_LOG"
printf '\n' >>"$MOCK_HERDR_LOG"

if [[ "$1 $2" == "agent prompt" ]]; then
  printf '%s\n---\n' "$4" >>"$MOCK_HERDR_PROMPTS"
fi

case "$1 $2" in
  'tab create')
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p9"}}}'
    ;;
  'pane split')
    count_file="$MOCK_HERDR_STATE/splits"
    count=0
    [[ -f "$count_file" ]] && count="$(<"$count_file")"
    count=$((count + 1))
    printf '%s' "$count" >"$count_file"
    printf '{"result":{"pane":{"pane_id":"w1:p%s"}}}\n' "$((9 + count))"
    ;;
  'agent start'|'agent prompt')
    ;;
  *)
    printf 'unexpected Herdr command: %s %s\n' "$1" "$2" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$mock_bin/herdr"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$mock_bin/codex"
chmod +x "$mock_bin/codex"

PATH="$mock_bin:$PATH" \
HERDR_ENV=1 \
HERDR_WORKSPACE_ID=w1 \
MOCK_HERDR_LOG="$mock_log" \
MOCK_HERDR_STATE="$mock_state" \
MOCK_HERDR_PROMPTS="$fixture/prompts" \
"$launcher" --new-top-level --delegates 2 --cwd "$fixture" 'inspect and implement' >"$fixture/output"

rg -F 'tab create --workspace w1 --cwd ' "$mock_log" >/dev/null
rg -F 'HERDR_CODEX_ORCHESTRATED=1' "$mock_log" >/dev/null
rg -F 'pane split w1:p9 --direction right ' "$mock_log" >/dev/null
rg -F 'pane split w1:p10 --direction down ' "$mock_log" >/dev/null
rg -F 'agent start delegate-' "$mock_log" >/dev/null
rg -F -- '--kind codex --pane w1:p10' "$mock_log" >/dev/null
rg -F -- '--kind codex --pane w1:p11' "$mock_log" >/dev/null
rg -F -- '--kind codex --pane w1:p9' "$mock_log" >/dev/null
[[ "$(rg -c '^agent prompt ' "$mock_log")" == 3 ]]
rg -F 'Created w1:t9: main=orchestrator-' "$fixture/output" >/dev/null
rg -F -- '--delegates 2 is this tab' "$fixture/prompts" >/dev/null
rg -F 'Do not create additional panes, tabs, agents, or reviewers.' "$fixture/prompts" >/dev/null
rg -F 'fixed-slot delegate' "$fixture/prompts" >/dev/null
rg -F 'reclaimable, not recovered' "$fixture/prompts" >/dev/null
rg -F 'never close a pane or tab unconditionally or automatically' "$fixture/prompts" >/dev/null
if rg -F 'If additional independent work must run in parallel' "$fixture/prompts" >/dev/null; then
  echo 'launcher still authorizes nested delegate allocation' >&2
  exit 1
fi

if PATH="$mock_bin:$PATH" \
  HERDR_ENV=1 \
  HERDR_WORKSPACE_ID=w1 \
  MOCK_HERDR_LOG="$mock_log" \
  MOCK_HERDR_STATE="$mock_state" \
  "$launcher" --cwd "$fixture" 'must require an explicit new-top-level opt-in' >/dev/null 2>&1; then
  echo 'launcher created a tab without an explicit new-top-level opt-in' >&2
  exit 1
fi

if PATH="$mock_bin:$PATH" \
  HERDR_ENV=1 \
  HERDR_CODEX_ORCHESTRATED=1 \
  HERDR_WORKSPACE_ID=w1 \
  MOCK_HERDR_LOG="$mock_log" \
  MOCK_HERDR_STATE="$mock_state" \
  "$launcher" --new-top-level --cwd "$fixture" 'nested launcher must fail' >/dev/null 2>&1; then
  echo 'launcher accepted a nested orchestration session' >&2
  exit 1
fi

if PATH="$mock_bin:$PATH" HERDR_WORKSPACE_ID=w1 "$launcher" 'must fail' >/dev/null 2>&1; then
  echo 'launcher accepted execution outside Herdr' >&2
  exit 1
fi

echo 'herdr-codex-orchestrate tests passed'
