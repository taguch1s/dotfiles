#!/usr/bin/env bash
# hc-orch が正しい引数で hc run を呼ぶことを、偽の hc で検証する。
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
launcher="$repository_root/.local/bin/hc-orch"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/my-repo"
export MOCK_HC_LOG="$fixture/hc.log"
export PATH="$fixture/bin:$PATH"
cat >"$fixture/bin/hc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$MOCK_HC_LOG"
echo t5
EOF
printf '#!/bin/sh\n' >"$fixture/bin/hc-permission"
chmod +x "$fixture/bin/hc" "$fixture/bin/hc-permission"

failures=0
ng() {
  printf 'NG   %s\n' "$*" >&2
  failures=1
}

repo="$(cd "$fixture/my-repo" && pwd -P)"
"$launcher" "$fixture/my-repo" 'Issue #12 と #13 を進める' >/dev/null
expected=$(printf '%s\n' run --bg --name orch-my-repo --cwd "$repo" claude-orchestrator 'Issue #12 と #13 を進める')
[[ "$(<"$MOCK_HC_LOG")" == "$expected" ]] && echo 'OK   hc run の引数' || ng "hc run の引数が違う: $(<"$MOCK_HC_LOG")"

"$launcher" --name orch-x "$fixture/my-repo" 'x' >/dev/null
grep -qx 'orch-x' "$MOCK_HC_LOG" && echo 'OK   --name で名前を変えられる' || ng '--name が効かない'

mkdir -p "$fixture/My.Repo"
"$launcher" "$fixture/My.Repo" 'x' >/dev/null
grep -qx 'orch-my-repo' "$MOCK_HC_LOG" && echo 'OK   既定名を hc の命名規則に合わせる' || ng "既定名が規則外: $(sed -n 4p "$MOCK_HC_LOG")"
if "$launcher" --name 'Bad Name' "$fixture/my-repo" 'x' >/dev/null 2>&1; then ng '規則外の --name を受け付けた'; else echo 'OK   規則外の --name は拒否'; fi

if "$launcher" "$fixture/missing" 'x' >/dev/null 2>&1; then ng '存在しないディレクトリを受け付けた'; else echo 'OK   存在しないディレクトリは拒否'; fi
if "$launcher" "$fixture/my-repo" >/dev/null 2>&1; then ng '指示なしを受け付けた'; else echo 'OK   指示なしは拒否'; fi

exit "$failures"
