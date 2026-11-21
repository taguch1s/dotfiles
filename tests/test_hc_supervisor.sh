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
    printf '{"address":"t9","name":"%s","state":"%s","labels":{"herdr.space":"spSUP","herdr.tab":"tbSUP"},"status":{"state":"%s"}}\n' \
      "$2" "$(<"$MOCK_HC_DIR/live/$2")" "${MOCK_AGENT_STATE-done}"
    ;;
  run)
    shift
    while [[ "$1" == --* ]]; do
      [[ "$1" == --name ]] && echo live >"$MOCK_HC_DIR/live/$2"
      case "$1" in --) break ;; --bg|--no-parent|--keep|--no-notify|--outlive-parent|--rm) shift ;; *) shift 2 ;; esac
    done
    ;;
  kill) rm -f "$MOCK_HC_DIR/live/$2" ;;
  send)
    # MOCK_SEND_WRITES_HANDOFF=1 なら、依頼を受けた監督役が引き継ぎを書いたことにする。
    if [[ "${MOCK_SEND_WRITES_HANDOFF:-}" == 1 ]]; then
      mkdir -p "$HOME/.local/share/hc-supervisor"
      echo handoff >"$HOME/.local/share/hc-supervisor/handoff.md"
    fi
    ;;
  label|wait|rm) ;;
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

# restart
sup_handoff="$home/handoff.md"
cmds() { grep -v $'^get\x1f' "$fixture/hc.log" | cut -d $'\x1f' -f 1 | tr '\n' ' ' || true; }

rm -f "$fixture/live/"* "$sup_handoff"
echo live >"$fixture/live/supervisor"
reset
MOCK_SEND_WRITES_HANDOFF=1 "$launcher" restart >/dev/null 2>"$fixture/err"
send_line="$(grep $'^send' "$fixture/hc.log" | tr '\037' ' ')"
label_line="$(grep $'^label' "$fixture/hc.log" | tr '\037' ' ')"
[[ "$send_line" == 'send --wait --timeout 600 supervisor 【再起動の準備】'* ]] \
  && ok 'restart: 動いている監督役に引き継ぎを書かせ、ターンの終わりまで待つ' || ng "restart の send が違う: $send_line"
[[ "$(cmds)" == 'send kill wait rm run label ' ]] \
  && ok 'restart: 引き継ぎの後に止めて、同じ名前で起動し直す' || ng "restart の順序が違う: $(cmds) / $(<"$fixture/err")"
[[ "$(runs)" == "$expected_supervisor" ]] && ok 'restart: 起動の引数は start と同じ' || ng "restart の hc run が違う: $(runs)"
[[ "$label_line" == 'label supervisor herdr.space=spSUP herdr.tab=tbSUP where=supervisor' ]] \
  && ok 'restart: Herdr app の同じスペース・同じタブに出す' || ng "restart のラベルが違う: $label_line"

rm -f "$sup_handoff"
echo live >"$fixture/live/supervisor"
reset
if "$launcher" restart >/dev/null 2>"$fixture/err"; then ng '引き継ぎが書かれないのに作り直した'; fi
[[ "$(cmds)" == 'send ' ]] && grep -q '監督役は止めていません' "$fixture/err" \
  && ok 'restart: 引き継ぎが書かれなければ止めない' || ng "引き継ぎなしの扱いが違う: $(cmds) / $(<"$fixture/err")"

echo live >"$fixture/live/supervisor"
reset
if MOCK_AGENT_STATE= MOCK_SEND_WRITES_HANDOFF=1 "$launcher" restart >/dev/null 2>"$fixture/err"; then ng 'エージェントでない terminal に作り直しを頼んだ'; fi
[[ -z "$(cmds)" ]] && grep -q 'Claude Code が応答できる状態ではありません' "$fixture/err" \
  && ok 'restart: 監督役の terminal がシェル（エージェントの状態なし）なら依頼を打ち込まず止めない' || ng "シェルの扱いが違う: $(cmds)"
reset
if MOCK_AGENT_STATE=blocked "$launcher" restart >/dev/null 2>&1; then ng 'blocked の監督役を作り直した'; fi
[[ -z "$(cmds)" ]] && ok 'restart: ダイアログ待ち（blocked）の監督役には頼まない' || ng "blocked の扱いが違う: $(cmds)"

echo old >"$sup_handoff"
touch -d '2000-01-01' "$sup_handoff"
reset
if "$launcher" restart >/dev/null 2>&1; then ng '古い引き継ぎのまま作り直した'; fi
[[ "$(cmds)" == 'send ' ]] && ok 'restart: 依頼より前の古い引き継ぎでは止めない' || ng "古い引き継ぎの扱いが違う: $(cmds)"

rm -f "$sup_handoff"
reset
if HC_TERMINAL_ID=t9 "$launcher" restart >/dev/null 2>"$fixture/err"; then ng '監督役自身が引き継ぎなしで作り直した'; fi
[[ -z "$(cmds)" ]] && grep -q '先に引き継ぎを' "$fixture/err" \
  && ok 'restart（監督役自身）: 引き継ぎがなければ何もしない' || ng "監督役自身・引き継ぎなしが違う: $(cmds)"

echo handoff >"$sup_handoff"
reset
HC_TERMINAL_ID=t9 "$launcher" restart >/dev/null 2>&1
run_line="$(runs)"
[[ "$run_line" == "run --bg --no-parent --rm --no-notify --name supervisor-restart -- bash -c "*'restart --handoff-ready'*" $home $home/restart.log" ]] \
  && [[ "$(cmds)" == 'run ' ]] \
  && ok 'restart（監督役自身）: 親のない別の terminal に切り離し、自分では止めない' || ng "監督役自身の restart が違う: $(cmds) / $run_line"

echo live >"$fixture/live/supervisor"
reset
"$launcher" restart --handoff-ready >/dev/null 2>&1
[[ "$(cmds)" == 'kill wait rm run label ' ]] \
  && ok 'restart --handoff-ready: 引き継ぎを頼まずに作り直す' || ng "--handoff-ready が違う: $(cmds)"

rm -f "$fixture/live/"* "$sup_handoff"
reset
"$launcher" restart >/dev/null 2>&1
[[ "$(cmds)" == 'run ' && "$(runs)" == "$expected_supervisor" ]] \
  && ok 'restart: 監督役がいなければ start と同じく起動する' || ng "監督役なしの restart が違う: $(cmds)"

board_file="$home/board.md"
rm -f "$board_file"
echo admin >"$HC_CLAUDE_ROLE_FILE"
reset
out="$("$launcher" board 2>&1)" && [[ "$out" == *'進捗ボードはまだありません'* && -z "$(cmds)" ]] \
  && ok 'board: ボードが無ければそう表示し、hc を操作しない（admin でも使える）' || ng "ボードなしの board が違う: $out / $(cmds)"
mkdir -p "$home"
printf '# 監督役ボード\n更新: 2026-11-21 21:40\n' >"$board_file"
out="$("$launcher" board 2>&1)" && [[ "$out" == "$(<"$board_file")" ]] \
  && ok 'board: ボードの中身をそのまま表示する' || ng "board の表示が違う: $out"
echo dev >"$HC_CLAUDE_ROLE_FILE"

if "$launcher" --cwd "$fixture/missing" >/dev/null 2>&1; then ng '存在しない --cwd を受け付けた'; else ok '存在しない --cwd は拒否'; fi
if "$launcher" bogus >/dev/null 2>&1; then ng '不明なサブコマンドを受け付けた'; else ok '不明なサブコマンドは拒否'; fi

exit "$failures"
