#!/usr/bin/env node
// 校验 disk-cleanup 的清理项编码在「脚本 / SKILL.md / references/cleanup.md / skill-internals.md」四处是否一致。
//
// 单一事实源是 `mac_cleanup.sh --list --json`（脚本里的 KNOWN_IDS + 元数据），
// 其余三处文档必须与之对齐：漏写 → 用户看不到这项；多写 → 报了个脚本不认的编码（--only 会 exit 1）。
//
// 退出码：0 一致 / 1 不一致 / 2 用法或环境错误。

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SCRIPT = join(repoRoot, "skills/disk-cleanup/scripts/mac_cleanup.sh");
const SKILL = join(repoRoot, "skills/disk-cleanup/SKILL.md");
const REFS = join(repoRoot, "skills/disk-cleanup/references/cleanup.md");
const INTERNALS = join(repoRoot, "docs/agents/skill-internals.md");

function fail(msg) {
  console.error(`[disk-cleanup-codes] ${msg}`);
  process.exitCode = 1;
}

function readCodes() {
  let out;
  try {
    out = execFileSync("bash", [SCRIPT, "--list", "--json"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch (err) {
    console.error(`[disk-cleanup-codes] 无法执行 ${SCRIPT} --list --json：${err.message}`);
    process.exit(2);
  }
  let data;
  try {
    data = JSON.parse(out);
  } catch (err) {
    console.error(`[disk-cleanup-codes] --list --json 输出不是合法 JSON：${err.message}`);
    process.exit(2);
  }
  if (!Array.isArray(data.codes) || data.codes.length === 0) {
    console.error("[disk-cleanup-codes] --list --json 里没有 codes 数组");
    process.exit(2);
  }
  return data.codes.map((c) => c.id);
}

// 抽取一段文本里所有 `xxx` 形式的标识符
function backticks(text) {
  return [...text.matchAll(/`([a-z][a-z0-9_-]*)`/g)].map((m) => m[1]);
}

// references/cleanup.md：编码表每行以 "| `code` |" 开头
function codesFromRefs() {
  const text = readFileSync(REFS, "utf8");
  const lines = text.split("\n");
  const start = lines.findIndex((l) => l.startsWith("### 清理项编码"));
  if (start === -1) {
    console.error("[disk-cleanup-codes] references/cleanup.md 里找不到「### 清理项编码」小节");
    process.exit(2);
  }
  const codes = [];
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith("#")) break;
    const m = line.match(/^\|\s*`([a-z][a-z0-9_-]*)`\s*\|/);
    if (m) codes.push(m[1]);
  }
  if (codes.length === 0) {
    console.error("[disk-cleanup-codes] references/cleanup.md 的编码表里没解析到任何编码");
    process.exit(2);
  }
  return codes;
}

// SKILL.md：只取勾选表（表头含「传给 `--only` 的编码」那张表）里的编码
function codesFromSkill() {
  const text = readFileSync(SKILL, "utf8");
  const lines = text.split("\n");
  const head = lines.findIndex((l) => l.includes("传给 `--only` 的编码"));
  if (head === -1) {
    console.error("[disk-cleanup-codes] SKILL.md 里找不到勾选表（表头含「传给 `--only` 的编码」）");
    process.exit(2);
  }
  const codes = new Set();
  for (let i = head + 2; i < lines.length; i++) {
    const line = lines[i];
    if (!line.startsWith("|")) break;
    const cells = line.split("|");
    // 第二列 = 传给 --only 的编码（可能写成 `caches,logs`）
    const cell = cells[2] ?? "";
    for (const tok of cell.split(/`([^`]*)`/)) {
      for (const id of tok.split(",")) {
        const t = id.trim();
        if (/^[a-z][a-z0-9_-]*$/.test(t)) codes.add(t);
      }
    }
  }
  if (codes.size === 0) {
    console.error("[disk-cleanup-codes] SKILL.md 勾选表里没解析到任何编码");
    process.exit(2);
  }
  return [...codes];
}

// skill-internals.md：取「清理项编码（…）」括号里那串
function codesFromInternals() {
  const text = readFileSync(INTERNALS, "utf8");
  const m = text.match(/清理项编码（([^）]*)）/);
  if (!m) {
    console.error("[disk-cleanup-codes] skill-internals.md 里找不到「清理项编码（…）」清单");
    process.exit(2);
  }
  return backticks(m[1]).filter((c) => c !== "all" && c !== "list");
}

const scriptCodes = readCodes();
const refsCodes = codesFromRefs();
const skillCodes = codesFromSkill();
const internalsCodes = codesFromInternals();

const want = new Set(scriptCodes);
const sources = [
  ["references/cleanup.md 编码表", refsCodes],
  ["SKILL.md 勾选表", skillCodes],
  ["docs/agents/skill-internals.md 编码清单", internalsCodes],
];

for (const [name, got] of sources) {
  const seen = new Set(got);
  const missing = scriptCodes.filter((c) => !seen.has(c));
  const extra = got.filter((c) => !want.has(c));
  if (missing.length) fail(`${name} 缺少编码：${missing.join(", ")}`);
  if (extra.length) fail(`${name} 出现脚本不认的编码：${[...new Set(extra)].join(", ")}`);
}

// 脚本里的元数据也要能用：每个编码都得有 label 和 desc
const listed = execFileSync("bash", [SCRIPT, "--list"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
for (const id of scriptCodes) {
  if (!new RegExp(`^\\s{2}${id}\\s`, "m").test(listed)) fail(`--list 文本输出里缺少编码 ${id}`);
}

if (process.exitCode) {
  console.error(`\n[disk-cleanup-codes] 脚本编码：${scriptCodes.join(", ")}`);
  console.error("提示：单一事实源是 mac_cleanup.sh 的 KNOWN_IDS 与 item_label/item_desc；改编码时三处文档要同步。");
} else {
  console.log(`[disk-cleanup-codes] ok：${scriptCodes.length} 个编码（${scriptCodes.join(", ")}）在四处一致`);
}
