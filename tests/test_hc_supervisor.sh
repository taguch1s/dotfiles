#!/usr/bin/env bash
# hc-supervisor が監督役と watcher を正しい引数で起動・停止することを、偽の hc で検証する。
# 偽の hc は $MOCK_HC_DIR/live/<名前> があれば `hc get` に成功する（中身は最上位の state）。
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
launcher="$repository_root/.local/bin/hc-supervisor"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/live" "$fixture/home"
export MOCK_HC_DIR="$fixture" PATH="$fixture/bin:$PATH" HOME="$fixture/home"
export HC_SUPERVISOR_CLAUDE_SETTINGS="$fixture/settings.json"
unset XDG_DATA_HOME
cat >"$fixture/bin/hc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
(IFS=$'\x1f'; printf '%s\n' "$*") >>"$MOCK_HC_DIR/hc.log"
case "$1" in
  get)
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
  *) echo "unexpected hc command: $*" >&2; exit 1 ;;
esac
EOF
printf '#!/bin/sh\n' >"$fixture/bin/hc-permission"
printf '#!/bin/sh\n' >"$fixture/bin/hc-supervisor-watch"
chmod +x "$fixture/bin/"*

failures=0
ng() {
  printf 'NG   %s\n' "$*" >&2
  failures=1
}
ok() { printf 'OK   %s\n' "$*"; }

runs() { grep $'^run\x1f' "$fixture/hc.log" | tr '\037' ' ' || true; }
reset() { : >"$fixture/hc.log"; }

echo '{}' >"$fixture/settings.json"
reset
"$launcher" >/dev/null 2>"$fixture/err"
home="$fixture/home/.local/share/hc-supervisor"
expected_supervisor="run --bg --timeout 20 --no-parent --keep --name supervisor --label role=supervisor --cwd $home claude-supervisor 監督を開始してください。"
expected_watch="run --bg --parent supervisor --no-notify --name supervisor-watch --label role=supervisor-watch --cwd $home $fixture/bin/hc-supervisor-watch supervisor"
if [[ "$(runs)" == "$expected_supervisor"$'\n'"$expected_watch" ]]; then
  ok 'start: 監督役（role=supervisor、親なし、keep）と、その子の watcher を起動する'
else
  ng "start の hc run が違う: $(runs)"
fi
grep -q 'hook-worker' "$fixture/err" && ok 'start: settings.json に hook がなければ注意を出す' || ng '注意が出ない'

printf '{"hooks":{"PermissionRequest":[{"hooks":[{"command":"\\"$HOME/.local/bin/hc-permission\\" hook-worker"}]}]}}' \
  >"$fixture/settings.json"
reset
"$launcher" >/dev/null 2>"$fixture/err"
[[ -z "$(runs)" ]] && ok 'start: 起動済みなら何も起動しない' || ng "二重に起動した: $(runs)"
[[ ! -s "$fixture/err" ]] && ok 'start: hook があれば注意を出さない' || ng "不要な注意: $(<"$fixture/err")"

rm "$fixture/live/supervisor-watch"
reset
"$launcher" >/dev/null 2>&1
[[ "$(runs)" == "$expected_watch" ]] && ok 'start: watcher だけ欠けていれば watcher だけ起動する' || ng "watcher の補充が違う: $(runs)"

echo finished >"$fixture/live/supervisor"
reset
"$launcher" >/dev/null 2>&1
[[ "$(runs)" == "$expected_supervisor" ]] && ok 'start: 終了済みの監督役は無いものとみなす' || ng "終了済みの扱いが違う: $(runs)"

reset
"$launcher" stop >/dev/null
[[ "$(grep $'^kill' "$fixture/hc.log" | tr '\037' ' ')" == $'kill supervisor-watch\nkill supervisor' ]] \
  && ok 'stop: watcher、監督役の順に止める' || ng "stop が違う: $(cat "$fixture/hc.log")"

if "$launcher" --cwd "$fixture/missing" >/dev/null 2>&1; then ng '存在しない --cwd を受け付けた'; else ok '存在しない --cwd は拒否'; fi
if "$launcher" bogus >/dev/null 2>&1; then ng '不明なサブコマンドを受け付けた'; else ok '不明なサブコマンドは拒否'; fi

exit "$failures"
