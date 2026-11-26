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
unset HC_TERMINAL_ID CLAUDE_CTX_GUARD_TOKENS HC_CLAUDE_SUPERVISOR_CTX_GUARD_TOKENS HC_CLAUDE_WORKER_CTX_GUARD_TOKENS
cat >"$HC_CLAUDE_BIN" <<'EOF'
#!/usr/bin/env bash
(IFS=$'\x1f'; printf '%s\n' "$*") >"$(dirname "$0")/args"
printf '%s\n' "${CLAUDE_CTX_GUARD_TOKENS-unset}" >"$(dirname "$0")/ctx"
printf '%s\n' "${HC_CLAUDE_ROLE-unset}" >"$(dirname "$0")/role"
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
[[ "$(args)" == "--model fable --effort high "*"--append-system-prompt-file $config/supervisor-prompt.md" ]] && ok 'dev: 監督役は fable・effort high・監督役のプロンプトで起動する' \
  || ng "監督役の引数が違う: $(args)"

# モデル: 既定は opus。ワーカーだけ役割の直後の --model で opus / sonnet を選べる（#33）。
worker_tail="--effort medium --permission-mode bypassPermissions --settings $config/session-settings.json --append-system-prompt-file $config/worker-prompt.md"
"$launcher" worker --model sonnet '依頼文'
[[ "$(args)" == "--model sonnet $worker_tail 依頼文" ]] \
  && ok 'モデル: ワーカーは --model sonnet で sonnet を使い、--model を claude に二重に渡さない' || ng "--model sonnet の引数が違う: $(args)"
"$launcher" worker --model=sonnet '依頼文'
[[ "$(args)" == "--model sonnet $worker_tail 依頼文" ]] && ok 'モデル: --model=sonnet の形も受け付ける' || ng "--model=sonnet の引数が違う: $(args)"
"$launcher" worker --model opus '依頼文'
[[ "$(args)" == "--model opus $worker_tail 依頼文" ]] && ok 'モデル: --model opus を明示できる' || ng "--model opus の引数が違う: $(args)"
bad_ok=1
for bad in haiku Sonnet fable 'opus sonnet' claude-sonnet-4-5 ''; do
  "$launcher" worker --model "$bad" '依頼文' 2>"$fixture/err"
  [[ "$(args)" == "--model opus $worker_tail 依頼文" ]] || { ng "許可しないモデル '$bad' で opus に戻らない: $(args)"; bad_ok=0; }
  grep -q '許可していないモデル' "$fixture/err" || { ng "許可しないモデル '$bad' を黙って捨てた"; bad_ok=0; }
done
[[ "$bad_ok" == 1 ]] && ok 'モデル: 許可しない名前（opus・sonnet 以外）は警告して opus で起動する（起動は止めない）'
"$launcher" supervisor --model opus 2>"$fixture/err"
[[ "$(args)" == "--model opus --effort high "*"--append-system-prompt-file $config/supervisor-prompt.md" && ! -s "$fixture/err" ]] \
  && ok 'モデル: 監督役は --model opus で opus を使う（既定は fable）' || ng "監督役の --model opus の扱いが違う: $(args) / $(cat "$fixture/err")"
"$launcher" supervisor --model=fable 2>"$fixture/err"
[[ "$(args)" == "--model fable --effort high "* && ! -s "$fixture/err" ]] \
  && ok 'モデル: 監督役は --model=fable を明示できる' || ng "監督役の --model=fable の扱いが違う: $(args) / $(cat "$fixture/err")"
"$launcher" supervisor --model sonnet 2>"$fixture/err"
[[ "$(args)" == "--model fable --effort high "* && "$(args)" != *sonnet* ]] && grep -q '許可していないモデルなので、fable を使います' "$fixture/err" \
  && ok 'モデル: 監督役に許可しないモデルは、警告して既定の fable で起動する' || ng "監督役の --model の扱いが違う: $(args) / $(cat "$fixture/err")"
python3 - "$repository_root/.config/herdr-core/templates/claude-supervisor.md" "$repository_root/.config/herdr-core/templates/claude-supervisor-opus.md" \
  "$repository_root/dotfiles.toml" <<'PY' && ok 'テンプレート: claude-supervisor は fable（--model なし）、claude-supervisor-opus は --model opus、どちらも link する' \
  || ng '監督役のテンプレートが違う'
import re, sys, tomllib
def command(path):
    return re.search(r"^command: (.*)$", open(path).read(), re.M).group(1)
assert command(sys.argv[1]) == "hc-claude supervisor", command(sys.argv[1])
assert command(sys.argv[2]) == "hc-claude supervisor --model opus", command(sys.argv[2])
# 依頼文の前置き（本文）は同じにする（モデル以外の振る舞いを変えない）。
body = lambda p: open(p).read().split("---\n", 2)[2]
assert body(sys.argv[1]) == body(sys.argv[2])
sources = {c.get("source") for c in tomllib.load(open(sys.argv[3], "rb"))["config"]}
for name in ("claude-supervisor.md", "claude-supervisor-opus.md"):
    assert ".config/herdr-core/templates/" + name in sources, name
PY
if "$launcher" worker --model 2>/dev/null; then ng '値のない --model を受け付けた'; else ok 'モデル: 値のない --model は使い方の誤りとして拒否'; fi
python3 - "$repository_root/.config/herdr-core/templates/claude-worker.md" "$repository_root/.config/herdr-core/templates/claude-worker-sonnet.md" \
  "$repository_root/dotfiles.toml" <<'EOF' && ok 'テンプレート: claude-worker は opus（--model なし）、claude-worker-sonnet は --model sonnet、どちらも link する' \
  || ng 'ワーカーのテンプレートが違う'
import re, sys, tomllib
def command(path):
    return re.search(r"^command: (.*)$", open(path).read(), re.M).group(1)
assert command(sys.argv[1]) == "hc-claude worker", command(sys.argv[1])
assert command(sys.argv[2]) == "hc-claude worker --model sonnet", command(sys.argv[2])
# 依頼文の前置き（本文）は同じにする（モデル以外の振る舞いを変えない）。
body = lambda p: open(p).read().split("---\n", 2)[2]
assert body(sys.argv[1]) == body(sys.argv[2])
sources = {c.get("source") for c in tomllib.load(open(sys.argv[3], "rb"))["config"]}
assert {".config/herdr-core/templates/claude-worker.md", ".config/herdr-core/templates/claude-worker-sonnet.md"} <= sources
EOF

# 文脈予算の閾値（claude-context-guard が読む CLAUDE_CTX_GUARD_TOKENS）を役割ごとに渡す。
ctx() { cat "$fixture/bin/ctx"; }
"$launcher" supervisor
[[ "$(ctx)" == 150000 ]] && ok '閾値: 監督役は既定 150000' || ng "監督役の閾値が違う: $(ctx)"
"$launcher" worker x
[[ "$(ctx)" == 120000 ]] && ok '閾値: ワーカーは既定 120000' || ng "ワーカーの閾値が違う: $(ctx)"
CLAUDE_CTX_GUARD_TOKENS=150000 "$launcher" worker x
[[ "$(ctx)" == 120000 ]] && ok '閾値: 呼び出し元の CLAUDE_CTX_GUARD_TOKENS（監督役の値など）はワーカーに持ち込まない' \
  || ng "呼び出し元の閾値を持ち込んだ: $(ctx)"
HC_CLAUDE_WORKER_CTX_GUARD_TOKENS=5000 HC_CLAUDE_SUPERVISOR_CTX_GUARD_TOKENS=7000 "$launcher" worker x
[[ "$(ctx)" == 5000 ]] && ok '閾値: HC_CLAUDE_WORKER_CTX_GUARD_TOKENS でワーカーの閾値を上書きできる' || ng "ワーカーの上書きが違う: $(ctx)"
HC_CLAUDE_WORKER_CTX_GUARD_TOKENS=5000 HC_CLAUDE_SUPERVISOR_CTX_GUARD_TOKENS=7000 "$launcher" supervisor
[[ "$(ctx)" == 7000 ]] && ok '閾値: HC_CLAUDE_SUPERVISOR_CTX_GUARD_TOKENS で監督役の閾値を上書きできる' || ng "監督役の上書きが違う: $(ctx)"
bad_ok=1
for bad in abc 0 -1 1e5 ''; do
  HC_CLAUDE_WORKER_CTX_GUARD_TOKENS="$bad" "$launcher" worker x 2>"$fixture/err"
  [[ "$(ctx)" == 120000 ]] || { ng "不正な上書き値 '$bad' で既定に戻らない: $(ctx)"; bad_ok=0; }
  [[ -z "$bad" || -s "$fixture/err" ]] || { ng "不正な上書き値 '$bad' を黙って捨てた"; bad_ok=0; }
done
[[ "$bad_ok" == 1 ]] && ok '閾値: 正の整数でない上書き値は警告して既定に戻す（起動は止めない）'

# 役割（claude-token-metrics record が hc.role に記録する）。呼び出し元の値は持ち込まない。
role_of() { cat "$fixture/bin/role"; }
HC_CLAUDE_ROLE=supervisor "$launcher" worker x
[[ "$(role_of)" == worker ]] && ok '役割: ワーカーは HC_CLAUDE_ROLE=worker（呼び出し元の値を上書きする）' || ng "ワーカーの役割が違う: $(role_of)"
"$launcher" supervisor
[[ "$(role_of)" == supervisor ]] && ok '役割: 監督役は HC_CLAUDE_ROLE=supervisor' || ng "監督役の役割が違う: $(role_of)"

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

# 作業ディレクトリの外の記録（#44）。~/.claude/settings.json の blockReadsOutsideWorkingDirectories: true は
# どの設定ファイルの false でも外せないので、hc のセッションだけ読める範囲を additionalDirectories で足す
# （リストは設定ファイルの間で足し合わされる）。手動セッション（ユーザー設定）の読み取り制限は弱めない。
# --add-dir は対話セッションで信頼の確認を出しうるので、hc-claude の引数では足さない（上のワーカー・監督役の
# 引数の完全一致の検査が、--add-dir を渡さないことも確かめている）。
python3 - "$repository_root/.config/herdr-core/claude/session-settings.json" "$repository_root/.claude/settings.json" <<'EOF' \
  && ok 'session-settings: 計測の記録（~/.claude/projects・claude-token-metrics・hc-supervisor）を additionalDirectories で読める範囲に足し、ユーザー設定の読み取り制限は変えない' \
  || ng 'session-settings の読める範囲（additionalDirectories）か、ユーザー設定の読み取り制限が違う'
import json, sys
session = json.load(open(sys.argv[1]))
user = json.load(open(sys.argv[2]))
permissions = session["permissions"]
assert permissions["additionalDirectories"] == [
    "~/.claude/projects",
    "~/.local/share/claude-token-metrics",
    "~/.local/share/hc-supervisor",
], permissions["additionalDirectories"]
# 読み取りを広げるのは上の 3 つだけ。block を false にする（効かない上に誤解を招く）・allow で広げることはしない。
assert set(permissions) == {"defaultMode", "additionalDirectories"}, sorted(permissions)
# 手動セッションの正本（リポジトリ版 .claude/settings.json）は、外の読み取りを止めたまま、読める範囲を足さない。
assert user["permissions"]["blockReadsOutsideWorkingDirectories"] is True
assert "additionalDirectories" not in user["permissions"]
EOF

# 文脈予算 hook とトークン記録。ユーザー設定（リポジトリ版 .claude/settings.json → ~/.claude/settings.json）
# と同じ command 文字列にしておくと、Claude Code が同じ hook として 1 回だけ実行する。
python3 - "$repository_root/.config/herdr-core/claude/session-settings.json" "$repository_root/.claude/settings.json" <<'EOF' \
  && ok 'session-settings: UserPromptSubmit・PostToolUse → claude-context-guard、SessionEnd → claude-token-metrics record（ユーザー設定と同じ command）' \
  || ng 'session-settings の文脈予算 hook・トークン記録が違う'
import json, sys
session = json.load(open(sys.argv[1]))
user = json.load(open(sys.argv[2]))
expected = {
    "UserPromptSubmit": "~/.local/bin/claude-context-guard",
    "PostToolUse": "~/.local/bin/claude-context-guard",
    "SessionEnd": "~/.local/bin/claude-token-metrics record || true",
}

def handlers(settings, event):
    return [h for g in settings.get("hooks", {}).get(event, []) for h in g["hooks"]]

for event, command in expected.items():
    mine = [h for h in handlers(session, event) if h.get("command") == command]
    assert len(mine) == 1, (event, handlers(session, event))
    assert mine[0]["type"] == "command" and 0 < mine[0].get("timeout", 0) <= 10, mine[0]
    # 呼ぶたびに全イベントで動かす（matcher で絞らない）。
    assert all("matcher" not in g for g in session["hooks"][event]), event
    assert command in [h.get("command") for h in handlers(user, event)], (event, "ユーザー設定と command 文字列が違う")
EOF

exit "$failures"
