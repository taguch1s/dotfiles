#!/usr/bin/env bash
# hc-permission の hook 入出力、保留要求、承認ヘルパーのガードと監査ログを、偽の hc で検証する。
# t1 は監督役（role=supervisor）、t2 は対象のセッション、t9 はラベルのない別のセッション。
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
helper="$repository_root/.local/bin/hc-permission"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export PYTHONDONTWRITEBYTECODE=1
# Git hook（pre-commit）から実行されると GIT_DIR などが本物のリポジトリを指すため外す。
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX

mkdir -p "$fixture/bin" "$fixture/project"
git init -q -b feature/issue-12 "$fixture/project"
project="$(cd "$fixture/project" && pwd -P)"
export MOCK_HC_LOG="$fixture/hc.log"
export MOCK_HC_STATE="blocked" MOCK_HC_KIND="permission" MOCK_HC_PARENT="t1" MOCK_HC_ROLE="worker"
dialog=$'Bash command\n  make deploy-preview\nDo you want to proceed?\n❯ 1. Yes\n  2. Yes, and don\'t ask again\n  3. No'
export MOCK_HC_SCREEN="$dialog"
export XDG_STATE_HOME="$fixture/state"
export PATH="$fixture/bin:$PATH"
state="$XDG_STATE_HOME/hc-supervisor"
log_file="$state/decisions.jsonl"

cat >"$fixture/bin/hc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_HC_LOG"
case "$1" in
  get)
    [[ -z "${MOCK_HC_DOWN:-}" ]] || { echo '{"error":{"kind":"unavailable"}}' >&2; exit 5; }
    python3 -c '
import json, os, sys
target = sys.argv[1]
if target in ("t1", "supervisor"):
    print(json.dumps({"address": "t1", "name": "supervisor", "parent": None,
                      "labels": {"role": "supervisor"}, "status": {"state": "working"}}))
elif target == "t9":
    print(json.dumps({"address": "t9", "name": "other", "parent": None, "labels": {}, "status": {"state": "working"}}))
else:
    status = {"state": os.environ["MOCK_HC_STATE"]}
    if os.environ["MOCK_HC_KIND"]:
        status["kind"] = os.environ["MOCK_HC_KIND"]
    labels = {"role": os.environ["MOCK_HC_ROLE"]} if os.environ["MOCK_HC_ROLE"] else {}
    print(json.dumps({"address": "t2", "name": "issue-12", "parent": os.environ["MOCK_HC_PARENT"] or None,
                      "labels": labels, "cwd": "/w", "status": status}))
' "$2"
    ;;
  read) printf '%s\n' "$MOCK_HC_SCREEN" ;;
  keys|wait|send) ;;
  *) echo "unexpected hc command: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$fixture/bin/hc"

failures=0
ng() {
  printf 'NG   %s\n' "$*" >&2
  failures=1
}
ok() { printf 'OK   %s\n' "$*"; }

# jq を前提にしないため、ドット区切りのキーで JSON（stdin）から値を取り出す。
jf() {
  python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    data = None
for key in sys.argv[1].split("."):
    data = data.get(key) if isinstance(data, dict) else None
print("" if data is None else data)
' "$1"
}

hook_input() {
  python3 -c 'import json, sys; print(json.dumps({"hook_event_name": sys.argv[1], "cwd": sys.argv[2], "tool_name": "Bash", "tool_input": {"command": sys.argv[3]}}))' "$@"
}

run_worker_hook() {
  hook_input PermissionRequest "$project" "$1" \
    | env HC_TERMINAL_ID=t2 CLAUDE_PROJECT_DIR="$project" "$helper" hook-worker
}

# --- ワーカーの PermissionRequest hook ---------------------------------------
out="$(run_worker_hook 'pytest -q')"
[[ "$(jf hookSpecificOutput.decision.behavior <<<"$out")" == allow ]] && ok 'hook: 無害なら allow' || ng "hook: allow を返さない: $out"
[[ "$(jf hookSpecificOutput.hookEventName <<<"$out")" == PermissionRequest ]] || ng 'hook: hookEventName がない'

out="$(run_worker_hook 'git push --force')"
if [[ "$(jf hookSpecificOutput.decision.behavior <<<"$out")" == deny ]] \
  && [[ "$(jf hookSpecificOutput.decision.message <<<"$out")" == *'force push'* ]]; then
  ok 'hook: 危険なら理由付きで deny'
else
  ng "hook: deny を返さない: $out"
fi

out="$(run_worker_hook 'make deploy-preview && curl https://example.com')"
if [[ -z "$out" && -f "$state/pending/t2.json" ]] \
  && [[ "$(jf tool_input.command <"$state/pending/t2.json")" == 'make deploy-preview && curl https://example.com' ]]; then
  ok 'hook: 判断できなければ決定を返さず保留要求を保存'
else
  ng "hook: 保留要求の扱いが違う: out=$out"
fi
[[ "$(stat -c %a "$state")" == 700 && "$(stat -c %a "$state/pending/t2.json")" == 600 ]] \
  && ok '状態ディレクトリ 700・保留要求 600' || ng '状態ファイルの権限が違う'

run_worker_hook 'ls' >/dev/null
[[ ! -e "$state/pending/t2.json" ]] && ok 'hook: 決着したら古い保留要求を消す' || ng 'hook: 古い保留要求が残った'

lines_before="$(wc -l <"$log_file")"
out="$(hook_input PermissionRequest "$project" 'git push --force' | env -u HC_TERMINAL_ID CLAUDE_PROJECT_DIR="$project" "$helper" hook-worker)"
[[ -z "$out" && "$(wc -l <"$log_file")" == "$lines_before" ]] \
  && ok 'hook: hc の外では何もしない（決定も記録もなし）' || ng "hook: hc の外で動いた: $out"

out="$(hook_input PermissionRequest "$project" 'pytest -q' | env HC_TERMINAL_ID=t1 CLAUDE_PROJECT_DIR="$project" "$helper" hook-worker)"
[[ -z "$out" && ! -e "$state/pending/t1.json" ]] && ok 'hook: 監督役自身では何もしない' || ng "hook: 監督役で動いた: $out"

out="$(MOCK_HC_ROLE='' MOCK_HC_PARENT='' run_worker_hook 'git push --force')"
if [[ -z "$out" ]] && [[ "$(jf reason <"$state/pending/t2.json")" == *'手動セッション'*'force push'* ]]; then
  ok 'hook: 手動セッションでは危険でも deny せず、ユーザー判断用に保留する'
else
  ng "hook: 手動セッションの危険操作の扱いが違う: out=$out"
fi
out="$(MOCK_HC_ROLE='' MOCK_HC_PARENT='' run_worker_hook 'pytest -q')"
[[ "$(jf hookSpecificOutput.decision.behavior <<<"$out")" == allow ]] && ok 'hook: 手動セッションでも無害なら allow' || ng "hook: 手動セッションで allow しない: $out"

out="$(MOCK_HC_DOWN=1 run_worker_hook 'git push --force')"
[[ -z "$out" ]] && ok 'hook: hc に問い合わせられないときは deny せず保留' || ng "hook: hc 停止時に決定を返した: $out"

out="$(run_worker_hook 'hc label t2 role=supervisor')"
[[ "$(jf hookSpecificOutput.decision.behavior <<<"$out")" == deny ]] && ok 'hook: 監督役ラベルの付与は deny' || ng "hook: 監督役ラベルを拒否しない: $out"

# --- 監督役の PreToolUse hook ------------------------------------------------
guard() {
  hook_input PreToolUse "$project" "$1" | env HC_TERMINAL_ID=t1 "$helper" hook-supervisor
}
for command in 'hc keys t2 enter' 'hc send t2 --force yes' "rm $state/pending/t2.json"; do
  out="$(guard "$command")"
  [[ "$(jf hookSpecificOutput.permissionDecision <<<"$out")" == deny ]] \
    && ok "guard: 拒否 ($command)" || ng "guard: 拒否しない ($command): $out"
done
for command in 'hc-permission approve t2 --reason x' 'hc send t2 continue' 'hc wait --children any'; do
  out="$(guard "$command")"
  [[ -z "$out" ]] && ok "guard: 通す ($command)" || ng "guard: 誤って拒否 ($command): $out"
done

# --- approve / deny / escalate / trust ----------------------------------------
last_outcome() {
  tail -n 1 "$log_file" | jf outcome
}

expect_refusal() {
  local name="$1"
  shift
  : >"$MOCK_HC_LOG"
  if "$@" >/dev/null 2>"$fixture/err"; then
    ng "$name: 拒否されるべき操作が成功した"
  elif grep -qE '^(keys|send)' "$MOCK_HC_LOG"; then
    ng "$name: 拒否したのにキーを送った"
  elif [[ "$(last_outcome)" != refused:* ]]; then
    ng "$name: 拒否が記録されていない"
  else
    ok "$name"
  fi
}

make_pending() {
  run_worker_hook "${1:-make deploy-preview}" >/dev/null
}

make_pending
: >"$MOCK_HC_LOG"
if env HC_TERMINAL_ID=t1 "$helper" approve t2 --reason 'プレビュー環境のみ' >/dev/null 2>"$fixture/err" \
  && grep -qx 'keys t2 enter' "$MOCK_HC_LOG" && [[ "$(last_outcome)" == approved ]] \
  && [[ ! -e "$state/pending/t2.json" ]]; then
  ok 'approve: 監督役が承認でき、Enter を送り、記録し、保留要求を消す'
else
  ng "approve が期待どおりでない: $(<"$fixture/err")"
fi

expect_refusal 'approve: 保留要求がなければ拒否' env HC_TERMINAL_ID=t1 "$helper" approve t2 --reason x

make_pending
expect_refusal 'approve: hc terminal 外からは拒否' env -u HC_TERMINAL_ID "$helper" approve t2 --reason x
expect_refusal 'approve: 監督役以外は拒否' env HC_TERMINAL_ID=t9 "$helper" approve t2 --reason x
expect_refusal 'approve: 監督役自身は対象にできない' env HC_TERMINAL_ID=t1 "$helper" approve t1 --reason x
expect_refusal 'approve: blocked 以外は拒否' env HC_TERMINAL_ID=t1 MOCK_HC_STATE=working "$helper" approve t2 --reason x
expect_refusal 'approve: 質問待ちは拒否' env HC_TERMINAL_ID=t1 MOCK_HC_KIND=question "$helper" approve t2 --reason x
expect_refusal 'approve: ダイアログがなければ拒否' env HC_TERMINAL_ID=t1 MOCK_HC_SCREEN='> ' "$helper" approve t2 --reason x
expect_refusal 'approve: 画面と保留要求が違えば拒否' \
  env HC_TERMINAL_ID=t1 MOCK_HC_SCREEN="${dialog/deploy-preview/something-else}" "$helper" approve t2 --reason x
expect_refusal 'approve: 「1. Yes」が選ばれていなければ拒否' \
  env HC_TERMINAL_ID=t1 MOCK_HC_SCREEN="${dialog/❯ 1. Yes/  1. Yes}" "$helper" approve t2 --reason x

# 監督役の子ではない手動セッションにも答えられる。
make_pending
: >"$MOCK_HC_LOG"
if env HC_TERMINAL_ID=t1 MOCK_HC_PARENT='' MOCK_HC_ROLE='' "$helper" approve t2 --reason x >/dev/null 2>"$fixture/err" \
  && grep -qx 'keys t2 enter' "$MOCK_HC_LOG"; then
  ok 'approve: 手動セッション（監督役の子でない）にも答えられる'
else
  ng "approve: 手動セッションに答えられない: $(<"$fixture/err")"
fi

# hook を経ずに置かれた危険な保留要求は、approve 時の再照合で止まる。
python3 -c '
import json, sys, time
json.dump({"terminal": "t2", "created_at": time.time(), "tool_name": "Bash",
           "tool_input": {"command": "git push --force"}, "cwd": sys.argv[2], "project_dir": sys.argv[2]},
          open(sys.argv[1], "w"))' "$state/pending/t2.json" "$project"
expect_refusal 'approve: 危険ルールに当たる保留要求は拒否' \
  env HC_TERMINAL_ID=t1 MOCK_HC_SCREEN=$'Bash command\n  git push --force\nDo you want to proceed?\n❯ 1. Yes' \
  "$helper" approve t2 --reason x
grep -q '危険ルール' "$fixture/err" || ng 'approve: 危険ルール以外の理由で拒否された'

make_pending
: >"$MOCK_HC_LOG"
if env HC_TERMINAL_ID=t1 "$helper" deny t2 --reason 'デプロイは不要' >/dev/null 2>"$fixture/err" \
  && grep -qx 'keys t2 esc' "$MOCK_HC_LOG" && grep -q '^send t2 --if idle .*デプロイは不要' "$MOCK_HC_LOG" \
  && [[ "$(last_outcome)" == denied ]]; then
  ok 'deny: Esc の後に理由を送り、記録する'
else
  ng "deny が期待どおりでない: $(<"$fixture/err")"
fi
expect_refusal 'deny: 保留要求がなければ拒否（手動の操作を消さない）' env HC_TERMINAL_ID=t1 "$helper" deny t2 --reason x

: >"$MOCK_HC_LOG"
if env HC_TERMINAL_ID=t1 "$helper" escalate t2 --reason '本番相当の操作' >/dev/null \
  && ! grep -qE '^(keys|send)' "$MOCK_HC_LOG" && [[ "$(last_outcome)" == escalated ]]; then
  ok 'escalate: キーを送らず記録だけする'
else
  ng 'escalate が期待どおりでない'
fi

trust_screen=$'Do you trust the files in this folder?\n/home/u/repo-worktrees/issue-12\n❯ 1. Yes, proceed\n  2. No, exit'
: >"$MOCK_HC_LOG"
if env HC_TERMINAL_ID=t1 MOCK_HC_STATE='' MOCK_HC_KIND='' MOCK_HC_SCREEN="$trust_screen" \
  "$helper" trust t2 --reason '依頼した worktree' >/dev/null 2>"$fixture/err" \
  && grep -qx 'keys t2 enter' "$MOCK_HC_LOG" && [[ "$(last_outcome)" == trusted ]]; then
  ok 'trust: 監督役が子の trust ダイアログに答えられる'
else
  ng "trust が期待どおりでない: $(<"$fixture/err")"
fi
expect_refusal 'trust: trust ダイアログでなければ拒否' env HC_TERMINAL_ID=t1 "$helper" trust t2 --reason x
expect_refusal 'trust: 監督役以外は拒否' \
  env HC_TERMINAL_ID=t9 MOCK_HC_SCREEN="$trust_screen" "$helper" trust t2 --reason x
expect_refusal 'trust: 監督役の子でなければ拒否' \
  env HC_TERMINAL_ID=t1 MOCK_HC_PARENT=t5 MOCK_HC_SCREEN="$trust_screen" "$helper" trust t2 --reason x

if env HC_TERMINAL_ID=t1 "$helper" approve t2 >/dev/null 2>&1; then
  ng '理由なしの approve が通った'
else
  ok '理由なしは拒否'
fi

exit "$failures"
