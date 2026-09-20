#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_hook="$root/.githooks/pre-push"
source_validator="$root/.agents/skills/issue-development-workflow/scripts/check-workflow-progress.py"

test -x "$source_hook"
test -f "$source_validator"
! rg -q 'WORKFLOW_PROGRESS|HANDOFF.*=' "$source_hook"
! rg -q 'find .*codex-handoffs|for .*codex-handoffs' "$source_hook"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
remote="$fixture/remote.git"
repo="$fixture/repo"
branch='feature/issue-9-workflow-progress-review-gate'

git init --bare "$remote" >/dev/null
git init -b "$branch" "$repo" >/dev/null
git -C "$repo" config user.name 'Workflow fixture'
git -C "$repo" config user.email 'workflow@example.invalid'
mkdir -p "$repo/.githooks" "$repo/.agents/skills/issue-development-workflow/scripts"
cp "$source_hook" "$repo/.githooks/pre-push"
cp "$source_validator" "$repo/.agents/skills/issue-development-workflow/scripts/check-workflow-progress.py"
chmod 755 "$repo/.githooks/pre-push"
git -C "$repo" config core.hooksPath .githooks
git -C "$repo" remote add origin "$remote"

printf 'seed\n' >"$repo/README"
git -C "$repo" add README
git -C "$repo" commit -m 'seed' >/dev/null
head="$(git -C "$repo" rev-parse HEAD)"
handoff_dir="$(git -C "$repo" rev-parse --path-format=absolute --git-path codex-handoffs)"
mkdir -p "$handoff_dir"

cat >"$handoff_dir/issue-9.md" <<EOF
<!-- workflow-progress/v1:start -->
\`\`\`json
{"version":"workflow-progress/v1","issue":{"repository":"taguch1s/dotfiles","number":9,"url":"https://github.com/taguch1s/dotfiles/issues/9"},"git":{"branch":"$branch","head":"$head"},"current_unit":{"id":"U3","status":"accepted","next_action":""},"units":[{"id":"U3","status":"accepted","required_for_delivery":true,"review":{"kind":"light","outcome":"pass","independence":"fresh","degraded_reason":null,"reviewed_head":"$head","evidence":[{"locator":"workflow-review-unit-U3","summary":"fresh Unit review"}]}}],"final_review":{"kind":"full","outcome":"pass","independence":"fresh","degraded_reason":null,"reviewed_head":"$head","evidence":[{"locator":"workflow-review-final","summary":"fresh final review"}]},"remote_sync":{"status":"pending","pending_actions":["post after push"]},"delivery":{"intent":"pr","state":"in_progress","pr_url":null,"read_back_evidence":[],"pause_reason":null},"continuation":"auto"}
\`\`\`
<!-- workflow-progress/v1:end -->
<!-- workflow-review-section/v1 id="workflow-review-unit-U3" unit="U3" kind="light" reviewed_head="$head" -->
### Review evidence: Unit U3
<!-- workflow-review-section/v1 id="workflow-review-final" kind="full" reviewed_head="$head" -->
### Review evidence: Final delivery
EOF

cat >"$repo/.githooks/workflow-progress.toml" <<EOF
[[issue_branch]]
branch = "$branch"
handoff = "issue-9.md"

[[out_of_scope_branch]]
branch = "release/manual-only"
reason = "release handoff is outside Issue #9 adoption"
EOF

git -C "$repo" push -u origin "$branch" >/dev/null

git -C "$repo" checkout -b feature/no-issue/local-test >/dev/null
printf 'no issue\n' >>"$repo/README"
git -C "$repo" commit -am 'no issue' >/dev/null
git -C "$repo" push -u origin feature/no-issue/local-test >/dev/null

git -C "$repo" checkout -b release/manual-only "$branch" >/dev/null
printf 'out of scope\n' >>"$repo/README"
git -C "$repo" commit -am 'out of scope' >/dev/null
git -C "$repo" push -u origin release/manual-only >/dev/null

git -C "$repo" checkout -b feature/issue-99-missing "$branch" >/dev/null
printf 'missing mapping\n' >>"$repo/README"
git -C "$repo" commit -am 'missing mapping' >/dev/null
if git -C "$repo" push -u origin feature/issue-99-missing >"$fixture/missing.out" 2>&1; then
  echo 'Issue-like branch without mapping unexpectedly pushed' >&2
  exit 1
fi
rg -F 'NG workflow-progress: mapping is required' "$fixture/missing.out" >/dev/null

git -C "$repo" checkout -b experiment/unknown "$branch" >/dev/null
printf 'unknown\n' >>"$repo/README"
git -C "$repo" commit -am 'unknown branch' >/dev/null
if git -C "$repo" push -u origin experiment/unknown >"$fixture/unknown.out" 2>&1; then
  echo 'unknown branch unexpectedly pushed' >&2
  exit 1
fi
rg -F 'NG workflow-progress: branch is unclassified' "$fixture/unknown.out" >/dev/null

echo 'workflow pre-push tests passed'
