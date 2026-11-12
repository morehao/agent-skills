#!/usr/bin/env node
// 校验 disk-cleanup 的清理项编码在「脚本 / SKILL.md / references/*.md / skill-internals.md」四处是否一致，
// 并做四类结构性检查（1 类原有 + 3 类新增，背景见 docs/agents/verification.md「disk-cleanup 文档一致性校验」）：
//
//   1) 编码集合：四处编码集合必须一致；`--list` 文本输出里每项都要出现（原有检查）。
//   2) 阈值一致性：references/ 下编码行必须出现该编码的预期阈值 token（天 / 体积）。
//   3) 参数一致性：`mac_cleanup.sh --help` 里的每个 `--xxx` 都要在 references/*.md 或 SKILL.md 出现。
//   4) 白名单一致性：脚本 SAFE_CACHE_DIRS / ORPHAN_ROOTS 的每条路径（`$HOME` 归一为 `~`）都要在 references/*.md 出现。
//
// references 已按「清理对象」拆成多篇（cleanup.md 入口 + tools/*.md + 系统级/项目层/残留各篇）。
// 编码索引表仍只在入口 cleanup.md（parseRefsTable 只解析它）；阈值/参数/白名单则跨 references 全目录联合校验。
//
// 单一事实源是 `mac_cleanup.sh --list --json`（脚本里的 KNOWN_IDS + 元数据），
// 其余三处文档必须与之对齐：漏写 → 用户看不到这项；多写 → 报了个脚本不认的编码（--only 会 exit 1）。
//
// 文档侧允许两种简写（现状写法，不必为了门禁改排版）：
//   - 花括号列表：`~/Library/{Caches,Logs}` → ~/Library/Caches、~/Library/Logs；
//   - 同行裸名列表：`~/.npm/_npx  _cacache  _logs` → 以该行首个路径的父目录为前缀补齐为 ~/.npm/_cacache。
//
// 退出码：0 一致 / 1 不一致 / 2 用法或环境错误。

import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SCRIPT = join(repoRoot, "skills/disk-cleanup/scripts/mac_cleanup.sh");
const SKILL = join(repoRoot, "skills/disk-cleanup/SKILL.md");
const REFS_DIR = join(repoRoot, "skills/disk-cleanup/references");
// 编码索引表仍只认入口文件；阈值/参数/白名单则跨 references 全目录联合校验。
const REFS_ENTRY = join(REFS_DIR, "cleanup.md");
const INTERNALS = join(repoRoot, "docs/agents/skill-internals.md");

const problems = [];

function fail(msg) {
  problems.push(msg);
}

// 环境 / 用法错误：立即 exit 2（不当作「文档漂移」）
function die(msg) {
  console.error(`[disk-cleanup-codes] ${msg}`);
  process.exit(2);
}

// 递归列出 references 目录下所有 .md（含 tools/ 子目录）
function listRefFiles(dir = REFS_DIR) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) out.push(...listRefFiles(p));
    else if (name.endsWith(".md")) out.push(p);
  }
  return out.sort();
}

// 把所有 references/*.md 拼成一份联合文本，供阈值/参数/白名单跨篇校验
function readAllRefs() {
  const files = listRefFiles();
  return files.map((f) => readFileSync(f, "utf8")).join("\n\n");
}

function runScript(args) {
  const r = spawnSync("bash", [SCRIPT, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  if (r.error) die(`无法执行 ${SCRIPT} ${args.join(" ")}：${r.error.message}`);
  if (r.status !== 0) {
    die(`执行 ${SCRIPT} ${args.join(" ")} 失败（exit ${r.status}）：${(r.stderr || "").trim()}`);
  }
  return r.stdout;
}

function readCodes() {
  const out = runScript(["--list", "--json"]);
  let data;
  try {
    data = JSON.parse(out);
  } catch (err) {
    die(`--list --json 输出不是合法 JSON：${err.message}`);
  }
  if (!Array.isArray(data.codes) || data.codes.length === 0) {
    die("--list --json 里没有 codes 数组");
  }
  return data.codes.map((c) => c.id);
}

// 抽取一段文本里所有 `xxx` 形式的标识符
function backticks(text) {
  return [...text.matchAll(/`([a-z][a-z0-9_-]*)`/g)].map((m) => m[1]);
}

// references/cleanup.md（入口编码索引表）：每行以 "| `code` |" 开头；返回 { id, row }，row 是整行原文
function parseRefsTable(text) {
  const lines = text.split("\n");
  const start = lines.findIndex((l) => l.startsWith("### 清理项编码"));
  if (start === -1) {
    die("references/cleanup.md 里找不到「### 清理项编码」小节（编码索引表须留在入口）");
  }
  const rows = [];
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith("#")) break;
    const m = line.match(/^\|\s*`([a-z][a-z0-9_-]*)`\s*\|/);
    if (m) rows.push({ id: m[1], row: line });
  }
  if (rows.length === 0) {
    die("references/cleanup.md 的编码索引表里没解析到任何编码");
  }
  return rows;
}

// SKILL.md：只取勾选表（表头含「传给 `--only` 的编码」那张表）里的编码
function codesFromSkill(text) {
  const lines = text.split("\n");
  const head = lines.findIndex((l) => l.includes("传给 `--only` 的编码"));
  if (head === -1) {
    die("SKILL.md 里找不到勾选表（表头含「传给 `--only` 的编码」）");
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
    die("SKILL.md 勾选表里没解析到任何编码");
  }
  return [...codes];
}

// skill-internals.md：取「清理项编码（…）」括号里那串
function codesFromInternals(text) {
  const m = text.match(/清理项编码（([^）]*)）/);
  if (!m) {
    die("skill-internals.md 里找不到「清理项编码（…）」清单");
  }
  return backticks(m[1]).filter((c) => c !== "all" && c !== "list");
}

// ---------- 阈值一致性 ----------
// 每条 = 一个编码行里必须出现的阈值 token（多组则都要命中；组内多个正则命中任一即可）。
// 用「包含」判断，但把数字本身钉死，避免写成「几天」这类无信息量描述。
const THRESHOLDS = [
  {
    id: "caches",
    label: "缓存年龄阈值 1 天",
    res: [/(?:^|\D)1\s*天/, /mtime\s*\+\s*1/],
  },
  { id: "logs", label: "日志年龄阈值 7 天", res: [/(?:^|\D)7\s*天/] },
  { id: "varfolders", label: "varfolders 年龄阈值 7 天", res: [/(?:^|\D)7\s*天/] },
  {
    id: "projects",
    label: "projects 年龄阈值 30 天",
    res: [/(?:^|\D)30\s*天/, /默认\s*30(?![0-9])/],
  },
  { id: "projects", label: "projects 最小体积 50 MB", res: [/(?:^|\D)50\s*MB/i] },
  { id: "appcache", label: "appcache 最小体积 10 MB", res: [/(?:^|\D)10\s*MB/i] },
  {
    id: "projectcache",
    label: "projectcache 年龄阈值 3 天",
    res: [/(?:^|\D)3\s*天/, /默认\s*3(?![0-9])/],
  },
  {
    id: "dshtmp",
    label: "dshtmp 年龄阈值 0 天",
    res: [/(?:^|\D)0\s*天/, /默认\s*0(?![0-9])/],
  },
];

// 编码行规范化：去 markdown 记号与括号，方便「默认 30)天」这类写法也能命中数字
function normalizeRow(row) {
  return row.replace(/[`*]/g, "").replace(/[（）()]/g, "").replace(/\s+/g, " ").trim();
}

function checkThresholds() {
  // 阈值 token 可分布在 references 任一分篇（入口索引表只放一句话，详细阈值行在 tools/* / macos-system / project-artifacts）。
  // 因此扫全目录所有「| `code` | … |」行，把一个编码在所有文件里的行拼起来一起判断。
  const rowsById = new Map();
  for (const file of listRefFiles()) {
    const text = readFileSync(file, "utf8");
    for (const line of text.split("\n")) {
      const m = line.match(/^\|\s*`([a-z][a-z0-9_-]*)`\s*\|/);
      if (!m) continue;
      const id = m[1];
      const prev = rowsById.get(id) ?? "";
      rowsById.set(id, `${prev} ${normalizeRow(line)}`.trim());
    }
  }
  for (const { id, label, res } of THRESHOLDS) {
    const row = rowsById.get(id);
    if (row === undefined) continue; // 缺行由编码集合检查报，避免重复
    if (!res.some((re) => re.test(row))) {
      fail(`references/*.md 的 \`${id}\` 行缺少阈值 token：${label}`);
    }
  }
}

// ---------- 参数一致性 ----------
function checkParams(refsText, skillText) {
  const help = runScript(["--help"]);
  const params = [...new Set([...help.matchAll(/--[a-z][a-z0-9-]*/g)].map((m) => m[0]))].sort();
  if (params.length === 0) die("mac_cleanup.sh --help 输出里没解析到任何 --xxx 参数");
  const docs = `${refsText}\n${skillText}`;
  // 右侧加边界，避免文档里的 `--all` 把 `--allx` 这类未登记参数「顶掉」
  const missing = params.filter((p) => !new RegExp(`${p}(?![a-z0-9-])`).test(docs));
  if (missing.length) {
    fail(`mac_cleanup.sh --help 的参数在 cleanup.md / SKILL.md 里都没提到：${missing.join(", ")}`);
  }
  return params.length;
}

// ---------- 白名单一致性 ----------
// 解析脚本里的数组字面量：认 `NAME=(` 与 `NAME+=(`（含多行与单行写法），按括号/引号配对取出字符串
function scriptArray(name) {
  const text = readFileSync(SCRIPT, "utf8");
  const re = new RegExp(`\\b${name}\\s*\\+?=\\s*\\(`, "g");
  const vals = [];
  for (const m of text.matchAll(re)) {
    let depth = 1;
    let quote = null;
    let block = "";
    for (let i = m.index + m[0].length; i < text.length; i++) {
      const ch = text[i];
      if (quote) {
        if (ch === "\n") quote = null;
        else if (ch === quote && text[i - 1] !== "\\") quote = null;
        block += ch;
        continue;
      }
      if (ch === '"' || ch === "'") {
        quote = ch;
        block += ch;
        continue;
      }
      if (ch === "(") depth += 1;
      if (ch === ")") {
        depth -= 1;
        if (depth === 0) break;
      }
      block += ch;
    }
    for (const q of block.matchAll(/"([^"]+)"/g)) vals.push(q[1]);
  }
  const paths = [...new Set(vals.filter((v) => v.startsWith("$HOME/") || v.startsWith("/")))];
  if (paths.length === 0) die(`mac_cleanup.sh 里找不到 ${name}=() 数组，或数组里没解析到路径`);
  return paths;
}

const tilde = (p) => p.replace(/^\$HOME/, "~").replace(/\/+$/, "");

// 把 cleanup.md 文本展开成「文档里出现过的路径集合」，认两种简写（见文件头）
function docPathSet(text) {
  const set = new Set();
  const add = (p) => {
    const n = tilde(p);
    if (n.length > 1) set.add(n);
  };

  // 1) 花括号简写：~/Library/{Caches,Logs}
  for (const m of text.matchAll(/(?:~|\$HOME)?\/[^\s{,`]*\{([^{}`\n]+)\}/g)) {
    const prefix = m[0].slice(0, m[0].indexOf("{"));
    for (const part of m[1].split(",")) add(prefix + part.trim());
  }

  // 2) 普通路径 token（允许路径名里带一个空格，如 ~/Library/Application Support）；
  //    同一行的裸名（如 `~/.npm/_npx  _cacache`）按该行首个路径的父目录补齐
  const pathRe = /(?:~|\$HOME)?\/[A-Za-z0-9_.@/-]+(?: [A-Za-z0-9_.@-]+)*/g;
  const bareRe = /(?:^|[\s|、,，；;（(`])([A-Za-z0-9_][A-Za-z0-9_.@-]*)(?=[\s|、,，；;）)`]|$)/g;
  for (const line of text.split("\n")) {
    const toks = [...line.matchAll(pathRe)].map((m) => m[0]);
    for (const t of toks) add(t);
    if (toks.length === 0) continue;
    const first = tilde(toks[0]);
    const parent = first.replace(/\/[^/]*$/, "");
    for (const m of line.matchAll(bareRe)) {
      const tok = m[1];
      if (tok.length < 2) continue;
      add(`${parent}/${tok}`);
      add(`${first}/${tok}`);
    }
  }
  return set;
}

function checkWhitelists(refsText) {
  const docs = docPathSet(refsText);
  let total = 0;
  for (const name of ["SAFE_CACHE_DIRS", "ORPHAN_ROOTS"]) {
    const paths = scriptArray(name).map(tilde);
    total += paths.length;
    const missing = paths.filter((p) => !docs.has(p));
    if (missing.length) {
      fail(`references/*.md 缺少 ${name} 里的路径：${missing.join(", ")}`);
    }
  }
  return total;
}

// ---------- 执行检查 ----------
const refsEntryText = readFileSync(REFS_ENTRY, "utf8"); // 编码索引表（只认入口）
const allRefsText = readAllRefs(); // 阈值/参数/白名单跨 references 全目录联合
const skillText = readFileSync(SKILL, "utf8");
const internalsText = readFileSync(INTERNALS, "utf8");

const scriptCodes = readCodes();
const refsCodes = parseRefsTable(refsEntryText).map((r) => r.id);
const skillCodes = codesFromSkill(skillText);
const internalsCodes = codesFromInternals(internalsText);

const want = new Set(scriptCodes);
const sources = [
  ["references/cleanup.md 编码索引表", refsCodes],
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
const listed = runScript(["--list"]);
for (const id of scriptCodes) {
  if (!new RegExp(`^\\s{2}${id}\\s`, "m").test(listed)) fail(`--list 文本输出里缺少编码 ${id}`);
}

checkThresholds();
const paramCount = checkParams(allRefsText, skillText);
const whitelistCount = checkWhitelists(allRefsText);

if (problems.length) {
  for (const p of problems) console.error(`[disk-cleanup-codes] ${p}`);
  console.error(`\n[disk-cleanup-codes] 脚本编码：${scriptCodes.join(", ")}`);
  console.error(
    "提示：单一事实源是 mac_cleanup.sh 的 KNOWN_IDS 与 item_label/item_desc；" +
      "改编码、阈值、参数或白名单时，references/*.md / SKILL.md 要同步。",
  );
  process.exitCode = 1;
} else {
  console.log(
    `[disk-cleanup-codes] ok：${scriptCodes.length} 个编码在四处一致；` +
      `阈值 ${THRESHOLDS.length} 项、参数 ${paramCount} 个、白名单 ${whitelistCount} 条路径均已覆盖`,
  );
}
