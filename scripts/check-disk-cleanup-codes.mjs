#!/usr/bin/env node
// 校验 disk-cleanup v2 的编码契约（单一事实源 = skills/disk-cleanup/scripts/data/codes.tsv）。
//
// 五类结构性一致（不是逐字比对文案）：
//   ① 运行时：`--list --json` 的 id / 顺序 / label / desc / sudo 必须与 TSV 逐项相同。
//   ② 索引表：`references/cleanup.md` 的「### 清理项编码」表必须与 TSV 一一对应，
//             **数量也要比**（v1 只比集合，导致文档写「16 个」而实际 22 个也没红）。
//   ③ 参数   ：`SKILL.md` 里出现的每个 `--flag` 都必须在 `mac_cleanup.sh` 的 usage()
//             （或 `cleanup-opencode.sh` 的 usage()）里真的存在 —— 反向检查，防 agent 照着文档敲出不存在的参数。
//   ④ sudo   ：TSV 的 sudo 列要与 `--list` 文本的 `[需 sudo]`、以及 `references/cleanup.md`
//             索引表的 sudo 标注一致（三处都得说同一件事）。
//   ⑤ 编码引用：references/**/*.md 里 `--only` 示例只允许出现 TSV 声明过的编码。
//
// 所有失败信息都指名「哪个文件哪一行、期望什么」。
// 退出码：0 一致 / 1 有漂移 / 2 用法或环境错误（文件读不到、脚本跑不起来、JSON 解析失败）。
//
// 用法：node scripts/check-disk-cleanup-codes.mjs

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const rel = (p) => relative(repoRoot, p);

const TSV = join(repoRoot, "skills/disk-cleanup/scripts/data/codes.tsv");
const SCRIPT = join(repoRoot, "skills/disk-cleanup/scripts/mac_cleanup.sh");
const OPCODE_SCRIPT = join(repoRoot, "skills/disk-cleanup/scripts/cleanup-opencode.sh");
const SKILL = join(repoRoot, "skills/disk-cleanup/SKILL.md");
const REFS_DIR = join(repoRoot, "skills/disk-cleanup/references");
const REFS_ENTRY = join(REFS_DIR, "cleanup.md");

const problems = [];
const fail = (msg) => problems.push(msg);

// 环境/用法错误：立即 exit 2，不当作「文档漂移」
function die(msg) {
  console.error(`[disk-cleanup-codes] ${msg}`);
  process.exit(2);
}

// 沙箱 HOME：跑脚本时不让它读/写真实 HOME（--list 本来就只读，但别留口子）
let tmpHome = null;
function sandboxHome() {
  if (!tmpHome) tmpHome = mkdtempSync(join(tmpdir(), "dc-codes-"));
  return tmpHome;
}
process.on("exit", () => {
  if (!tmpHome) return;
  try {
    rmSync(tmpHome, { recursive: true, force: true });
  } catch {
    /* 清理失败不影响退出码 */
  }
});

function runScript(file, args) {
  const home = sandboxHome();
  const r = spawnSync("bash", [file, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, HOME: home, DC_AUDIT_LOG: join(home, "audit.log") },
  });
  if (r.error) die(`无法执行 ${rel(file)} ${args.join(" ")}：${r.error.message}`);
  if (r.status !== 0) {
    die(`执行 ${rel(file)} ${args.join(" ")} 失败（exit ${r.status}）：${(r.stderr || "").trim()}`);
  }
  return r.stdout;
}

function readText(file, what) {
  try {
    return readFileSync(file, "utf8");
  } catch (err) {
    die(`读不到${what} ${rel(file)}：${err.message}`);
  }
}

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

// ---------- 单一事实源：data/codes.tsv ----------
// 格式：id<TAB>label<TAB>desc<TAB>sudo（0|1），`#` 注释与空行忽略
function readCodesTsv() {
  const text = readText(TSV, "编码表");
  const rows = [];
  const seen = new Map();
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const ln = i + 1;
    const line = lines[i];
    if (line.trim() === "" || line.trimStart().startsWith("#")) continue;
    const cols = line.split("\t");
    if (cols.length !== 4) {
      fail(
        `${rel(TSV)}:${ln}  期望 4 列（id<TAB>label<TAB>desc<TAB>sudo），实际 ${cols.length} 列：` +
          `${JSON.stringify(line.slice(0, 80))}`,
      );
      continue;
    }
    const [rawId, label, desc, rawSudo] = cols;
    const id = rawId.trim();
    const sudo = rawSudo.trim();
    if (!/^[a-z][a-z0-9-]*$/.test(id)) {
      fail(`${rel(TSV)}:${ln}  id 期望小写字母开头的 [a-z0-9-] 串，实际 ${JSON.stringify(rawId)}`);
      continue;
    }
    if (sudo !== "0" && sudo !== "1") {
      fail(`${rel(TSV)}:${ln}  第 4 列 sudo 期望 0 或 1，实际 ${JSON.stringify(rawSudo)}`);
      continue;
    }
    if (label.trim() === "" || desc.trim() === "") {
      fail(`${rel(TSV)}:${ln}  \`${id}\` 的 label / desc 不能为空（--list 与文档都靠它）`);
      continue;
    }
    if (seen.has(id)) {
      fail(`${rel(TSV)}:${ln}  重复编码 \`${id}\`（首次出现在第 ${seen.get(id)} 行）`);
      continue;
    }
    seen.set(id, ln);
    rows.push({ id, label: label.trim(), desc: desc.trim(), sudo: sudo === "1", line: ln });
  }
  if (rows.length === 0) {
    for (const p of problems) console.error(`[disk-cleanup-codes] ${p}`);
    console.error(`[disk-cleanup-codes] ${rel(TSV)} 里没有解析到任何合法编码（数据漂移，不是环境错误）`);
    process.exit(1);
  }
  return rows;
}

// ---------- ① --list --json 与 TSV 逐项一致 ----------
function checkListJson(rows) {
  const out = runScript(SCRIPT, ["--list", "--json"]);
  let data;
  try {
    data = JSON.parse(out);
  } catch (err) {
    die(`--list --json 输出不是合法 JSON：${err.message}`);
  }
  if (data.schema !== 2) {
    fail(`${rel(SCRIPT)} 的 --list --json 输出 schema 期望 2，实际 ${JSON.stringify(data.schema)}`);
  }
  const codes = Array.isArray(data.codes) ? data.codes : null;
  if (!codes) die(`--list --json 里没有 codes 数组`);

  if (codes.length !== rows.length) {
    fail(
      `${rel(TSV)} 有 ${rows.length} 个编码，但 \`--list --json\` 输出 ${codes.length} 个（数量必须一致）`,
    );
  }
  const n = Math.min(codes.length, rows.length);
  for (let i = 0; i < n; i++) {
    const want = rows[i];
    const got = codes[i];
    const where = `${rel(TSV)}:${want.line} 与 --list --json 第 ${i + 1} 项`;
    if (got.id !== want.id) {
      fail(`${where} 的 id 不一致：期望 \`${want.id}\`，实际 \`${got.id}\`（顺序必须与 TSV 一致）`);
      continue;
    }
    if (got.label !== want.label) {
      fail(`${where}（\`${want.id}\`）的 label 不一致：期望 ${JSON.stringify(want.label)}，实际 ${JSON.stringify(got.label)}`);
    }
    if (got.desc !== want.desc) {
      fail(`${where}（\`${want.id}\`）的 desc 不一致：期望 ${JSON.stringify(want.desc)}，实际 ${JSON.stringify(got.desc)}`);
    }
    if (Boolean(got.sudo) !== want.sudo) {
      fail(`${where}（\`${want.id}\`）的 sudo 不一致：期望 ${want.sudo}，实际 ${Boolean(got.sudo)}`);
    }
  }
  if (codes.length > rows.length) {
    fail(
      `--list --json 多出 TSV 未声明的编码：${codes.slice(rows.length).map((c) => `\`${c.id}\``).join("、")}`,
    );
  }
}

// ---------- ② references/cleanup.md 编码索引表 ----------
function parseRefsTable(text) {
  const lines = text.split("\n");
  const start = lines.findIndex((l) => /^#{2,6}\s*清理项编码/.test(l));
  if (start === -1) return null;
  const rows = [];
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i];
    if (/^#{1,6}\s/.test(line)) break;
    const m = line.match(/^\|\s*`([a-z][a-z0-9_-]*)`\s*\|/);
    if (m) rows.push({ id: m[1], line: i + 1, text: line });
  }
  return rows;
}

function checkRefsTable(rows) {
  const table = parseRefsTable(readText(REFS_ENTRY, "编码索引表"));
  if (table === null) {
    fail(
      `${rel(REFS_ENTRY)}  找不到「### 清理项编码」小节` +
        `（编码索引表必须留在入口，表格行以 \`| \\\`id\\\` |\` 开头）`,
    );
    return new Map();
  }
  const byId = new Map();
  for (const r of table) {
    if (byId.has(r.id)) {
      fail(`${rel(REFS_ENTRY)}:${r.line}  编码表里 \`${r.id}\` 重复（首次在第 ${byId.get(r.id).line} 行）`);
      continue;
    }
    byId.set(r.id, r);
  }
  if (table.length !== rows.length) {
    fail(
      `${rel(REFS_ENTRY)}:${table.length > 0 ? table[0].line : 1}  编码表有 ${table.length} 行，` +
        `${rel(TSV)} 有 ${rows.length} 个编码（数量必须相等）`,
    );
  }
  for (const row of rows) {
    if (!byId.has(row.id)) {
      fail(
        `${rel(REFS_ENTRY)}  编码表缺少 \`${row.id}\`（${rel(TSV)}:${row.line} 声明了它；漏写用户就看不到这项）`,
      );
    }
  }
  const declared = new Set(rows.map((r) => r.id));
  for (const r of table) {
    if (!declared.has(r.id)) {
      fail(
        `${rel(REFS_ENTRY)}:${r.line}  出现 ${rel(TSV)} 未声明的编码 \`${r.id}\`` +
          `（\`--only ${r.id}\` 会被脚本拒绝）`,
      );
    }
  }
  return byId;
}

// ---------- ③ SKILL.md 的 --flag 必须在 usage() 里存在 ----------
// usage() 的正文：从 `usage() {` 到下一个顶格 `}`
function usageFlags(file) {
  const flags = new Set();
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    return flags;
  }
  const lines = text.split("\n");
  const start = lines.findIndex((l) => /^\s*usage\s*\(\s*\)\s*\{/.test(l));
  if (start === -1) return flags;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^\}/.test(lines[i])) break;
    for (const m of lines[i].matchAll(/--[a-z][a-z0-9-]*/g)) flags.add(m[0]);
  }
  return flags;
}

function checkSkillFlags() {
  const allowed = new Set([...usageFlags(SCRIPT), ...usageFlags(OPCODE_SCRIPT)]);
  if (allowed.size === 0) die(`${rel(SCRIPT)} 的 usage() 里没解析到任何参数`);
  const text = readText(SKILL, "技能说明");
  const lines = text.split("\n");
  const used = new Map(); // flag -> [line...]
  for (let i = 0; i < lines.length; i++) {
    for (const m of lines[i].matchAll(/--[a-z][a-z0-9-]*/g)) {
      const flag = m[0];
      if (!used.has(flag)) used.set(flag, []);
      used.get(flag).push(i + 1);
    }
  }
  if (used.size === 0) {
    fail(`${rel(SKILL)}  里没解析到任何 \`--flag\`（技能说明至少要给出参数入口）`);
  }
  for (const [flag, at] of [...used].sort()) {
    if (allowed.has(flag)) continue;
    fail(
      `${rel(SKILL)}:${at[0]}  出现 \`${flag}\`，但 ${rel(SCRIPT)} 的 usage() 与 ` +
        `${rel(OPCODE_SCRIPT)} 的 usage() 都没有这个参数` +
        `（agent 会照着敲，脚本直接 exit 2；共 ${at.length} 处：第 ${at.join("、")} 行）`,
    );
  }
}

// ---------- ④ sudo 列：TSV ↔ --list 文本 ↔ cleanup.md 索引表 ----------
function checkSudoColumn(rows, tableById) {
  const listed = runScript(SCRIPT, ["--list"]);
  for (const row of rows) {
    // 取整行（`  <id>  <label>  [需 sudo]`），别只取匹配到的前缀
    const lineRe = new RegExp(`^\\s{2,}${row.id}\\s.*$`, "m");
    const line = listed.match(lineRe);
    if (!line) {
      fail(`${rel(SCRIPT)} 的 \`--list\` 文本里找不到编码 \`${row.id}\`（${rel(TSV)}:${row.line}）`);
      continue;
    }
    const marked = line[0].includes("[需 sudo]");
    if (row.sudo && !marked) {
      fail(
        `${rel(SCRIPT)} 的 \`--list\` 文本里 \`${row.id}\` 行缺少 \`[需 sudo]\`` +
          `（${rel(TSV)}:${row.line} 的 sudo 列是 1）`,
      );
    }
    if (!row.sudo && marked) {
      fail(
        `${rel(SCRIPT)} 的 \`--list\` 文本里 \`${row.id}\` 行标了 \`[需 sudo]\`` +
          `（${rel(TSV)}:${row.line} 的 sudo 列是 0）`,
      );
    }

    // 索引表：sudo=1 必须写明 sudo；sudo=0 不能声称需要 sudo
    const tr = tableById.get(row.id);
    if (!tr) continue; // 缺行已由 ② 报过
    const claimsSudo = /（sudo）|\(sudo\)|需要\s*sudo|需\s*sudo/i.test(tr.text);
    if (row.sudo && !claimsSudo) {
      fail(
        `${rel(REFS_ENTRY)}:${tr.line}  编码表里 \`${row.id}\` 没写 sudo，` +
          `但 ${rel(TSV)}:${row.line} 的 sudo 列是 1`,
      );
    }
    if (!row.sudo && claimsSudo) {
      fail(
        `${rel(REFS_ENTRY)}:${tr.line}  编码表里 \`${row.id}\` 标了 sudo，` +
          `但 ${rel(TSV)}:${row.line} 的 sudo 列是 0`,
      );
    }
  }
}

// ---------- ⑤ references 里 --only 示例只能引用已声明编码 ----------
// 认三种写法：--only a,b / --only=a / `--only a,b`；占位符（<ids>、<编码>、N）跳过。
const ONLY_RE = /--only(?:\s*=\s*|\s+)(`[^`]*`|[^\s`|，。；、）)]+)/g;
const PLACEHOLDER_RE = /^(ids?|id|codes?|code|n|编码|编码列表|勾选项|列表|路径)$/i;

function checkOnlyExamples(ids) {
  let checked = 0;
  for (const file of listRefFiles()) {
    const lines = readText(file, "文档").split("\n");
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (!line.includes("--only")) continue;
      ONLY_RE.lastIndex = 0;
      let m;
      while ((m = ONLY_RE.exec(line)) !== null) {
        const token = m[1].replace(/^`|`$/g, "").replace(/[，,。；;、]$/g, "").trim();
        if (!token) continue;
        if (/^[<（(]/.test(token)) continue; // <ids> / （编码）
        if (PLACEHOLDER_RE.test(token)) continue;
        if (/编码|列表|勾选/.test(token)) continue; // 中文占位符
        const parts = token.split(/[,，]/).map((p) => p.trim()).filter(Boolean);
        // --only a,b,c / --only x,y：文档里表示「任意若干编码」的记号，不是真实编码
        if (parts.length > 1 && parts.every((p) => /^[a-z]$/.test(p))) continue;
        for (const raw of parts) {
          const part = raw.trim().replace(/^[`'"]+|[`'"]+$/g, "");
          if (!part) continue;
          if (!/^[a-z][a-z0-9_-]*$/.test(part)) continue; // 中文说明/其它写法
          checked += 1;
          if (ids.has(part)) continue;
          fail(
            `${rel(file)}:${i + 1}  \`--only\` 示例里出现 ${rel(TSV)} 未声明的编码 \`${part}\`` +
              `（脚本会对 \`--only ${part}\` 直接报错）`,
          );
        }
      }
    }
  }
  return checked;
}

// ---------- 执行检查 ----------
const tsvRows = readCodesTsv();
checkListJson(tsvRows);
const tableById = checkRefsTable(tsvRows);
checkSkillFlags();
checkSudoColumn(tsvRows, tableById);
const onlyCount = checkOnlyExamples(new Set(tsvRows.map((r) => r.id)));

if (problems.length > 0) {
  for (const p of problems) console.error(`[disk-cleanup-codes] ${p}`);
  console.error(
    `\n[disk-cleanup-codes] 共 ${problems.length} 处漂移（单一事实源：${rel(TSV)}，` +
      `${tsvRows.length} 个编码：${tsvRows.map((r) => r.id).join(", ")}）`,
  );
  console.error(
    "提示：改编码/描述/sudo 时只改 data/codes.tsv，再同步 references/cleanup.md 的索引表；" +
      "SKILL.md 只写 usage() 里真实存在的参数。",
  );
  process.exitCode = 1;
} else {
  console.log(
    `[disk-cleanup-codes] ok：${tsvRows.length} 个编码在 data/codes.tsv、--list --json、` +
      `references/cleanup.md 三处一致；SKILL.md 的 --flag 全部在 usage()；` +
      `sudo 标注一致（${tsvRows.filter((r) => r.sudo).length} 个需 sudo）；` +
      `references 的 --only 示例 ${onlyCount} 处均为已声明编码`,
  );
}
