#!/usr/bin/env node
// check-docs.mjs —— project-wiki 的文档质量门禁（自研，零依赖：只用 node 内置模块）。
//
// 用法：
//   node check-docs.mjs <输出目录|a.md b.md ...> [--source-repo <源码根>] [--strict] [--quiet]
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
//
// 退出码：0 = 通过（仅有 warning）；1 = 存在 error（--strict 时 warning 也算失败）；2 = 用法/目标错误。
// 本脚本只读，不改动任何文档。

import { readFileSync, existsSync, realpathSync, statSync, readdirSync } from 'node:fs';
import { resolve, join, sep } from 'node:path';

// —— 预算（与 references/writing-style.md 的表保持一致）——
const MAX_BLOCKS_PER_PAGE = 3;
const MAX_LINES_PER_BLOCK = 15;
const MAX_CODE_LINES_PER_PAGE = 40;
const MAX_INLINE_REFS_PER_PAGE = 5;
const MIN_BODY_LINES = 15;
const COMPLEX_NODE_THRESHOLD = 12;

const C = {
  reset: '\u001b[0m', red: '\u001b[31m', yellow: '\u001b[33m', dim: '\u001b[2m',
};

// ———————————————————————————— 参数 ————————————————————————————

const argv = process.argv.slice(2);
const targets = [];
let sourceRepo = null;
let strict = false;
let quiet = false;

for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === '--source-repo') { sourceRepo = argv[++i]; continue; }
  if (a === '--strict') { strict = true; continue; }
  if (a === '--quiet') { quiet = true; continue; }
  if (a === '-h' || a === '--help') {
    console.log('用法: node check-docs.mjs <输出目录|a.md b.md ...> [--source-repo <源码根>] [--strict] [--quiet]');
    process.exit(0);
  }
  targets.push(a);
}

if (!targets.length) {
  console.error('用法: node check-docs.mjs <输出目录|a.md b.md ...> [--source-repo <源码根>] [--strict] [--quiet]');
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

// ———————————————————————————— 工具 ————————————————————————————

const errors = [];
const warns = [];

function report(level, code, file, line, msg) {
  const entry = { level, code, file: disp(file), line, msg };
  (level === 'error' ? errors : warns).push(entry);
}

function isWithinRoot(root, target) {
  if (target === root) return true;
  return target.startsWith(root + sep);
}

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

// 引用：逐个 code span 解析，而不是全文件扫正则——否则"正则不认的写法"会静默漏检。
// PRIMARY：整个 code span 内容就是一个 `路径:行号`（允许 ./ ../ / 开头、允许无扩展名）
// 路径字符类含 `[` `]`：Next.js 之类的动态路由目录名就是 `src/app/[owner]/[repo]/page.tsx`，
// 不收的话这类真实引用会掉进 UNPARSED，等于「看得见却验不了」。
const PRIMARY_CITATION_RE = /^(?:(?:\.{1,2}\/)+|\/)?[A-Za-z0-9_@][A-Za-z0-9_./@+[\]-]*(?:\.[A-Za-z][A-Za-z0-9]{0,9})?:(\d+)(?:-(\d+))?$/;
// 任意 code span（用于取出候选再分类）
const CODE_SPAN_RE = /`([^`\n]+)`/g;
// 疑似引用：含 `/` 且以 `:行号` 结尾，但没被 PRIMARY 认出来 → 必须显式告知，不静默放过
const SUSPECT_CITATION_RE = /\/.*:\d+(?:-\d+)?$/;

/**
 * 归一化引用写法：全角冒号、en/em dash、`#L12` 与 `:L12-L20` 锚点式行号。
 * 不做归一化的话，模型换个写法就绕过了校验——这正是"静默放过"的入口。
 */
function normalizeSpan(raw) {
  let out = raw.replace(/：/g, ':').replace(/[–—]/g, '-').trim();
  out = out.replace(/#L(\d+)(?:\s*-\s*L?(\d+))?/gi, (_m, a, b) => (b ? `:${a}-${b}` : `:${a}`));
  out = out.replace(/:L(\d+)(?:\s*-\s*L?(\d+))?/gi, (_m, a, b) => (b ? `:${a}-${b}` : `:${a}`));
  return out;
}
// 校验痕迹（正文不得出现）
const TRACE_RES = [
  /<!--\s*anchor(?:-base64)?\s*:/,
  /<!--\s*snippet(?:-base64)?\s*:/,
  /\bSources?\s*:\s*\[/,
];
const HEADING_NUM_RE = /^#{1,6}\s+(?:[0-9]+|[一二三四五六七八九十百千]+)\s*[.、)）:：]/;

function splitFrontmatter(text) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text);
  if (!m) return { frontmatter: null, body: text, bodyLine: 1 };
  return {
    frontmatter: m[1],
    body: text.slice(m[0].length),
    bodyLine: m[0].split('\n').length,
  };
}

/** 提取围栏代码块 [{lang, startLine, endLine, lines}] */
function extractCodeBlocks(lines) {
  const blocks = [];
  let open = null;
  for (let i = 0; i < lines.length; i += 1) {
    const m = /^\s*```+\s*(\S*)\s*$/.exec(lines[i]);
    if (!m) continue;
    if (open === null) {
      open = { lang: (m[1] || '').toLowerCase(), startLine: i + 1, contentStart: i + 1 };
    } else {
      blocks.push({
        lang: open.lang,
        startLine: open.startLine,
        endLine: i + 1,
        lines: lines.slice(open.contentStart, i),
      });
      open = null;
    }
  }
  if (open !== null) {
    // 未闭合的围栏：按到文末处理，避免整段代码漏检
    blocks.push({ lang: open.lang, startLine: open.startLine, endLine: lines.length, lines: lines.slice(open.contentStart) });
  }
  return blocks;
}

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

  // —— 引用：依据行 + 行内 ——
  const citations = [];
  const inlineCitations = [];
  const unparsed = [];
  // 依据可以是「一行」，也可以是同一引用块里折行的「一块」：续行同样算依据。
  // 否则长依据列表一折行，后半截就被误判成散落在正文里的行内引用。
  let inBasisBlock = false;
  for (let i = 0; i < lines.length; i += 1) {
    if (/^\s*>?\s*依据\s*[:：]/.test(lines[i])) inBasisBlock = true;
    else if (!(inBasisBlock && /^\s*>/.test(lines[i]))) inBasisBlock = false;
    const isBasis = inBasisBlock;
    CODE_SPAN_RE.lastIndex = 0;
    let m;
    while ((m = CODE_SPAN_RE.exec(lines[i])) !== null) {
      const span = normalizeSpan(m[1]);
      const pm = PRIMARY_CITATION_RE.exec(span);
      if (pm) {
        // 路径 = span 去掉末尾的 `:start[-end]`
        const suffix = pm[0].slice(pm[0].lastIndexOf(':'));
        const rec = {
          path: span.slice(0, span.length - suffix.length),
          start: parseInt(pm[1], 10),
          end: pm[2] ? parseInt(pm[2], 10) : parseInt(pm[1], 10),
          line: i + 1,
          basis: isBasis,
        };
        citations.push(rec);
        if (!isBasis) inlineCitations.push(rec);
      } else if (span.includes('/') && SUSPECT_CITATION_RE.test(span)) {
        unparsed.push({ text: span, line: i + 1 });
      }
    }
  }

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

console.log(`\n检查结果：error=${errors.length} warn=${warns.length}（文件 ${files.length} 个）`);
if (targetMissing) {
  console.log('存在必须修复的问题（目标不存在，未检查任何目标）。');
  process.exitCode = 2;
} else if (errors.length) {
  console.log('存在必须修复的问题（error）。代码预算超标时：删减，或写 <!-- code-budget: 理由 --> 显式豁免。');
  process.exitCode = 1;
} else if (strict && warns.length) {
  console.log('--strict 模式：warning 视为失败。');
  process.exitCode = 1;
} else {
  console.log('未发现必须修复的问题。');
  process.exitCode = 0;
}
