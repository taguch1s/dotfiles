#!/usr/bin/env bash
# hc-supervisor が監督役を正しい引数で起動・停止し、dev ディストリ以外では起動しないことを、偽の hc で検証する。
# 偽の hc は $MOCK_HC_DIR/live/<名前> があれば `hc get` に成功する（中身は最上位の state）。
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
launcher="$repository_root/.local/bin/hc-supervisor"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/live" "$fixture/labels" "$fixture/home"
export MOCK_HC_DIR="$fixture" PATH="$fixture/bin:$PATH" HOME="$fixture/home"
export HC_CLAUDE_ROLE_FILE="$fixture/dotfiles-role"
echo dev >"$HC_CLAUDE_ROLE_FILE"
unset XDG_DATA_HOME HC_TERMINAL_ID HC_CLAUDE_STATE_DIR HC_CLAUDE_BIN HC_SUPERVISOR_NAME
# pre-commit hook から make check を実行すると GIT_DIR などが入っており、fixture の git が
# このリポジトリを指してしまう。git の環境変数は引き継がない。
unset $(compgen -e | grep '^GIT_' || true)
cat >"$fixture/bin/hc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# 1 回の呼び出しを 1 行に残す（複数行の依頼文の改行は \n と書く）。
(IFS=$'\x1f'; line="$*"; printf '%s\n' "${line//$'\n'/\\n}") >>"$MOCK_HC_DIR/hc.log"
case "$1" in
  get)
    if [[ "$2" == self ]]; then
      echo '{"address":"t1","state":"live","labels":{"herdr.space":"spABC","herdr.tab":"tbOLD"}}'
      exit 0
    fi
    [[ -f "$MOCK_HC_DIR/live/$2" ]] || { echo '{"error":{"kind":"not_found"}}' >&2; exit 3; }
    # $MOCK_HC_DIR/labels/<名前> があれば、その JSON をラベルとして返す（ワーカーの role・引き継ぎ回数）。
    labels='{"herdr.space":"spSUP","herdr.tab":"tbSUP"}'
    [[ ! -f "$MOCK_HC_DIR/labels/$2" ]] || labels="$(<"$MOCK_HC_DIR/labels/$2")"
    printf '{"address":"t9","name":"%s","state":"%s","labels":%s,"status":{"state":"%s"}}\n' \
      "$2" "$(<"$MOCK_HC_DIR/live/$2")" "$labels" "${MOCK_AGENT_STATE-done}"
    ;;
  run)
    shift
    while [[ "$1" == --* ]]; do
      [[ "$1" == --name ]] && echo live >"$MOCK_HC_DIR/live/$2"
      # --label handoffs=N は、起動した terminal のラベルとして残す（resume-worker の引き継ぎ回数）。
      [[ "$1" == --label && "$2" == handoffs=* ]] && printf '%s\n' "${2#handoffs=}" >"$MOCK_HC_DIR/run-handoffs"
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
[[ "$run_line" == "run --bg --no-parent --rm --no-notify --name supervisor-restart -- env bash -c "*'restart --handoff-ready'*" $home $home/restart.log" ]] \
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

# restart（同じ terminal で入れ替え）: 本物の hc-claude を偽の claude で動かし、terminal t9 の中身とみなす。
config="$fixture/config/herdr-core/claude"
mkdir -p "$config"
touch "$config/session-settings.json" "$config/supervisor-prompt.md"
cat >"$fixture/fake-claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude %s\n' "${*: -1}" >>"$MOCK_HC_DIR/claude.log"
exec sleep 60
EOF
chmod +x "$fixture/fake-claude"
HC_TERMINAL_ID=t9 XDG_CONFIG_HOME="$fixture/config" HC_CLAUDE_BIN="$fixture/fake-claude" \
  "$repository_root/.local/bin/hc-claude" supervisor '監督を開始してください。' >"$fixture/hc-claude.out" 2>&1 &
hc_claude_pid=$!
for _ in $(seq 50); do [[ -f "$fixture/claude.log" ]] && break; sleep 0.1; done
old_claude="$(pgrep -P "$hc_claude_pid")"
echo live >"$fixture/live/supervisor"
echo handoff >"$sup_handoff"
reset
"$launcher" restart --handoff-ready >"$fixture/out" 2>&1
new_claude="$(pgrep -P "$hc_claude_pid" || true)"
[[ -z "$(cmds)" ]] && grep -q '同じ terminal（t9）のまま' "$fixture/out" \
  && ok 'restart: hc-claude で動く監督役は、terminal を消さず・作らずに入れ替える' || ng "入れ替えの hc 操作が違う: $(cmds) / $(<"$fixture/out")"
[[ -n "$new_claude" && "$new_claude" != "$old_claude" && "$(tail -n 1 "$fixture/claude.log")" == 'claude 監督を開始してください。' ]] \
  && ok 'restart: 新しい claude を最初の依頼文で起動する' || ng "入れ替え後の claude が違う: $old_claude → $new_claude / $(cat "$fixture/claude.log")"
[[ ! -e "$fixture/home/.local/state/hc-claude/t9.restart" ]] && ok 'restart: 入れ替えの印は使い終わると消える' || ng '入れ替えの印が残った'
kill "$new_claude" 2>/dev/null || true
wait "$hc_claude_pid" 2>/dev/null || true
[[ ! -e "$fixture/home/.local/state/hc-claude/t9.pid" ]] && ok 'hc-claude: claude が自分で終われば終わり、pid の印を消す' || ng 'pid の印が残った'
reset
"$launcher" restart --handoff-ready >"$fixture/out" 2>&1
[[ "$(cmds)" == 'kill wait rm run label ' ]] && grep -q '新しい監督役の子になりません' "$fixture/out" \
  && ok 'restart: 入れ替えられなければ作り直し、親子関係が切れることを知らせる' || ng "作り直しへの切り替えが違う: $(cmds) / $(<"$fixture/out")"

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

# resume-worker: 引き継ぎを送ったワーカーを片付け、同じ worktree で新しいワーカーを handoff 付きで起動する。
repo="$fixture/repo"
git init -q "$repo"
handoff_dir="$(git -C "$repo" rev-parse --path-format=absolute --git-path codex-handoffs)"
mkdir -p "$handoff_dir"
worker_handoff="$handoff_dir/issue-31.md"
echo '# Handoff' >"$worker_handoff"
resume() { "$launcher" resume-worker "$@" >"$fixture/out" 2>"$fixture/err"; }
worker_ready() {
  rm -f "$fixture/live/"* "$fixture/labels/"* "$fixture/run-handoffs"
  echo live >"$fixture/live/w1"
  printf '%s\n' "${1:-{\"role\":\"worker\"\}}" >"$fixture/labels/w1"
  reset
}

worker_ready
if resume --from w1 --cwd "$repo" --handoff "$worker_handoff" '#31 を PR 作成まで進める'; then
  run_line="$(runs)"
  [[ "$(cmds)" == 'kill wait rm run ' ]] \
    && ok 'resume-worker: 前のワーカーを止めて片付けてから、新しいワーカーを起動する' || ng "resume-worker の順序が違う: $(cmds)"
  [[ "$run_line" == "run --bg --timeout 60 --outlive-parent --label role=worker --label handoffs=1 --name w1 --cwd $repo claude-worker 【再開】$worker_handoff"* ]] \
    && ok 'resume-worker: 同じ worktree・同じ名前で、依頼文の先頭に【再開】<handoff> を付けて起動する' || ng "resume-worker の hc run が違う: $run_line"
  [[ "$run_line" == *'#31 を PR 作成まで進める' ]] && ok 'resume-worker: 元の依頼文を添える' || ng "元の依頼文がない: $run_line"
  [[ "$(<"$fixture/run-handoffs")" == 1 ]] && ok 'resume-worker: 引き継ぎ回数（1 回目）を起動と同時にラベルに残す' || ng "引き継ぎ回数のラベルが違う: $run_line"
else
  ng "resume-worker が失敗した: $(<"$fixture/err")"
fi

worker_ready '{"role":"worker","handoffs":"2"}'
resume --from w1 --cwd "$repo" --handoff "$worker_handoff" --name w1b '依頼' || true
[[ "$(<"$fixture/run-handoffs")" == 3 && "$(runs)" == *' --name w1b '* ]] \
  && ok 'resume-worker: 前の回数に 1 を足し、--name の名前で起動する' || ng "回数の加算・--name が違う: $(cmds) / $(runs) / $(<"$fixture/err")"

worker_ready '{"role":"worker","handoffs":"3"}'
if resume --from w1 --cwd "$repo" --handoff "$worker_handoff" '依頼'; then ng '上限（3 回）を超える引き継ぎで起動した'; fi
[[ -z "$(cmds)" ]] && grep -q 'ユーザーに報告' "$fixture/err" \
  && ok 'resume-worker: 引き継ぎが 3 回を超えるなら、前のワーカーを止めず起動もせず、ユーザーへの報告を促す' || ng "上限の扱いが違う: $(cmds) / $(<"$fixture/err")"
worker_ready '{"role":"worker","handoffs":"3"}'
HC_SUPERVISOR_MAX_WORKER_HANDOFFS=4 resume --from w1 --cwd "$repo" --handoff "$worker_handoff" '依頼' || true
[[ "$(cmds)" == 'kill wait rm run ' ]] && ok 'resume-worker: 上限は HC_SUPERVISOR_MAX_WORKER_HANDOFFS で変えられる' || ng "上限の上書きが違う: $(cmds)"

worker_ready
echo live >"$fixture/live/other"
if resume --from w1 --cwd "$repo" --handoff "$worker_handoff" --name other '依頼'; then ng '既にある terminal の名前で起動した'; fi
[[ -z "$(cmds)" ]] && grep -q '既にあります' "$fixture/err" \
  && ok 'resume-worker: --name が既にある別の terminal と同じなら、前のワーカーを止めず起動もしない' || ng "名前の衝突の扱いが違う: $(cmds) / $(<"$fixture/err")"

worker_ready
if MOCK_AGENT_STATE=working resume --from w1 --cwd "$repo" --handoff "$worker_handoff" '依頼'; then ng '動いているワーカーの worktree で起動した'; fi
[[ -z "$(cmds)" ]] && grep -q 'まだ動いています' "$fixture/err" \
  && ok 'resume-worker: 前のワーカーが動いている（working）なら、止めず起動もしない' || ng "working の扱いが違う: $(cmds) / $(<"$fixture/err")"

worker_ready '{"role":"supervisor"}'
if resume --from w1 --cwd "$repo" --handoff "$worker_handoff" '依頼'; then ng 'role=worker でない terminal を止めた'; fi
[[ -z "$(cmds)" ]] && ok 'resume-worker: role=worker でない terminal は止めない' || ng "role の扱いが違う: $(cmds)"

worker_ready
rm -f "$fixture/live/w1"
if resume --from w1 --cwd "$repo" --handoff "$worker_handoff" '依頼'; then ng '前のワーカーが見つからないのに起動した'; fi
[[ -z "$(cmds)" ]] && grep -q '見つかりません' "$fixture/err" \
  && ok 'resume-worker: 前のワーカーが見つからなければ（回数が分からない）起動しない' || ng "前のワーカーなしの扱いが違う: $(cmds) / $(<"$fixture/err")"

echo '# other' >"$fixture/stray.md"
for bad in "$fixture/stray.md" "$handoff_dir/missing.md" "issue-31.md"; do
  worker_ready
  if resume --from w1 --cwd "$repo" --handoff "$bad" '依頼'; then ng "不正な handoff を受け付けた: $bad"; continue; fi
  [[ -z "$(cmds)" && "$(grep -c $'^get' "$fixture/hc.log" || true)" == 0 ]] \
    && ok "resume-worker: handoff が codex-handoffs の下の既存ファイル（絶対 path）でなければ、hc に触れず拒否: ${bad#"$fixture/"}" \
    || ng "不正な handoff で hc を操作した: $bad / $(cmds)"
done
worker_ready
if resume --from w1 --cwd "$fixture/home" --handoff "$worker_handoff" '依頼'; then ng 'git でない --cwd を受け付けた'; fi
[[ -z "$(cmds)" ]] && ok 'resume-worker: --cwd が git の worktree でなければ拒否' || ng "git でない --cwd の扱いが違う: $(cmds)"
worker_ready
if resume --from w1 --cwd "$repo" --handoff "$worker_handoff"; then ng '依頼文なしで起動した'; fi
[[ -z "$(cmds)" ]] && ok 'resume-worker: 依頼文がなければ拒否' || ng "依頼文なしの扱いが違う: $(cmds)"
echo admin >"$HC_CLAUDE_ROLE_FILE"
worker_ready
if resume --from w1 --cwd "$repo" --handoff "$worker_handoff" '依頼'; then ng 'admin でワーカーを起動した'; fi
[[ -z "$(cmds)" ]] && ok 'resume-worker: dev ディストリ以外では起動しない' || ng "admin での resume-worker が違う: $(cmds)"
echo dev >"$HC_CLAUDE_ROLE_FILE"
rm -f "$fixture/live/"* "$fixture/labels/"*

if "$launcher" --cwd "$fixture/missing" >/dev/null 2>&1; then ng '存在しない --cwd を受け付けた'; else ok '存在しない --cwd は拒否'; fi
if "$launcher" bogus >/dev/null 2>&1; then ng '不明なサブコマンドを受け付けた'; else ok '不明なサブコマンドは拒否'; fi

exit "$failures"
