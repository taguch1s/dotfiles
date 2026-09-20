---
name: shared-codex-workflow
description: Use when starting, resuming, or handing off AI-assisted work across the user's local repositories, especially when a Git worktree or shared Codex policy is involved.
---

# Shared Codex Workflow

Use the repository's `AGENTS.md` and tracked worktree policy as the source for repository-specific rules. This skill supplies only cross-repository invariants.

Before creating, resuming, or changing a worktree:

1. Confirm the Git root, active branch, worktree list, and working-tree status.
2. Use the installed shared launcher only when the repository has its tracked policy file. Stop rather than applying another repository's policy.
3. Treat one worktree as one task. Never edit the same worktree concurrently from multiple agent sessions.
4. Record task decisions and verification in tracked artifacts or a handoff; do not rely on chat history or Memory as the only source.

## Herdr fixed delegate and reclaim contract

When the tracked launcher starts a Herdr task, `--delegates N` is the strict concurrency and pane cap for that tab. Main and delegates do not add nested panes, tabs, agents, or reviewers. A delegate returns one bounded Unit's evidence, checks, handoff state, blockers, and safe next action; the parent either explicitly accepts and reassigns that same delegate or reclaims its pane.

`done` / `idle` means `reclaimable`, not recovered. After all Units, only the parent may decide whether to close a tab after reading Issue/PR, agent stop, worktree clean, handoff delivery, and downstream pane need. This contract never authorizes an unconditional automatic close.

When a delegate returns a bounded Unit, the parent executes its recorded safe next action, reassigns the same fixed delegate, or conditionally reclaims the pane. A delivery intent (`none|commit|pr`) is handoff evidence, not permission to add a review, pane, tab, or agent.

At the repository handoff threshold, an auto continuation is only a PR-delivery recovery path when recorded `continuation=auto` has no external manual/human gate, unresolved specification decision, or safety blocker. It first verifies a distinct nonempty successor main session by Herdr read-back; it neither grants external authority nor turns an intermediate delegate report into `done`.

Repository policy decides branch naming, dependency setup, cleanup, and checks.
