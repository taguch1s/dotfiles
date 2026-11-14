#!/usr/bin/env bash
# hc-supervisor-watch が権限待ちだけを監督役へ 1 度ずつ知らせることを、偽の hc で検証する。
# t1 は監督役。偽の hc は $MOCK_HC_DIR/terminals/<address>.json を `hc get` の結果として返し、
# `hc events` では $MOCK_HC_DIR/events.sh を実行する（状態を書き換えながら 1 行ずつ出す）。
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
watcher="$repository_root/.local/bin/hc-supervisor-watch"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export PYTHONDONTWRITEBYTECODE=1
export MOCK_HC_DIR="$fixture" PATH="$fixture/bin:$PATH" HC_SUPERVISOR_WATCH_RETRY=1
mkdir -p "$fixture/bin" "$fixture/terminals"
: >"$fixture/send.log"
: >"$fixture/get.log"

cat >"$fixture/bin/hc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  get)
    printf '%s\n' "$2" >>"$MOCK_HC_DIR/get.log"
    file="$MOCK_HC_DIR/terminals/$2.json"
    [[ -f "$file" ]] || { echo '{"error":{"kind":"not_found"}}' >&2; exit 3; }
    cat "$file"
    ;;
  ls)
    python3 -c '
import json, pathlib, sys
print(json.dumps([json.loads(p.read_text()) for p in sorted(pathlib.Path(sys.argv[1]).glob("*.json"))]))
' "$MOCK_HC_DIR/terminals"
    ;;
  events) bash "$MOCK_HC_DIR/events.sh" ;;
  send)
    [[ ! -e "$MOCK_HC_DIR/send-fails" ]] || { echo '{"error":{"kind":"blocked"}}' >&2; exit 9; }
    printf '%s\t%s\n' "$2" "$3" >>"$MOCK_HC_DIR/send.log"
    ;;
  *) echo "unexpected hc command: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$fixture/bin/hc"

# terminal <address> <state> [kind] [parent]
terminal() {
  python3 -c '
import json, sys
address, state, kind, parent = (sys.argv[1:] + ["", ""])[:4]
status = {"state": state}
if kind:
    status["kind"] = kind
print(json.dumps({"address": address, "name": "n-" + address, "parent": parent or None,
                  "cwd": "/repo/" + address, "status": status}))
' "$@" >"$fixture/terminals/$1.json"
}

terminal t1 working
terminal t3 blocked permission          # 手動セッション: 起動時の見直しで知らせる
terminal t4 blocked permission t1       # 監督役の子: hc が親へ通知するので知らせない
terminal t5 blocked question            # 権限待ちではない
terminal t6 idle
terminal t7 idle

cat >"$fixture/events.sh" <<'EOF'
set -euo pipefail
dir="$MOCK_HC_DIR"
# 監視側が get を n 回以上呼ぶまで待つ（状態の書き換えと読み取りの順序をそろえる）。
wait_get() {
  for _ in $(seq 100); do
    (( $(grep -cx "$1" "$dir/get.log" || true) >= $2 )) && return 0
    sleep 0.05
  done
  echo "timeout waiting for get $1" >&2
}
t() { bash -c 'source "$0"; terminal "$@"' "$dir/terminal.sh" "$@"; }
echo '{"event":"status","terminal":{"address":"t3","status":{"state":"blocked","kind":"permission"}}}'
wait_get t3 2
t t3 idle
echo '{"terminal":"t3","status":{"state":"idle"}}'
wait_get t3 3
t t3 blocked permission
echo '{"address":"t3"}'
wait_get t3 4
t t6 blocked permission
echo '{"kind":"something-without-address"}'
wait_get t6 2
t t1 blocked permission
echo '{"address":"t1"}'
touch "$dir/send-fails"
t t7 blocked permission
echo '{"address":"t7"}'
wait_get t7 2
rm "$dir/send-fails"
echo 'not json'
sleep 1.5
EOF
declare -f terminal >"$fixture/terminal.sh"
printf 'fixture=%q\n' "$fixture" | cat - "$fixture/terminal.sh" >"$fixture/terminal.tmp"
mv "$fixture/terminal.tmp" "$fixture/terminal.sh"

failures=0
ng() {
  printf 'NG   %s\n' "$*" >&2
  failures=1
}
ok() { printf 'OK   %s\n' "$*"; }

timeout 30 "$watcher" t1 --once >"$fixture/watch.log" 2>&1 || ng "watcher が異常終了した: $(cat "$fixture/watch.log")"

count() { grep -c "<hc-watch>$1 " "$fixture/send.log" || true; }
[[ "$(cut -f1 "$fixture/send.log" | sort -u)" == t1 ]] && ok '通知の宛先は監督役' || ng "宛先が違う: $(cat "$fixture/send.log")"
grep -q $'^t1\t<hc-watch>t3 n-t3 (/repo/t3) is blocked (permission). hc-permission show t3</hc-watch>$' "$fixture/send.log" \
  && ok '通知の文面（名前・cwd・show の案内）' || ng "文面が違う: $(cat "$fixture/send.log")"
[[ "$(count t3)" == 2 ]] && ok '同じ権限待ちは 1 度だけ、解消後に再び止まれば再通知' || ng "t3 の通知回数: $(count t3)"
[[ "$(count t4)" == 0 ]] && ok '監督役の子は知らせない' || ng 't4 を知らせた'
[[ "$(count t5)" == 0 ]] && ok '質問待ち（question）は知らせない' || ng 't5 を知らせた'
[[ "$(count t1)" == 0 ]] && ok '監督役自身は知らせない' || ng 't1 を知らせた'
[[ "$(count t6)" == 1 ]] && ok 'アドレスのない event では全体を見直す' || ng "t6 の通知回数: $(count t6)"
[[ "$(count t7)" == 1 ]] && ok '送れなかった通知は後で再送する' || ng "t7 の通知回数: $(count t7)"

exit "$failures"
