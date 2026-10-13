#!/usr/bin/env node
// check-docs.mjs —— project-wiki 的文档质量门禁（自研，零依赖：只用 node 内置模块）。
//
// 用法：
//   node check-docs.mjs <输出目录|a.md b.md ...> [--source-repo <源码根>] [--expect-baseline <ref>]
//                       [--kb-repo <知识库根>] [--allow-in-repo] [--strict] [--quiet]
//
// 严重度三档（语义已冻结，见 references/grounding-light.md「严重度与归级判据」）：
//   error  程序可确定判定，且违反会让读者读到错的产物            → 退出码 1
//   warn   程序可判定，但属质量偏好                              → 默认 0；--strict 下 1
//   note   作者侧流程与口径合规，或程序判不了、只有人能判的事      → **任何模式下都是 0**
//   note 默认打印（不静默）；note 升 error 必须过判据并在 grounding-light 写明理由。
//
// 它检查的是本 skill 相对 project-insight 的那几条核心差异，全部可程序化：
//
//   代码密度（本 skill 存在的理由）
//     [DOC-CODE-HEAVY]  单页非图表代码块 > 3 块，或合计 > 40 行
//     [DOC-CODE-LONG]   单个代码块 > 15 行
//     · 页内写一行 `<!-- code-budget: <理由> -->` 即豁免该页（有意识的选择 vs 忘了删）
//
//   轻量真源（作者侧校验，正文不留痕迹）
//     [DOC-SRC-MISSING]    依据行/行内引用的路径不存在
//     [DOC-SRC-ORANGE]     行号越出文件行数
//     [DOC-SRC-RANGE]      区间首末无序（如 100-20）
//     [DOC-SRC-TRAVERSAL]  路径越出源码根
//     [DOC-SRC-UNCHECKED]  有引用但未传 --source-repo，无法校验（不静默放过）
//     [DOC-INLINE-REFS]    行内引用 > 5 处，提示收进章末依据行
//     [DOC-TRACE]          正文出现校验痕迹（<!-- anchor --> / <!-- snippet --> / Sources:）
//
//   结构
//     [DOC-FRONTMATTER]    缺 title / description
//     [DOC-HEADING-NUM]    标题带数字前缀（## 1. / ## 第N部分 / ## 一、）
//     [DOC-INDEX-MISSING]  有页面但首页无「索引」章节
//     [DOC-INDEX-UNLISTED] 页面未在首页列出
//     [DOC-INDEX-DANGLING] 首页链到不存在的文件
//     [DOC-NO-FIGURE]      整页无图（mermaid 或 .svg）
//     [DOC-FIGURE-COMPLEX] mermaid 图节点 ≥12，建议改 SVG
//     [DOC-FIGURE-PARTICIPANT] sequenceDiagram 用了未声明的参与者
//     [DOC-THIN]           页面正文过短（< 20 行有效行）
//     [DOC-FRONTMATTER-TYPE] 未写 type（同一知识库里的检索层靠它区分解读与 Wiki）——note
//
//   落点与版本契约（note 为主；唯一 error 是"产物落在源码仓内"）
//     [DOC-DOCROOT-IN-SRC]   产物目录落在 --source-repo 内（error；可用 --allow-in-repo 显式放行）
//     [DOC-BASELINE-MISSING] 首页没有「本文档依据」契约行
//     [DOC-BASELINE-FORMAT]  契约行存在但解析不出 ref/短SHA/日期
//     [DOC-BASELINE-UNRESOLVED] 契约声明的 ref/SHA/日期无法与 git 核对（含缺 git、非仓库）
//     [DOC-SRC-BASELINE-MISMATCH] --expect-baseline 与 --source-repo 的 HEAD 不一致（含未传）
//     [DOC-KB-UNLINKED]      KB 模式下没有任何索引链接到本 wiki 的首页
//
// 退出码：0 = 通过（仅有 warning / note）；1 = 存在 error（--strict 时 warning 也算失败，**note 永不参与**）；
//         2 = 用法/目标错误。
// 本脚本只读，不改动任何文档。git 只用于只读核对（rev-parse / log / for-each-ref），缺 git 时降级为 note。

import { readFileSync, existsSync, realpathSync, statSync, readdirSync } from 'node:fs';
import { resolve, join, sep } from 'node:path';
import { execFileSync } from 'node:child_process';
import {
  extractCitations, extractCodeBlocks, splitFrontmatter,
} from './lib/doc-parse.mjs';

// —— 预算（与 references/writing-style.md 的表保持一致）——
const MAX_BLOCKS_PER_PAGE = 3;
const MAX_LINES_PER_BLOCK = 15;
const MAX_CODE_LINES_PER_PAGE = 40;
const MAX_INLINE_REFS_PER_PAGE = 5;
const MIN_BODY_LINES = 15;
const COMPLEX_NODE_THRESHOLD = 12;

const C = {
  reset: '\u001b[0m', red: '\u001b[31m', yellow: '\u001b[33m', cyan: '\u001b[36m', dim: '\u001b[2m',
};

// ———————————————————————————— 参数 ————————————————————————————

const argv = process.argv.slice(2);
const targets = [];
let sourceRepo = null;
let expectBaseline = null;
let kbRepo = null;
let allowInRepo = false;
let strict = false;
let quiet = false;

const USAGE = '用法: node check-docs.mjs <输出目录|a.md b.md ...> [--source-repo <源码根>] [--expect-baseline <ref>] [--kb-repo <知识库根>] [--allow-in-repo] [--strict] [--quiet]';

for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === '--source-repo') { sourceRepo = argv[++i]; continue; }
  if (a === '--expect-baseline') { expectBaseline = argv[++i]; continue; }
  if (a === '--kb-repo') { kbRepo = argv[++i]; continue; }
  if (a === '--allow-in-repo') { allowInRepo = true; continue; }
  if (a === '--strict') { strict = true; continue; }
  if (a === '--quiet') { quiet = true; continue; }
  if (a === '-h' || a === '--help') {
    console.log(USAGE);
    process.exit(0);
  }
  targets.push(a);
}

if (!targets.length) {
  console.error(USAGE);
  process.exit(2);
}
if (expectBaseline !== null && (expectBaseline === undefined || expectBaseline.trim() === '')) {
  console.error('[用法错误] --expect-baseline 需要一个 ref（如 v1.2.3 或 main）');
  process.exit(2);
}

let repoReal = null;
if (sourceRepo) {
  const abs = resolve(sourceRepo);
  if (!existsSync(abs)) {
    console.error(`[用法错误] --source-repo 不存在：${abs}`);
    process.exit(2);
  }
  repoReal = realpathSync(abs);
}

let kbReal = null;
if (kbRepo) {
  const abs = resolve(kbRepo);
  if (!existsSync(abs)) {
    console.error(`[用法错误] --kb-repo 不存在：${abs}`);
    process.exit(2);
  }
  kbReal = realpathSync(abs);
}

// ———————————————————————————— 工具 ————————————————————————————

const errors = [];
const warns = [];
const notes = [];

function report(level, code, file, line, msg) {
  const entry = { level, code, file: disp(file), line, msg };
  if (level === 'error') errors.push(entry);
  else if (level === 'warn') warns.push(entry);
  else notes.push(entry);
}

function isWithinRoot(root, target) {
  if (target === root) return true;
  return target.startsWith(root + sep);
}

// —— 只读 git 辅助（缺 git / 非仓库 / 命令失败一律返回 null，由调用方降级为 note）——
function git(repo, args) {
  if (!repo) return null;
  try {
    return execFileSync('git', ['-C', repo, ...args], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 20000,
    }).trim();
  } catch {
    return null;
  }
}

function isGitRepo(repo) {
  return git(repo, ['rev-parse', '--git-dir']) !== null;
}

/** 契约行：`**本文档依据**：\`v1.2.3\`（\`abc1234\`，2026-08-14）`
 *  反引号可省（容错），但 ref / 短SHA / ISO 日期三者缺一即判 FORMAT——三个字段各有用途：
 *  ref 是下次 diff 的左端、SHA 是对得上哪次提交、日期是读者判断新鲜度的依据。 */
const CONTRACT_RE = /^\s*\*\*本文档依据\*\*\s*[:：]\s*`?([^`（）()\s]+)`?\s*[（(]\s*`?([0-9a-fA-F]{4,40})`?\s*[，,]\s*(\d{4}-\d{2}-\d{2})\s*[）)]/m;
// 只写了标题但没写全三元组的行（用于区分 MISSING 与 FORMAT）
const CONTRACT_HEAD_RE = /^\s*\*\*本文档依据\*\*/m;

let docRoot = null;
// 目标不存在必须让门禁失败：否则末尾的 exitCode 会把它覆盖成 0，等于静默放过
let targetMissing = false;

function collectMd(list) {
  const out = [];
  const walk = (dir) => {
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (e.name === 'node_modules' || e.name === '.git' || e.name.startsWith('.')) continue;
      const p = join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.toLowerCase().endsWith('.md')) out.push(p);
    }
  };
  for (const t of list) {
    const abs = resolve(t);
    if (!existsSync(abs)) {
      console.error(`[DOC-TARGET-MISSING] 目标不存在：${t}`);
      targetMissing = true;
      continue;
    }
    if (statSync(abs).isDirectory()) { if (!docRoot) docRoot = abs; walk(abs); }
    else { if (!docRoot) docRoot = resolve(abs, '..'); out.push(abs); }
  }
  return [...new Set(out)].sort();
}

/** 展示用短路径：相对文档根，避免刷屏的绝对路径 */
function disp(p) {
  if (docRoot && (p === docRoot || p.startsWith(docRoot + sep))) {
    const r = p.slice(docRoot.length + (p === docRoot ? 0 : 1));
    return r === '' ? '.' : r;
  }
  return p;
}

const files = collectMd(targets);

// ———————————————————————————— 解析 ————————————————————————————
// 引用/代码块/frontmatter 的解析实现是 scripts/lib/doc-parse.mjs（单一真源，
// 与 plan-update.mjs 共用）——这里不再自己写正则，避免两边判定漂移。

// 校验痕迹（正文不得出现）
const TRACE_RES = [
  /<!--\s*anchor(?:-base64)?\s*:/,
  /<!--\s*snippet(?:-base64)?\s*:/,
  /\bSources?\s*:\s*\[/,
];
const HEADING_NUM_RE = /^#{1,6}\s+(?:[0-9]+|[一二三四五六七八九十百千]+)\s*[.、)）:：]/;

/** flowchart/graph 节点数（节点定义 id[...]/(...)/{...} 与边端点取并集） */
function mermaidNodeCount(src) {
  const ids = new Set();
  const defRe = /(?:^|[\s;>|])([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[\[|\[\(|\(\(|\{\{|\[|\(|\{)/g;
  const edgeRe = /(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)\s*(?:-->|---|-.->|--x|--o|==>|~~~)\s*(?:\|[^|]*\|\s*)?([A-Za-z_][A-Za-z0-9_]*)?/g;
  let m;
  while ((m = defRe.exec(src)) !== null) ids.add(m[1]);
  while ((m = edgeRe.exec(src)) !== null) {
    ids.add(m[1]);
    if (m[2] && !/^(end|subgraph)$/i.test(m[2])) ids.add(m[2]);
  }
  // 剔除明显是关键字/标签位的 token
  for (const kw of ['graph', 'flowchart', 'subgraph', 'end', 'classDef', 'class', 'style', 'linkStyle', 'click']) ids.delete(kw);
  return ids.size;
}

/** sequenceDiagram 未声明的参与者 */
function mermaidUndeclaredParticipants(src) {
  const declared = new Set();
  const lines = src.split('\n');
  for (const l of lines) {
    const m = /^\s*(?:participant|actor)\s+([A-Za-z_][A-Za-z0-9_]*)/.exec(l);
    if (m) declared.add(m[1]);
  }
  const used = new Set();
  const arrowRe = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:-{1,2}>>?|--?\)|--?x|<<--?|->>|-->)\s*([A-Za-z_][A-Za-z0-9_]*)\s*:/;
  for (const l of lines) {
    const m = arrowRe.exec(l);
    if (m) { used.add(m[1]); used.add(m[2]); }
  }
  return [...used].filter((p) => !declared.has(p));
}

// ———————————————————————————— 逐文件检查 ————————————————————————————

const stats = [];

for (const file of files) {
  const text = readFileSync(file, 'utf8');
  const lines = text.split('\n');
  const { frontmatter, body, bodyLine } = splitFrontmatter(text);
  const bodyLines = body.split('\n');
  const rel = resolve(file);

  // —— 校验痕迹（铁律 1）——
  for (let i = 0; i < lines.length; i += 1) {
    for (const re of TRACE_RES) {
      if (re.test(lines[i])) {
        report('error', 'DOC-TRACE', rel, i + 1, '正文出现校验痕迹（锚点/片段指纹或 Sources: 前缀）——本 skill 的校验不进正文');
        break;
      }
    }
  }

  // —— frontmatter ——
  if (frontmatter === null) {
    report('error', 'DOC-FRONTMATTER', rel, 1, '缺 YAML frontmatter（需 title + description）');
  } else {
    if (!/^\s*title\s*:/m.test(frontmatter)) report('error', 'DOC-FRONTMATTER', rel, 1, 'frontmatter 缺 title');
    if (!/^\s*description\s*:/m.test(frontmatter)) report('error', 'DOC-FRONTMATTER', rel, 1, 'frontmatter 缺 description');
    // type 只服务检索（同一知识库里要与 project-insight 的 `type: 项目解读` 区分），不影响读者能否读懂 → note
    if (!/^\s*type\s*:/m.test(frontmatter)) {
      report('note', 'DOC-FRONTMATTER-TYPE', rel, 1, 'frontmatter 未写 type——知识库检索层靠它区分两类产物，建议 `type: 项目 Wiki`（不阻断）');
    }
  }

  // —— 代码预算 ——
  const blocks = extractCodeBlocks(lines);
  const diagramBlocks = blocks.filter((b) => b.lang === 'mermaid');
  const codeBlocks = blocks.filter((b) => b.lang !== 'mermaid');
  const exempted = /<!--\s*code-budget\s*:/.test(text);
  const totalCodeLines = codeBlocks.reduce((n, b) => n + b.lines.filter((l) => l.trim() !== '').length, 0);

  if (!exempted) {
    if (codeBlocks.length > MAX_BLOCKS_PER_PAGE) {
      report('error', 'DOC-CODE-HEAVY', rel, codeBlocks[0].startLine, `非图表代码块 ${codeBlocks.length} 个（上限 ${MAX_BLOCKS_PER_PAGE}）——删减，或写 <!-- code-budget: 理由 --> 豁免`);
    }
    for (const b of codeBlocks) {
      const n = b.lines.filter((l) => l.trim() !== '').length;
      if (n > MAX_LINES_PER_BLOCK) {
        report('error', 'DOC-CODE-LONG', rel, b.startLine, `代码块 ${n} 行（上限 ${MAX_LINES_PER_BLOCK}）——只留不可绕过的核心`);
      }
    }
    if (totalCodeLines > MAX_CODE_LINES_PER_PAGE) {
      report('error', 'DOC-CODE-HEAVY', rel, codeBlocks[0]?.startLine ?? 1, `非图表代码合计 ${totalCodeLines} 行（上限 ${MAX_CODE_LINES_PER_PAGE}）——删减，或用 <!-- code-budget: 理由 --> 豁免`);
    }
  } else if (!quiet) {
    console.log(`${C.dim}[code-budget 豁免] ${rel}${C.reset}`);
  }

  // —— 引用：依据行 + 行内（解析实现见 lib/doc-parse.mjs，与预检脚本共用）——
  const { citations, inlineCitations, unparsed } = extractCitations(lines);

  for (const u of unparsed) {
    report('warn', 'DOC-SRC-UNPARSED', rel, u.line, `疑似引用但无法解析：\`${u.text}\` —— 写成「相对路径:起止行」的形式，否则不会被校验`);
  }

  if (inlineCitations.length > MAX_INLINE_REFS_PER_PAGE) {
    report('error', 'DOC-INLINE-REFS', rel, inlineCitations[MAX_INLINE_REFS_PER_PAGE].line, `行内引用 ${inlineCitations.length} 处（上限 ${MAX_INLINE_REFS_PER_PAGE}）——出处请收进章末「依据」行`);
  }

  if (citations.length && !repoReal) {
    report('warn', 'DOC-SRC-UNCHECKED', rel, citations[0].line, `有 ${citations.length} 条引用但未传 --source-repo，路径与行号未被校验`);
  }

  for (const c of citations) {
    if (c.start > c.end) {
      report('error', 'DOC-SRC-RANGE', rel, c.line, `区间首末无序：${c.path}:${c.start}-${c.end}`);
      continue;
    }
    if (!repoReal) continue;
    const abs = resolve(repoReal, c.path);
    let real = null;
    try { real = realpathSync(abs); } catch { real = null; }
    if (real === null || !existsSync(abs)) {
      report('error', 'DOC-SRC-MISSING', rel, c.line, `引用路径不存在：${c.path}`);
      continue;
    }
    if (!isWithinRoot(repoReal, real)) {
      report('error', 'DOC-SRC-TRAVERSAL', rel, c.line, `引用越出源码根：${c.path}`);
      continue;
    }
    let src;
    try { src = readFileSync(real, 'utf8'); } catch {
      report('error', 'DOC-SRC-MISSING', rel, c.line, `引用文件不可读：${c.path}`);
      continue;
    }
    const lineCount = src.split('\n').length;
    if (c.end > lineCount) {
      report('error', 'DOC-SRC-ORANGE', rel, c.line, `行号越界：${c.path}:${c.start}-${c.end}（文件共 ${lineCount} 行）`);
    }
  }

  // —— 标题数字前缀 ——
  for (let i = 0; i < lines.length; i += 1) {
    if (HEADING_NUM_RE.test(lines[i])) {
      report('error', 'DOC-HEADING-NUM', rel, i + 1, `标题带数字前缀：${lines[i].trim().slice(0, 40)} —— 改用语义式标题`);
    }
  }

  // —— 图表 ——
  const isReadme = /(^|[\\/])readme\.md$/i.test(file);
  let hasSvg = false;
  for (const l of lines) {
    if (/\]\([^)]+\.svg\)/.test(l) || /<img[^>]+\.svg/.test(l)) hasSvg = true;
  }
  // 首页是入口页而非内容页：不要求配图，也不按"撑不起一页"判薄
  if (diagramBlocks.length === 0 && !hasSvg && !isReadme) {
    report('warn', 'DOC-NO-FIGURE', rel, 1, '整页无图——凡有形状的内容都该给图');
  }
  for (const b of diagramBlocks) {
    const src = b.lines.join('\n');
    const head = src.trimStart().slice(0, 30).toLowerCase();
    const isFlow = /^(graph|flowchart)\b/.test(head);
    if (isFlow) {
      const n = mermaidNodeCount(src);
      if (n >= COMPLEX_NODE_THRESHOLD) {
        report('warn', 'DOC-FIGURE-COMPLEX', rel, b.startLine, `mermaid 图约 ${n} 个节点（阈值 ${COMPLEX_NODE_THRESHOLD}）——建议改用 SVG（见 references/diagrams.md）`);
      }
    }
    if (/^sequencediagram\b/.test(head)) {
      const undeclared = mermaidUndeclaredParticipants(src);
      if (undeclared.length) {
        report('warn', 'DOC-FIGURE-PARTICIPANT', rel, b.startLine, `时序图有未声明的参与者：${undeclared.join('、')} —— 先 participant 声明再画消息`);
      }
    }
  }

  // —— 篇幅（只数散文：围栏块与 frontmatter 不计入）——
  const fenced = new Set();
  for (const b of blocks) for (let k = b.startLine; k <= b.endLine; k += 1) fenced.add(k);
  const bodyNonEmpty = bodyLines.filter((l, idx) => l.trim() !== '' && !fenced.has(bodyLine + idx)).length;
  if (bodyNonEmpty < MIN_BODY_LINES && !isReadme) {
    report('warn', 'DOC-THIN', rel, bodyLine, `正文仅 ${bodyNonEmpty} 行有效内容（下限 ${MIN_BODY_LINES}）——撑不起一页就并页`);
  }

  stats.push({ file: disp(rel), codeBlocks: codeBlocks.length, codeLines: totalCodeLines, citations: citations.length, basis: citations.filter((c) => c.basis).length, figures: diagramBlocks.length + (hasSvg ? 1 : 0), bodyNonEmpty });
}

// ———————————————————————————— 首页索引一致性 ————————————————————————————

const readme = files.find((f) => /(^|[\\/])readme\.md$/i.test(f));
if (readme) {
  const text = readFileSync(readme, 'utf8');
  const pages = files.filter((f) => f !== readme);
  const linkRe = /\[[^\]]*\]\(([^)\s]+\.md)\)/g;
  const linked = new Set();
  let m;
  while ((m = linkRe.exec(text)) !== null) linked.add(resolve(readme, '..', m[1]));

  const hasIndexSection = /^#{1,6}\s.*(索引|阅读顺序)/m.test(text);
  if (pages.length && !hasIndexSection) {
    report('error', 'DOC-INDEX-MISSING', readme, 1, `有 ${pages.length} 个页面但首页没有「页面索引」章节`);
  }
  for (const p of pages) {
    if (!linked.has(resolve(p))) {
      report('error', 'DOC-INDEX-UNLISTED', readme, 1, `页面未在首页列出：${p}`);
    }
  }
  for (const l of linked) {
    if (!existsSync(l)) {
      report('error', 'DOC-INDEX-DANGLING', readme, 1, `首页链接指向不存在的文件：${l}`);
    }
  }
} else if (files.length) {
  report('error', 'DOC-INDEX-MISSING', files[0], 1, '输出目录缺首页 README.md');
}

// ———————————————————————————— 落点：产物不得落在被描述项目的源码仓内 ————————————————————————————
// 唯一的新增 error：程序可确定判定（纯路径比较），且后果落在第三方仓库
// （产物污染维护者的仓库，而这个 skill 还会为基线在其上做过 checkout）。
// --allow-in-repo 是显式逃生开关：放行要出声，不能静默跳过。

const degradeReasons = [];
let baselineVerified = false;
let docRootReal = null;
if (docRoot) { try { docRootReal = realpathSync(docRoot); } catch { docRootReal = docRoot; } }

if (docRootReal && repoReal) {
  if (isWithinRoot(repoReal, docRootReal)) {
    if (allowInRepo) {
      report('note', 'DOC-DOCROOT-IN-SRC', docRoot, 1, `已按 --allow-in-repo 显式放行：产物目录位于源码仓内（${docRootReal} ⊂ ${repoReal}）——请确认这是有意的`);
    } else {
      report('error', 'DOC-DOCROOT-IN-SRC', docRoot, 1, `产物目录落在源码仓内（${docRootReal} ⊂ ${repoReal}）——本 skill 的产物不得写入被描述项目；换到仓外目录，或确属有意时显式传 --allow-in-repo`);
    }
  }
} else if (docRootReal && !repoReal) {
  report('note', 'DOC-DOCROOT-IN-SRC', docRoot, 1, '未传 --source-repo，无法判定产物是否落在源码仓内（传上即可自动判定）');
}

// ———————————————————————————— 版本契约（单基线）————————————————————————————
// 契约行是读者需要的口径声明，属正文合法内容（不受铁律 1 约束）。
// 它的作用是三件事：读者知道看的是哪版、依据行有确定快照、下次更新有 diff 的左端。

if (readme) {
  const rmText = readFileSync(readme, 'utf8');
  const cm = CONTRACT_RE.exec(rmText);
  if (!cm) {
    if (CONTRACT_HEAD_RE.test(rmText)) {
      report('note', 'DOC-BASELINE-FORMAT', readme, 1, '「本文档依据」无法解析出 ref/短SHA/日期三元组——写成 `**本文档依据**：\\`v1.2.3\\`（\\`abc1234\\`，2026-08-14）`');
    } else {
      report('note', 'DOC-BASELINE-MISSING', readme, 1, '首页没有「本文档依据」契约行——读者无从判断文档对应哪个版本，下次更新也拿不到 diff 左端');
    }
  } else {
    const [, ref, sha, date] = cm;
    if (!repoReal) {
      report('note', 'DOC-BASELINE-UNRESOLVED', readme, 1, `契约声明 ${ref}@${sha}（${date}）无法核对：未传 --source-repo`);
    } else if (!isGitRepo(repoReal)) {
      report('note', 'DOC-BASELINE-UNRESOLVED', readme, 1, `契约声明 ${ref}@${sha}（${date}）无法核对：源码根不是 git 仓库或缺 git`);
    } else {
      const full = git(repoReal, ['rev-parse', '--verify', `${ref}^{commit}`]);
      if (!full) {
        report('note', 'DOC-BASELINE-UNRESOLVED', readme, 1, `契约声明的 ref 在源码仓里不存在：${ref}`);
      } else {
        const commitDate = git(repoReal, ['log', '-1', '--format=%cs', ref]) || '';
        const tagDate = git(repoReal, ['for-each-ref', '--format=%(creatordate:short)', `refs/tags/${ref}`]) || '';
        const shaOk = full.toLowerCase().startsWith(sha.toLowerCase());
        const dateOk = date === commitDate || (tagDate !== '' && date === tagDate);
        if (!shaOk || !dateOk) {
          const why = [];
          if (!shaOk) why.push(`短SHA 对不上（${ref} 实际为 ${full.slice(0, 12)}…）`);
          if (!dateOk) why.push(`日期对不上（${ref} 的提交日期 ${commitDate || '未知'}${tagDate ? `、tag 日期 ${tagDate}` : ''}）`);
          report('note', 'DOC-BASELINE-UNRESOLVED', readme, 1, `契约声明 ${ref}@${sha}（${date}）与 git 不符：${why.join('；')}`);
        }
      }
    }
  }
}

// —— --expect-baseline：把「校验根 = 自述基线」从口头约定变成机器事实 ——
if (!repoReal) {
  degradeReasons.push('未传 --source-repo');
} else if (!isGitRepo(repoReal)) {
  degradeReasons.push('源码根不是 git 仓库或缺 git，无法核对');
} else if (!expectBaseline) {
  degradeReasons.push('未传 --expect-baseline，无法确认 --source-repo 就是自述基线');
} else {
  const head = git(repoReal, ['rev-parse', 'HEAD']);
  const want = git(repoReal, ['rev-parse', '--verify', `${expectBaseline}^{commit}`]);
  if (!want) {
    degradeReasons.push(`--expect-baseline ${expectBaseline} 无法解析`);
  } else if (head !== want) {
    degradeReasons.push(`当前 HEAD=${(head || '').slice(0, 12)} ≠ --expect-baseline ${expectBaseline}@${want.slice(0, 12)}`);
  } else {
    baselineVerified = true;
  }
}
if (degradeReasons.length && !targetMissing && repoReal) {
  // 未传 --source-repo 时不再重复报一条 note：那属于"根本没校验"，
  // 已由每条引用的 [DOC-SRC-UNCHECKED] 与末尾的降级行说明，重复报只会变噪声。
  report('note', 'DOC-SRC-BASELINE-MISMATCH', docRoot || (readme ?? files[0] ?? '.'), 1, degradeReasons.join('；'));
}

// ———————————————————————————— KB 模式：本 wiki 是否被索引到 ————————————————————————————
// 入库了但没有任何索引链接过来 = 读者找不到 = 另一种静默失败。
// 不传 --kb-repo 则不做此检查（本 skill 的默认形态是独立目录，不是知识库）。

if (kbReal && readme) {
  const target = (() => { try { return realpathSync(readme); } catch { return resolve(readme); } })();
  const CAP = 2000;
  let scanned = 0;
  let truncated = false;
  let linkedToWiki = false;
  const walkKb = (dir) => {
    if (linkedToWiki || truncated) return;
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (linkedToWiki || truncated) return;
      if (e.name === 'node_modules' || e.name.startsWith('.')) continue;
      const p = join(dir, e.name);
      if (e.isDirectory()) {
        // 跳过 wiki 自己：内部页面互链（如"返回首页"）不能算作知识库索引
        let pr = p;
        try { pr = realpathSync(p); } catch { /* 保持原样 */ }
        if (docRootReal && isWithinRoot(docRootReal, pr)) continue;
        walkKb(p);
        continue;
      }
      if (!e.name.toLowerCase().endsWith('.md')) continue;
      scanned += 1;
      if (scanned > CAP) { truncated = true; return; }
      let t;
      try { t = readFileSync(p, 'utf8'); } catch { continue; }
      const lre = /\[[^\]]*\]\(([^)\s]+\.md)\)/g;
      let mm;
      while ((mm = lre.exec(t)) !== null) {
        const cand = resolve(dir, mm[1]);
        let cr = cand;
        try { cr = realpathSync(cand); } catch { /* 悬空链接不满足 */ }
        if (cr === target) { linkedToWiki = true; break; }
      }
    }
  };
  walkKb(kbReal);
  if (!linkedToWiki) {
    report('note', 'DOC-KB-UNLINKED', readme, 1, `知识库（${kbReal}）里没有任何索引链接到本 wiki 首页${truncated ? `（扫描上限 ${CAP} 个 md 后截断，结果可能不完整）` : ''}`);
  }
}

// ———————————————————————————— 输出 ————————————————————————————

if (!quiet) {
  console.log('## 文档检查（check-docs.mjs）\n');
  for (const s of stats) {
    console.log(`- ${s.file}：代码 ${s.codeBlocks} 块 / ${s.codeLines} 行，引用 ${s.citations} 条（依据行 ${s.basis}），图 ${s.figures} 张，正文 ${s.bodyNonEmpty} 行`);
  }
  console.log('');
}

for (const e of errors) {
  console.log(`${C.red}[${e.code}]${C.reset} ${e.file}:${e.line} —— ${e.msg}`);
}
for (const w of warns) {
  console.log(`${C.yellow}[${w.code}]${C.reset} ${w.file}:${w.line} —— ${w.msg}`);
}
// note 默认打印：不阻断 ≠ 不报告。滑成"不报告"就与本 skill 的反静默立场冲突。
for (const n of notes) {
  console.log(`${C.cyan}[${n.code}]${C.reset} ${n.file}:${n.line} —— ${n.msg}`);
}

const totalCitations = stats.reduce((n, s) => n + s.citations, 0);
console.log(`\n检查结果：error=${errors.length} warn=${warns.length} note=${notes.length}（文件 ${files.length} 个）`);
if (totalCitations > 0 && !baselineVerified) {
  // 结论不越权：不阻断，但也不假装"校验过了"。
  console.log(`引用校验结论：未在自述基线上执行（${degradeReasons.join('；') || '未知原因'}）——已校验项不覆盖「行号是否属于该版本」。`);
}
if (targetMissing) {
  console.log('存在必须修复的问题（目标不存在，未检查任何目标）。');
  process.exitCode = 2;
} else if (errors.length) {
  console.log('存在必须修复的问题（error）。代码预算超标时：删减，或写 <!-- code-budget: 理由 --> 显式豁免。');
  process.exitCode = 1;
} else if (strict && warns.length) {
  console.log('--strict 模式：warning 视为失败（note 不参与，永不阻断）。');
  process.exitCode = 1;
} else if (notes.length) {
  console.log(`未发现必须修复的问题（${notes.length} 条 note 待作者回应——不阻断，须在交付清单里逐条交代，见 references/grounding-light.md）。`);
  process.exitCode = 0;
} else {
  console.log('未发现必须修复的问题。');
  process.exitCode = 0;
}
