#!/usr/bin/env bash
# awake-keeper の hc 条件 (hc-working・hc-job) を、偽の hc と偽の /proc/locks で検証する。
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
keeper="$repository_root/.local/bin/awake-keeper"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# 偽の hc: ls は $fixture/ls.json、get <t> は $fixture/get-<t>.json を返す。HC_FAKE_SLEEP があれば応答しない
cat >"$fixture/hc" <<'FAKE'
#!/usr/bin/env bash
[ -n "${HC_FAKE_SLEEP:-}" ] && sleep "$HC_FAKE_SLEEP"
d=$(dirname "$0")
case $1 in
  ls) cat "$d/ls.json" ;;
  get) cat "$d/get-$2.json" ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$fixture/hc"
touch "$fixture/heavy.lock"
: >"$fixture/locks"
export HOME="$fixture/home" HC_BIN="$fixture/hc" HC_TIMEOUT=1 HEAVY_LOCK="$fixture/heavy.lock" PROC_LOCKS="$fixture/locks"
mkdir -p "$HOME"

failures=0
ng() { printf 'NG   %s\n' "$*" >&2; failures=1; }
ok() { printf 'OK   %s\n' "$*"; }
hc_reasons() { "$keeper" --once | tr '+' '\n' | grep '^hc-' | paste -sd+ || true; }
expect() {  # expect <期待する hc-* の理由> <説明>
  local got; got=$(hc_reasons)
  [[ "$got" == "$1" ]] && ok "$2" || ng "$2: 期待 '${1}'、実際 '${got}'"
}
terminals() { printf '{"terminals":[%s]}\n' "$1" >"$fixture/ls.json"; }
foreground() { printf '{"address":"%s","foreground":%s}\n' "$1" "$2" >"$fixture/get-$1.json"; }

terminals '{"address":"t1","agent":"claude-code","state":"live","status":"idle"},{"address":"t2","agent":"claude-code","state":"live","status":"done"},{"address":"t3","agent":"zsh","state":"live"},{"address":"t4","agent":"bash","state":"finished"}'
foreground t3 '{"argv":["/usr/bin/zsh"],"name":"zsh","pid":10}'
expect '' '待機中のエージェント・プロンプトの対話シェル・終了した端末は数えない'

foreground t3 '{"argv":["-zsh","-l"],"name":"-zsh","pid":10}'
expect '' 'ログインシェルの引数 (-l) だけなら数えない'

terminals '{"address":"t1","agent":"claude-code","state":"live","status":"working"}'
expect 'hc-working' 'status が working のエージェントは hc-working'

terminals '{"address":"t5","agent":"sleep","state":"live"}'
foreground t5 '{"argv":["sleep","120"],"name":"sleep","pid":11}'
expect 'hc-job' 'シェル以外のプログラムが前面にいれば hc-job'

terminals '{"address":"t6","agent":"bash","state":"live"}'
foreground t6 '{"argv":["bash","-c","run.sh >> run.log"],"name":"bash","pid":12}'
expect 'hc-job' 'bash -c でスクリプトを実行中なら hc-job'

foreground t6 '{"argv":["bash","run.sh"],"name":"bash","pid":12}'
expect 'hc-job' 'シェルがスクリプトファイルを実行中なら hc-job'

terminals '{"address":"t1","agent":"claude-code","state":"live","status":"working"},{"address":"t5","agent":"sleep","state":"live"}'
expect 'hc-working+hc-job' 'working と job が同時にあれば両方'

terminals '{"address":"t7","agent":"bash","state":"live"}'
expect '' 'hc get が失敗した端末は数えない'

terminals ''
ino=$(stat -c %i "$HEAVY_LOCK")
printf '1: FLOCK  ADVISORY  WRITE 999 08:30:%s 0 EOF\n' "$ino" >"$PROC_LOCKS"
expect 'hc-job' 'heavy.lock が保持されていれば hc-job'
printf '1: FLOCK  ADVISORY  WRITE 999 08:30:%s 0 EOF\n' "$((ino + 1))" >"$PROC_LOCKS"
expect '' '別の inode のロックは数えない'
: >"$PROC_LOCKS"

terminals '{"address":"t1","agent":"claude-code","state":"live","status":"working"}'
start=$(date +%s)
got=$(HC_FAKE_SLEEP=10 hc_reasons)
elapsed=$(( $(date +%s) - start ))
[[ -z "$got" && $elapsed -lt 5 ]] && ok "hc が応答しなくても timeout で打ち切る (${elapsed}s)" || ng "hc 無応答: '${got}' ${elapsed}s"

expect_missing=$(HC_BIN="$fixture/none" hc_reasons)
[[ -z "$expect_missing" ]] && ok 'hc がなければ hc 条件は出さない' || ng "hc なしで '${expect_missing}'"

exit "$failures"
