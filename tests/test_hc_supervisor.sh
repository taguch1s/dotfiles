#!/usr/bin/env bash
# hc-supervisor が監督役を正しい引数で起動・停止し、dev ディストリ以外では起動しないことを、偽の hc で検証する。
# 偽の hc は $MOCK_HC_DIR/live/<名前> があれば `hc get` に成功する（中身は最上位の state）。
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
launcher="$repository_root/.local/bin/hc-supervisor"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/live" "$fixture/home"
export MOCK_HC_DIR="$fixture" PATH="$fixture/bin:$PATH" HOME="$fixture/home"
export HC_CLAUDE_ROLE_FILE="$fixture/dotfiles-role"
echo dev >"$HC_CLAUDE_ROLE_FILE"
unset XDG_DATA_HOME HC_TERMINAL_ID
cat >"$fixture/bin/hc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
(IFS=$'\x1f'; printf '%s\n' "$*") >>"$MOCK_HC_DIR/hc.log"
case "$1" in
  get)
    if [[ "$2" == self ]]; then
      echo '{"address":"t1","state":"live","labels":{"herdr.space":"spABC","herdr.tab":"tbOLD"}}'
      exit 0
    fi
    [[ -f "$MOCK_HC_DIR/live/$2" ]] || { echo '{"error":{"kind":"not_found"}}' >&2; exit 3; }
    printf '{"address":"t1","name":"%s","state":"%s"}\n' "$2" "$(<"$MOCK_HC_DIR/live/$2")"
    ;;
  run)
    shift
    while [[ "$1" == --* ]]; do
      [[ "$1" == --name ]] && echo live >"$MOCK_HC_DIR/live/$2"
      case "$1" in --bg|--no-parent|--keep|--no-notify|--outlive-parent) shift ;; *) shift 2 ;; esac
    done
    ;;
  kill) rm -f "$MOCK_HC_DIR/live/$2" ;;
  label) ;;
  *) echo "unexpected hc command: $*" >&2; exit 1 ;;
esac
EOF
printf '#!/bin/sh\n' >"$fixture/bin/hc-claude"
chmod +x "$fixture/bin/"*

failures=0
ng() {
  printf 'NG   %s\n' "$*" >&2
  failures=1
}
ok() { printf 'OK   %s\n' "$*"; }

runs() { grep $'^run\x1f' "$fixture/hc.log" | tr '\037' ' ' || true; }
reset() { : >"$fixture/hc.log"; }

reset
echo admin >"$HC_CLAUDE_ROLE_FILE"
if "$launcher" >/dev/null 2>"$fixture/err"; then ng 'admin で起動した'; else ok 'start: dev ディストリ以外では起動しない'; fi
[[ -z "$(runs)" ]] && grep -q 'dev ディストリでだけ' "$fixture/err" && ok 'start: 理由を出し、hc run しない' \
  || ng "admin での拒否が違う: $(runs) / $(<"$fixture/err")"
rm "$HC_CLAUDE_ROLE_FILE"
if "$launcher" >/dev/null 2>&1; then ng '印のないディストリで起動した'; else ok 'start: 印のないディストリ（admin）では起動しない'; fi
echo dev >"$HC_CLAUDE_ROLE_FILE"

reset
"$launcher" >/dev/null 2>"$fixture/err"
home="$fixture/home/.local/share/hc-supervisor"
expected_supervisor="run --bg --timeout 20 --no-parent --keep --name supervisor --label role=supervisor --cwd $home claude-supervisor 監督を開始してください。"
if [[ "$(runs)" == "$expected_supervisor" ]]; then
  ok 'start: 監督役（role=supervisor、親なし、keep）だけを起動する（watcher はない）'
else
  ng "start の hc run が違う: $(runs)"
fi

reset
"$launcher" >/dev/null 2>&1
[[ -z "$(runs)" ]] && ok 'start: 起動済みなら何も起動しない' || ng "二重に起動した: $(runs)"

echo finished >"$fixture/live/supervisor"
reset
"$launcher" >/dev/null 2>&1
[[ "$(runs)" == "$expected_supervisor" ]] && ok 'start: 終了済みの監督役は無いものとみなす' || ng "終了済みの扱いが違う: $(runs)"

rm -f "$fixture/live/"*
reset
"$launcher" >/dev/null 2>&1
grep -q $'^label' "$fixture/hc.log" && ng 'Herdr app の外から起動したのにラベルを付けた' || ok 'start: Herdr app の外ではタブのラベルを付けない'

rm -f "$fixture/live/"*
reset
HC_TERMINAL_ID=self "$launcher" >/dev/null 2>&1
label_line="$(grep $'^label' "$fixture/hc.log" | tr '\037' ' ')"
if [[ "$label_line" =~ ^label\ supervisor\ herdr\.space=spABC\ herdr\.tab=tb[0-9a-f]{32}\ where=supervisor$ ]]; then
  ok 'start: Herdr app のタブから起動すると、同じスペースの新しいタブに出すラベルを付ける'
else
  ng "タブのラベルが違う: $label_line"
fi

reset
"$launcher" stop >/dev/null
[[ "$(grep $'^kill' "$fixture/hc.log" | tr '\037' ' ')" == 'kill supervisor' ]] \
  && ok 'stop: 監督役を止める' || ng "stop が違う: $(cat "$fixture/hc.log")"

if "$launcher" --cwd "$fixture/missing" >/dev/null 2>&1; then ng '存在しない --cwd を受け付けた'; else ok '存在しない --cwd は拒否'; fi
if "$launcher" bogus >/dev/null 2>&1; then ng '不明なサブコマンドを受け付けた'; else ok '不明なサブコマンドは拒否'; fi

exit "$failures"
