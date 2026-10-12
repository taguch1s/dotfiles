#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
script="$repo/.local/bin/datablog-stack"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/project/src/node_modules/.bin" "$fixture/project/supabase"
export PATH="$fixture/bin:$PATH"
export DATABLOG_SRC="$fixture/project/src"
export MOCK_LOG="$fixture/commands"
export MOCK_SUP="$fixture/sup"
export MOCK_Q="$fixture/q"
printf '1' >"$MOCK_SUP"
printf '1' >"$MOCK_Q"
printf '{}\n' >"$DATABLOG_SRC/package.json"
printf 'project_id = "datablog-master"\n' >"$fixture/project/supabase/config.toml"

cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$MOCK_LOG"
if [[ "$1" == info ]]; then echo mock; exit 0; fi
if [[ "$1 $2" == 'container rm' ]]; then
  [[ "$*" == *'q-id'* ]] || exit 1
  printf '0' >"$MOCK_Q"
  exit 0
fi
[[ "$1 $2" == 'container ls' ]] || exit 1
filter="$*"
if [[ -n "${MOCK_FAIL_LIST:-}" && "$filter" == *"$MOCK_FAIL_LIST"* ]]; then
  echo 'mock Docker list failure' >&2
  exit 13
fi
if [[ "$filter" == *'label=com.supabase.cli.project=datablog-master'* && "$(<"$MOCK_SUP")" == 1 ]]; then
  if [[ "$filter" == *'--quiet'* ]]; then echo sup-id; else printf 'supabase_db_datablog-master\tUp\n'; fi
elif [[ "$filter" == *'name=^/datablog-qdrant-integration$'* && "$(<"$MOCK_Q")" == 1 ]]; then
  if [[ "$filter" == *'--quiet'* ]]; then echo q-id; else printf 'datablog-qdrant-integration\tExited\n'; fi
fi
EOF
cat >"$DATABLOG_SRC/node_modules/.bin/supabase" <<'EOF'
#!/usr/bin/env bash
printf 'supabase %s\n' "$*" >>"$MOCK_LOG"
if [[ "$*" == *' stop --project-id datablog-master' ]]; then
  [[ "${MOCK_FAIL_STOP:-0}" == 0 ]] || exit 12
  printf '0' >"$MOCK_SUP"
fi
EOF
chmod +x "$fixture/bin/docker" "$DATABLOG_SRC/node_modules/.bin/supabase"

"$script" status >"$fixture/status"
grep -q 'supabase_db_datablog-master' "$fixture/status"
grep -q 'datablog-qdrant-integration' "$fixture/status"

"$script" start >/dev/null
grep -Fx "supabase --workdir $fixture/project start" "$MOCK_LOG"

"$script" stop >/dev/null
grep -Fx "supabase --workdir $fixture/project stop --project-id datablog-master" "$MOCK_LOG"
grep -Fx 'docker container rm --force q-id' "$MOCK_LOG"
if grep -E 'docker volume|--no-backup|supabase .* --all|docker container rm .*other' "$MOCK_LOG"; then exit 1; fi
[[ "$(<"$MOCK_SUP")" == 0 && "$(<"$MOCK_Q")" == 0 ]]
"$script" status >"$fixture/status"
[[ "$(grep -c '^none$' "$fixture/status")" == 2 ]]

"$script" stop >/dev/null
[[ "$(grep -c '^supabase .* stop ' "$MOCK_LOG")" == 1 ]]
[[ "$(grep -c '^docker container rm ' "$MOCK_LOG")" == 1 ]]

printf '1' >"$MOCK_SUP"
printf '1' >"$MOCK_Q"
if MOCK_FAIL_STOP=1 "$script" stop >"$fixture/output" 2>&1; then exit 1; fi
[[ "$(<"$MOCK_Q")" == 1 ]]
[[ "$(grep -c '^docker container rm ' "$MOCK_LOG")" == 1 ]]
printf '0' >"$MOCK_SUP"

for action in stop status; do
  for filter in 'label=com.supabase.cli.project=datablog-master' 'name=^/datablog-qdrant-integration$'; do
    printf '1' >"$MOCK_SUP"
    printf '1' >"$MOCK_Q"
    before="$(grep -Ec '^(supabase|docker container rm)' "$MOCK_LOG")"
    if MOCK_FAIL_LIST="$filter" "$script" "$action" >"$fixture/output" 2>&1; then exit 1; fi
    grep -q 'mock Docker list failure' "$fixture/output"
    if grep -q '^none$' "$fixture/output"; then exit 1; fi
    [[ "$(grep -Ec '^(supabase|docker container rm)' "$MOCK_LOG")" == "$before" ]]
    [[ "$(<"$MOCK_SUP")" == 1 && "$(<"$MOCK_Q")" == 1 ]]
  done
done

before="$(wc -l <"$MOCK_LOG")"
printf 'project_id = "other"\n' >"$fixture/project/supabase/config.toml"
if "$script" start >"$fixture/output" 2>&1; then exit 1; fi
[[ "$(wc -l <"$MOCK_LOG")" == "$((before + 1))" ]]
grep -q 'Unexpected Supabase project_id' "$fixture/output"

echo 'datablog-stack tests passed'
