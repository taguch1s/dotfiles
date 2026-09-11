#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve, sep } from "node:path";

const SIGNALS = {
  implementation: /実装|作成|追加|変更|修正|直して|調整|対応して|更新して|削除して|導入/,
  investigation: /調査|分析|確認|レビュー|見て|調べ|原因|なぜ|どうして/,
  design: /設計|要件|計画|プラン|方針|提案|検討|壁打ち/,
  issue: /issue|イシュー/i,
  commit: /commit|コミット/i,
  pullRequest: /\bPR\b|プルリク/i,
  directQuestion: /[?？]|ですか|でしょうか|どう思|教えて|説明して/,
  correction: /ちげー|違う|そうでは|そうじゃ|いや[、,]|勝手|依頼して|お願いして|話を聞|なってない|できてない|不十分|やり直|意味が分から/,
  scopeBoundary: /実装しない|変更しない|作成しない|コミットしない|不要|スコープ|別issue|別Issue/,
  continuation: /続けて|進めて|そのまま|最後まで|完了まで|自律|再開/,
  multipleDeliverables: /それぞれ|各issue|各Issue|複数|全件|全部/,
  worktree: /worktree/i,
  skillOrAgent: /skill|スキル|sub.?agent|サブ.?エージェント|並列|agent/i,
};

function parseArgs(argv) {
  const options = { codexDir: join(homedir(), ".codex"), repo: process.cwd() };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--codex-dir" || argument === "--repo") {
      const value = argv[index + 1];
      if (!value) throw new Error(`${argument} requires a path`);
      options[argument === "--repo" ? "repo" : "codexDir"] = value;
      index += 1;
      continue;
    }
    if (argument === "--help") {
      process.stdout.write("Usage: audit-logs.mjs [--codex-dir <path>] [--repo <path>]\n");
      process.exit(0);
    }
    throw new Error(`Unknown argument: ${argument}`);
  }
  options.codexDir = resolve(options.codexDir);
  options.repo = resolve(options.repo);
  return options;
}

function collectJsonlFiles(directory) {
  if (!existsSync(directory)) return [];
  const files = [];
  for (const entry of readdirSync(directory)) {
    const path = join(directory, entry);
    if (statSync(path).isDirectory()) files.push(...collectJsonlFiles(path));
    else if (entry.endsWith(".jsonl")) files.push(path);
  }
  return files;
}

function readJsonLines(path) {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter(Boolean)
    .flatMap((line) => {
      try {
        return [JSON.parse(line)];
      } catch {
        return [];
      }
    });
}

function readRepositoryUrl(repository) {
  const dotGitPath = join(repository, ".git");
  if (!existsSync(dotGitPath)) return null;

  let gitDirectory = dotGitPath;
  if (!statSync(dotGitPath).isDirectory()) {
    const match = readFileSync(dotGitPath, "utf8").match(/^gitdir:\s*(.+)$/m);
    if (!match) return null;
    gitDirectory = resolve(repository, match[1]);
  }

  const commonDirPath = join(gitDirectory, "commondir");
  const commonDirectory = existsSync(commonDirPath)
    ? resolve(gitDirectory, readFileSync(commonDirPath, "utf8").trim())
    : gitDirectory;
  const configPath = join(commonDirectory, "config");
  if (!existsSync(configPath)) return null;

  const config = readFileSync(configPath, "utf8");
  const originSection = config.match(/\[remote "origin"\]([\s\S]*?)(?=\n\[|$)/);
  return originSection?.[1].match(/^\s*url\s*=\s*(.+)$/m)?.[1]?.trim() ?? null;
}

function isSubagentSource(source) {
  return source === "subagent" || (source && typeof source === "object");
}

function normalizeUserMessage(message) {
  const marker = "## My request for Codex:";
  const markerIndex = message.indexOf(marker);
  return (markerIndex >= 0 ? message.slice(markerIndex + marker.length) : message).trim();
}

function summarizeLengths(values) {
  if (values.length === 0) return { average: 0, median: 0, p90: 0 };
  const sorted = [...values].sort((left, right) => left - right);
  return {
    average: Math.round(sorted.reduce((sum, value) => sum + value, 0) / sorted.length),
    median: sorted[Math.floor(sorted.length / 2)],
    p90: sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.9))],
  };
}

function fingerprint(...parts) {
  return createHash("sha256").update(parts.join("\0")).digest("hex");
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const indexPath = join(options.codexDir, "session_index.jsonl");
  if (!existsSync(indexPath)) throw new Error("session_index.jsonl was not found");

  const indexRows = readJsonLines(indexPath);
  const repositoryUrl = readRepositoryUrl(options.repo);
  const rolloutFiles = [
    ...collectJsonlFiles(join(options.codexDir, "sessions")),
    ...collectJsonlFiles(join(options.codexDir, "archived_sessions")),
  ];

  const userMessages = [];
  const assistantMessages = [];
  const turnsPerSession = [];
  const timestamps = [];
  const seenUserMessages = new Set();
  const seenAssistantMessages = new Set();
  let matchedSessions = 0;

  for (const path of rolloutFiles) {
    const records = readJsonLines(path);
    const firstSessionMeta = records.find(({ type }) => type === "session_meta");
    if (!firstSessionMeta || isSubagentSource(firstSessionMeta.payload?.thread_source)) continue;
    const belongsToRepo = records.some(({ type, payload = {} }) => {
      if (type !== "session_meta" || isSubagentSource(payload.thread_source)) return false;
      if (repositoryUrl && payload.git?.repository_url === repositoryUrl) return true;
      if (typeof payload.cwd !== "string") return false;
      const workingDirectory = resolve(payload.cwd);
      return workingDirectory === options.repo || workingDirectory.startsWith(`${options.repo}${sep}`);
    });
    if (!belongsToRepo) continue;

    matchedSessions += 1;
    let rootConversation = true;
    let sessionUserTurns = 0;
    for (const record of records) {
      const payload = record.payload ?? {};
      if (record.type === "session_meta") {
        rootConversation = !isSubagentSource(payload.thread_source);
        continue;
      }
      if (!rootConversation || record.type !== "event_msg") continue;

      if (payload.type === "user_message") {
        const message = normalizeUserMessage(String(payload.message ?? ""));
        if (!message) continue;
        const key = payload.client_id || fingerprint(record.timestamp ?? "", message);
        if (seenUserMessages.has(key)) continue;
        seenUserMessages.add(key);
        userMessages.push(message);
        sessionUserTurns += 1;
        if (record.timestamp) timestamps.push(record.timestamp);
      }

      if (payload.type === "agent_message") {
        const message = String(payload.message ?? "").trim();
        if (!message) continue;
        const phase = payload.phase ?? "unknown";
        const key = fingerprint(record.timestamp ?? "", phase, message);
        if (seenAssistantMessages.has(key)) continue;
        seenAssistantMessages.add(key);
        assistantMessages.push({ message, phase });
      }
    }
    turnsPerSession.push(sessionUserTurns);
  }

  const userLengths = userMessages.map((message) => Array.from(message).length);
  const finalLengths = assistantMessages
    .filter(({ phase }) => phase === "final_answer" || phase === "final")
    .map(({ message }) => Array.from(message).length);
  const commentaryLengths = assistantMessages
    .filter(({ phase }) => phase === "commentary")
    .map(({ message }) => Array.from(message).length);
  const signals = Object.fromEntries(
    Object.entries(SIGNALS).map(([name, pattern]) => [
      name,
      userMessages.filter((message) => pattern.test(message)).length,
    ]),
  );
  const nonEmptySessions = turnsPerSession.filter((count) => count > 0);
  timestamps.sort();

  const output = {
    schemaVersion: 1,
    privacy: "Aggregate only; no message text, thread names, IDs, URLs, or log paths are emitted.",
    scope: {
      repository: basename(options.repo),
      period: {
        from: timestamps[0]?.slice(0, 10) ?? null,
        to: timestamps.at(-1)?.slice(0, 10) ?? null,
      },
    },
    sessions: {
      indexed: indexRows.length,
      matchedToRepository: matchedSessions,
      withUserMessages: nonEmptySessions.length,
      multiTurn: nonEmptySessions.filter((count) => count > 1).length,
      userTurnsPerSession: summarizeLengths(nonEmptySessions),
    },
    messages: {
      user: userMessages.length,
      userLength: summarizeLengths(userLengths),
      userUnder20Characters: userLengths.filter((length) => length < 20).length,
      assistantFinal: finalLengths.length,
      assistantFinalLength: summarizeLengths(finalLengths),
      assistantCommentary: commentaryLengths.length,
      assistantCommentaryLength: summarizeLengths(commentaryLengths),
    },
    userSignals: signals,
    notes: [
      "Signal categories overlap and are indicators, not sentiment labels.",
      "Qualitative conclusions require a small targeted review of relevant turns.",
    ],
  };
  process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}
