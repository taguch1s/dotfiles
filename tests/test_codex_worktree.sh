#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
launcher="$repository_root/.local/bin/codex-worktree"
fixture="$(mktemp -d)"
export SETUP_RECORD="$fixture/setup-record"
trap 'rm -rf "$fixture"' EXIT

remote="$fixture/remote.git"
primary="$fixture/project"
git init --bare "$remote" >/dev/null
git clone "$remote" "$primary" >/dev/null 2>&1
git -C "$primary" config user.email test@example.invalid
git -C "$primary" config user.name test
printf 'seed\n' >"$primary/README.md"
git -C "$primary" add README.md
git -C "$primary" commit -m seed >/dev/null
git -C "$primary" branch -M main
git -C "$primary" push -u origin main >/dev/null
git -C "$remote" symbolic-ref HEAD refs/heads/main

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "Expected failure: $*" >&2
    exit 1
  fi
}

expect_failure bash -c 'cd "$1" && "$2" feature/no-issue/missing-policy' -- "$primary" "$launcher"
mkdir -p "$primary/.agents"
printf '%s\n' '#!/usr/bin/env bash' 'pwd > "$SETUP_RECORD"' >"$primary/.agents/setup.sh"
chmod +x "$primary/.agents/setup.sh"
printf "%s\n" "PRIMARY_BRANCH=main" "WORKTREES_RELATIVE=../worktrees" "BRANCH_PATTERN='^(feature|chore)/no-issue/[a-z0-9-]+$'" "REQUIRE_CLEAN_PRIMARY=true" "SETUP_SCRIPT=.agents/setup.sh" >"$primary/.agents/codex-worktree.conf"
git -C "$primary" add .agents/codex-worktree.conf .agents/setup.sh
git -C "$primary" commit -m policy >/dev/null
git -C "$primary" push >/dev/null

expect_failure bash -c 'cd "$1" && "$2" invalid_branch' -- "$primary" "$launcher"
(cd "$primary" && "$launcher" feature/no-issue/first)
created="$fixture/worktrees/feature-no-issue-first"
[[ "$(git -C "$created" branch --show-current)" == feature/no-issue/first ]]
[[ "$(<"$SETUP_RECORD")" == "$created" ]]
expect_failure bash -c 'cd "$1" && "$2" feature/no-issue/first' -- "$primary" "$launcher"
foreign="$fixture/worktrees/chore-no-issue-foreign"
mkdir -p "$foreign"
git -C "$foreign" init -q
git -C "$foreign" config user.email test@example.invalid
git -C "$foreign" config user.name test
printf 'foreign\n' >"$foreign/README.md"
git -C "$foreign" add README.md
git -C "$foreign" commit -m foreign >/dev/null
git -C "$foreign" branch -m chore/no-issue/foreign
expect_failure bash -c 'cd "$1" && "$2" --start chore/no-issue/foreign' -- "$primary" "$launcher"

printf 'dirty\n' >>"$primary/README.md"
expect_failure bash -c 'cd "$1" && "$2" chore/no-issue/blocked' -- "$primary" "$launcher"
git -C "$primary" restore README.md
(cd "$primary" && "$launcher" chore/no-issue/second)
[[ "$(git -C "$fixture/worktrees/chore-no-issue-second" branch --show-current)" == chore/no-issue/second ]]

stubs="$fixture/stubs"
mkdir -p "$stubs"
for agent in codex claude; do
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s|%s|%s\n' $agent \"\$(pwd -P)\" \"\$*\" >\"\$AGENT_RECORD\"" >"$stubs/$agent"
  chmod +x "$stubs/$agent"
done
export AGENT_RECORD="$fixture/agent-record"
second="$(cd "$fixture/worktrees/chore-no-issue-second" && pwd -P)"
(cd "$primary" && PATH="$stubs:$PATH" "$launcher" --start chore/no-issue/second)
[[ "$(<"$AGENT_RECORD")" == "codex|$(cd "$primary" && pwd -P)|-C $second" ]]
(cd "$primary" && PATH="$stubs:$PATH" "$repository_root/.local/bin/claude-worktree" --start chore/no-issue/second)
[[ "$(<"$AGENT_RECORD")" == "claude|$second|" ]]
ln -s "$launcher" "$fixture/other-worktree"
expect_failure bash -c 'cd "$1" && "$2" chore/no-issue/third' -- "$primary" "$fixture/other-worktree"

echo 'codex-worktree launcher tests passed'
