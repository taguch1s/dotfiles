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

Repository policy decides branch naming, dependency setup, cleanup, and checks.
