#!/usr/bin/env node
// check-design-doc.mjs —— tech-design 的文档正文门禁（零依赖，只用 node 内置模块）。
//
// 用法：
//   node check-design-doc.mjs <方案.md>... [--tier light|standard|full] [--upstream <PRD.md>...]
//                             [--strict] [--quiet] [--json]
//
// 严重度三档（与 project-wiki/scripts/check-docs.mjs 同一套语义）：
//   error  程序可确定判定，且违反会让评审读到错的东西        → 退出码 1
//   warn   程序可判定，但属质量偏好                          → 默认 0；--strict 下 1
//   note   作者侧口径，或程序判不了、只有人能判的事           → **任何模式下都是 0**，但默认打印（不静默）
//
// 它只做「机械那半」：占位符、空壳章节、缺状态块、无备选、追溯缺列、DDL 与正文两说。
// 「这条 Rule 是否真可执行」「边界是否合理」这类语义判断归 references/review-gate.md 的评审者，
// 不在这里猜——假阳性会让门禁被弃用。
//
// 行号对齐（BMAD lint_spine 的做法）：扫描前把 fenced code block 换成**等量空行**，
// 这样 mermaid / 源码树 / DDL 不产生假阳性，而报出的行号仍是文件真实行号；带 frontmatter 时再加偏移。
//
// 退出码：0 通过（仅 warn/note）；1 存在 error（--strict 时 warn 也算）；2 用法错误。

import { existsSync, readFileSync, statSync } from 'node:fs';
import { resolve, basename, dirname } from 'node:path';

const USAGE = '用法: node check-design-doc.mjs <方案.md>... [--tier light|standard|full] [--upstream <PRD.md>...] [--strict] [--quiet] [--json]';

const C = {
  reset: '\u001b[0m', red: '\u001b[31m', yellow: '\u001b[33m', cyan: '\u001b[36m', dim: '\u001b[2m', bold: '\u001b[1m',
};

// ———————————————————————————— 参数 ————————————————————————————

const argv = process.argv.slice(2);
const targets = [];
const upstreamPaths = [];
let tierOpt = null;
let strict = false;
let quiet = false;
let asJson = false;

for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === '--tier') { tierOpt = argv[++i]; continue; }
  if (a === '--upstream') { upstreamPaths.push(argv[++i]); continue; }
  if (a === '--strict') { strict = true; continue; }
  if (a === '--quiet') { quiet = true; continue; }
  if (a === '--json') { asJson = true; continue; }
  if (a === '-h' || a === '--help') { console.log(USAGE); process.exit(0); }
  if (a.startsWith('--')) { console.error(`[用法错误] 未知参数：${a}\n${USAGE}`); process.exit(2); }
  targets.push(a);
}

if (!targets.length) { console.error(USAGE); process.exit(2); }
if (tierOpt !== null && !['light', 'standard', 'full'].includes(tierOpt)) {
  console.error(`[用法错误] --tier 只能是 light / standard / full，收到：${tierOpt}`);
  process.exit(2);
}
for (const u of upstreamPaths) {
  if (!u || !existsSync(resolve(u))) { console.error(`[用法错误] --upstream 不存在：${u}`); process.exit(2); }
}

// ———————————————————————————— 报告 ————————————————————————————

const findings = [];
let currentFile = '';
let targetMissing = false;

function report(level, code, line, msg) {
  findings.push({ level, code, file: currentFile, line, msg });
}

/** 展示用短路径：只留文件名，避免刷屏的绝对路径 */
function disp(p) { return basename(p); }

// ———————————————————————————— 解析 ————————————————————————————

/** 拆 frontmatter：只认「第 1 行恰好是 ---」且找得到闭合行，返回 body 与行偏移 */
function splitFrontmatter(text) {
  const lines = text.split('\n');
  if (lines[0] === '---') {
    for (let i = 1; i < lines.length; i += 1) {
      if (lines[i] === '---') {
        return { frontmatter: lines.slice(1, i), body: lines.slice(i + 1), offset: i + 1 };
      }
    }
  }
  return { frontmatter: [], body: lines, offset: 0 };
}

/** 把 fenced code block 的内容换成空行，行数不变（行号仍然对齐） */
function blankFences(lines) {
  const out = lines.slice();
  let inFence = false;
  let marker = null;
  for (let i = 0; i < lines.length; i += 1) {
    const m = lines[i].match(/^\s*(```+|~~~+)/);
    if (m) {
      const ch = m[1][0];
      if (!inFence) { inFence = true; marker = ch; out[i] = ''; continue; }
      if (ch === marker) { inFence = false; marker = null; out[i] = ''; continue; }
    }
    if (inFence) out[i] = '';
  }
  return out;
}

/** 代码块清单（原文，供 DDL 校验用） */
function fencedBlocks(lines) {
  const blocks = [];
  let inFence = false;
  let marker = null;
  let start = 0;
  let lang = '';
  let buf = [];
  for (let i = 0; i < lines.length; i += 1) {
    const m = lines[i].match(/^\s*(```+|~~~+)\s*([A-Za-z0-9_+-]*)/);
    if (m) {
      const ch = m[1][0];
      if (!inFence) { inFence = true; marker = ch; start = i; lang = m[2] || ''; buf = []; continue; }
      if (ch === marker) {
        inFence = false; marker = null;
        blocks.push({ start, end: i, lang, lines: buf });
        continue;
      }
    }
    if (inFence) buf.push(lines[i]);
  }
  return blocks;
}

function parseHeadings(lines) {
  const out = [];
  for (let i = 0; i < lines.length; i += 1) {
    const m = lines[i].match(/^(#{1,6})\s+(.+?)\s*$/);
    if (m) out.push({ line: i, level: m[1].length, text: m[2].trim() });
  }
  return out;
}

/** 标题的章节体：[heading.line+1, 下一个 level<=当前 的标题行) */
function sectionRange(headings, idx, total) {
  const { level, line } = headings[idx];
  let end = total;
  for (let k = idx + 1; k < headings.length; k += 1) {
    if (headings[k].level <= level) { end = headings[k].line; break; }
  }
  return [line + 1, end];
}

function effectiveLines(lines, from, to) {
  const out = [];
  for (let i = from; i < to; i += 1) {
    const t = lines[i].trim();
    if (!t) continue;
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(t)) continue;
    if (/^#{1,6}\s/.test(t)) continue; // 子标题不算正文
    out.push({ line: i, text: t });
  }
  return out;
}

function splitRow(line) {
  return line.replace(/^\s*\|/, '').replace(/\|\s*$/, '').split('|').map((s) => s.trim());
}

function findTables(lines) {
  const tables = [];
  for (let i = 0; i < lines.length; i += 1) {
    if (!/^\s*\|/.test(lines[i])) continue;
    let j = i;
    while (j < lines.length && /^\s*\|/.test(lines[j])) j += 1;
    if (j - i >= 2 && /^\s*\|[\s:|-]+\|?\s*$/.test(lines[i + 1])) {
      tables.push({
        start: i, end: j - 1,
        header: splitRow(lines[i]),
        rows: lines.slice(i + 2, j).map((l) => ({ line: 0, cells: splitRow(l) })),
        rawRows: lines.slice(i + 2, j),
      });
    }
    i = j - 1;
  }
  // 回填每行真实行号（split 时丢了位置）
  for (const t of tables) {
    t.rows = t.rawRows.map((_, k) => ({ line: t.start + 2 + k, cells: splitRow(t.rawRows[k]) }));
  }
  return tables;
}

const hasDigit = (s) => /[0-9０-９]/.test(s);

// ———————————————————————————— 规则 ————————————————————————————

// 形容词化：同一行没有数字才算「无口径的形容词」
const VAGUE_WORDS = [
  '高性能', '海量', '高可用', '高并发', '低延迟', '显著', '大幅', '明显提升', '明显改善',
  '更好', '更快', '更稳', '高效', '灵活', '强大', '友好', '业界领先', '极致', '大幅提升',
];

// 数字无口径：只在这些章节里查性能类量纲，且该行没有口径词
const PERF_SECTION_RE = /性能|容量|压测|延迟|吞吐|可用性|SLA|成本|收益|指标/;
const PERF_UNIT_RE = /[0-9]+\s*(ms|毫秒|µs|us|ns|s\b|秒|qps|QPS|tps|TPS|rps|RPS|GB|TB|MB|MiB|GiB|%)/;
const BASIS_WORD_RE = /p50|p95|p99|P50|P95|P99|平均|均值|中位|峰值|分位|窗口|口径|假设|预估|预判|压测|采样|抽样|观测|复核|推断|推导|测算|估算|敏感度|经验值|系数|依据|来源|上限/;
// 表格里的口径常写在表头（「计算」「口径」「推导」列），或直接给推导式（5000 × (1−45%)）
const BASIS_HEADER_RE = /口径|计算|推导|测算|依据|来源|假设|判据|方法|方式|变量|情景|场景|悲观|乐观|影响|触发|对策|预算/;
const DERIVATION_RE = /[÷×]|\d\s*[*/]\s*\d|＝|=.*[÷×]/;
// 光有数字+单位不够（「≥60% 能展示」是验收口径，不是性能claims），还要有性能语境词
const PERF_CONTEXT_RE = /QPS|TPS|RPS|RT\b|延迟|耗时|吞吐|并发|水位|可用性|命中率|带宽|存储量|SLA/;

const PLACEHOLDER_RE = /\b(TBD|TODO|FIXME|TKTK)\b|待补充|待填写|待填|＜[^＞]*占位[^＞]*＞|<[^<>\n]*(占位|placeholder)[^<>\n]*>/i;
const SHELL_RE = /^(N\/A|n\/a|不适用|无|略|待填|待补充|同上|暂略)$/;
const STATUS_VALUES = ['草案待评', '评审中', '已批准'];
const OPTION_HEAD_RE = /备选|选型|方案对比/;
const OPTION_KEYWORD_RE = /不做|维持现状|不选|否决|放弃|不采用|现状不动/;
const TRACE_HEAD_RE = /决策/;
const TRACE_NEED_COL_RE = /承接需求|需求|目标/;
const TRACE_VERIFY_COL_RE = /验证/;

function checkStatusBlock(scanLines, offset) {
  const idx = scanLines.findIndex((l) => /^>\s*\**\s*状态\s*[:：]/.test(l));
  if (idx < 0) {
    report('error', 'TD-STATUS-BLOCK', offset + 1,
      '缺少文档状态块（`> 状态：草案待评 ｜ 作者：… ｜ 评审人：… ｜ 拍板人：… ｜ 最后更新：YYYY-MM-DD`）');
    return;
  }
  const line = scanLines[idx];
  const missing = ['作者', '评审人', '拍板人', '最后更新'].filter((f) => !line.includes(f));
  if (missing.length) {
    report('error', 'TD-STATUS-BLOCK', offset + idx + 1, `状态块缺字段：${missing.join('、')}`);
  }
  const m = line.match(/状态\s*[:：]\s*([^\s｜|]+)/);
  if (m && !STATUS_VALUES.some((v) => m[1].includes(v))) {
    report('warn', 'TD-STATUS-VALUE', offset + idx + 1,
      `状态取值「${m[1]}」不在 ${STATUS_VALUES.join(' / ')} 内`);
  }
}

function checkPlaceholders(scanLines, offset) {
  for (let i = 0; i < scanLines.length; i += 1) {
    const t = scanLines[i].trim();
    if (!t) continue;
    const m = t.match(PLACEHOLDER_RE);
    if (m) {
      report('error', 'TD-PLACEHOLDER', offset + i + 1, `残留占位符「${m[0]}」，要么写实要么删掉该句`);
    }
  }
}

function checkShellSections(rawLines, headings, offset) {
  const thin = [];
  for (let k = 0; k < headings.length; k += 1) {
    if (headings[k].level === 1) continue;
    const [from, to] = sectionRange(headings, k, rawLines.length);
    const body = effectiveLines(rawLines, from, to);
    if (body.length === 1 && SHELL_RE.test(body[0].text.replace(/[*`]/g, '').trim())) {
      report('error', 'TD-NA', offset + headings[k].line + 1,
        `章节「${headings[k].text}」只有「${body[0].text}」——不适用的章节删掉，不留 N/A 或占位`);
    } else if (body.length === 0) {
      report('warn', 'TD-SECTION-EMPTY', offset + headings[k].line + 1,
        `章节「${headings[k].text}」没有正文`);
    } else if (body.length < 2 && headings[k].level >= 2) {
      thin.push({ line: headings[k].line + 1, text: headings[k].text });
    }
  }
  // 聚合：一次列全，不刷 7 条同义 warn
  if (thin.length) {
    const where = thin.slice(0, 6).map((t) => `「${t.text}」(行 ${t.line})`).join('、')
      + (thin.length > 6 ? ` 等 ${thin.length} 个` : '');
    report('warn', 'TD-SECTION-THIN', offset + thin[0].line,
      `${thin.length} 个章节只有 1 行有效内容，确认不是占位：${where}`);
  }
}

function checkVague(scanLines, offset) {
  for (let i = 0; i < scanLines.length; i += 1) {
    const t = scanLines[i];
    if (!t.trim() || hasDigit(t)) continue;
    if (isTableHeaderRow(scanLines, i)) continue;
    if (enclosingHeadings(scanLines, i).some((h) => /术语|词汇|名词|glossary/i.test(h))) continue;
    for (const w of VAGUE_WORDS) {
      if (t.includes(w)) {
        report('warn', 'TD-VAGUE', offset + i + 1, `「${w}」没有数字支撑，换成量化目标 + 口径`);
        break;
      }
    }
  }
}

/** 该行是不是表格的表头或分隔行（表头里的词不该按正文规则判） */
function isTableHeaderRow(lines, i) {
  if (!/^\s*\|/.test(lines[i])) return false;
  if (/^\s*\|[\s:|-]+\|\s*$/.test(lines[i])) return true;
  const next = lines[i + 1] || '';
  return /^\s*\|[\s:|-]+\|\s*$/.test(next);
}

/** 某行所处的标题链（从外到内） */
function enclosingHeadings(lines, i) {
  const out = [];
  for (let k = 0; k <= i && k < lines.length; k += 1) {
    const m = lines[k].match(/^(#{1,6})\s+(.+?)\s*$/);
    if (!m) continue;
    while (out.length && out[out.length - 1].level >= m[1].length) out.pop();
    out.push({ level: m[1].length, text: m[2] });
  }
  return out.map((h) => h.text);
}

/** 返回某行所在 Markdown 表格的表头行文本（不是表格行则返回空串） */
function tableHeaderFor(lines, idx) {
  if (!/^\s*\|/.test(lines[idx])) return '';
  let k = idx;
  while (k > 0 && /^\s*\|/.test(lines[k - 1])) k -= 1;
  return lines[k] || '';
}

function checkNumbers(scanLines, offset) {
  let inPerf = false;
  let perfLevel = 0;
  for (let i = 0; i < scanLines.length; i += 1) {
    const hm = scanLines[i].match(/^(#{1,6})\s+(.+?)\s*$/);
    if (hm) {
      const level = hm[1].length;
      if (inPerf && level <= perfLevel) inPerf = false;
      if (PERF_SECTION_RE.test(hm[2])) { inPerf = true; perfLevel = level; }
      continue;
    }
    if (!inPerf) continue;
    const t = scanLines[i];
    if (!PERF_UNIT_RE.test(t) || BASIS_WORD_RE.test(t)) continue;
    if (!PERF_CONTEXT_RE.test(t)) continue;
    if (DERIVATION_RE.test(t)) continue;
    // 敏感度/预算/推导类小节：写的是条件值与算法，不是待验收的论断
    if (enclosingHeadings(scanLines, i).some((h) => /敏感度|预算|推导|测算|口径|假设|压测|验证|测试|演练/.test(h))) continue;
    if (/^\s*\|/.test(t) && BASIS_HEADER_RE.test(tableHeaderFor(scanLines, i))) continue;
    report('warn', 'TD-NUM-BASIS', offset + i + 1,
      '性能类数字没有口径（平均/p95/p99/窗口/假设来源），评审无法判断是否成立');
  }
}

/** 目标/验收章节里的「提升/降低/优化」必须落到数字上，否则是口号 */
const GOAL_SECTION_RE = /目标|验收/;
const GOAL_VERB_RE = /提升|提高|降低|减少|缩短|优化|加速|下降/;
function checkGoalNumbers(scanLines, offset) {
  let inside = false;
  let level = 0;
  for (let i = 0; i < scanLines.length; i += 1) {
    const hm = scanLines[i].match(/^(#{1,6})\s+(.+?)\s*$/);
    if (hm) {
      if (inside && hm[1].length <= level) inside = false;
      if (GOAL_SECTION_RE.test(hm[2])) { inside = true; level = hm[1].length; }
      continue;
    }
    if (!inside) continue;
    if (isTableHeaderRow(scanLines, i)) continue;
    const t = scanLines[i];
    if (!GOAL_VERB_RE.test(t) || hasDigit(t)) continue;
    if (/口径|假设|待验证|超出范畴|非目标/.test(t)) continue;
    report('warn', 'TD-GOAL-NO-NUMBER', offset + i + 1,
      '「提升/降低/优化」没有数字与口径——这是口号，不是目标');
  }
}

/** 空话风控：出现即返工的那几句 */
const EMPTY_PHRASE_RE = /加强监控|做好兜底|持续关注|高度重视|保障稳定|注意性能|关注性能|做好保障|加强保障/;
function checkEmptyPhrases(scanLines, offset) {
  for (let i = 0; i < scanLines.length; i += 1) {
    const m = scanLines[i].match(EMPTY_PHRASE_RE);
    if (m) {
      report('warn', 'TD-EMPTY-WORDS', offset + i + 1,
        `「${m[0]}」是空话——换成触发条件 + 具体动作 + 责任方`);
    }
  }
}

function checkOptions(scanLines, headings, offset) {
  const hits = headings.map((h, k) => ({ h, k })).filter(({ h }) => OPTION_HEAD_RE.test(h.text));
  if (!hits.length) {
    report('error', 'TD-OPTION', offset + 1, '全文没有「备选/选型/方案对比」章节——单一方案视为未完成');
    return;
  }
  const pooled = hits.flatMap(({ h, k }) => {
    const [from, to] = sectionRange(headings, k, scanLines.length);
    return scanLines.slice(from, to).join('\n');
  }).join('\n');
  if (!OPTION_KEYWORD_RE.test(pooled)) {
    report('error', 'TD-OPTION', offset + hits[0].h.line + 1,
      '备选章节里没有「不做 / 维持现状 / 否决」对照项——必须含不作为的基线');
  }
}

function checkTrace(scanLines, offset, tier, upstreamTokens) {
  if (tier === 'light') return;
  const tables = findTables(scanLines);
  const trace = tables.find((t) => {
    const joined = t.header.join(' ');
    return TRACE_HEAD_RE.test(joined) && TRACE_NEED_COL_RE.test(joined);
  });
  if (!trace) {
    report('error', 'TD-TRACE', offset + 1,
      '缺少「决策 ↔ 需求」追溯表（决策 ID / 承接需求 / 备选 / 验证手段 / 状态 / 置信度），见 references/templates.md');
    return;
  }
  const verifyCol = trace.header.findIndex((h) => TRACE_VERIFY_COL_RE.test(h));
  if (verifyCol < 0) {
    report('error', 'TD-TRACE', offset + trace.start + 1, '追溯表缺「验证手段」列：决策没有验证手段等于没有验收');
  }
  const needCol = trace.header.findIndex((h) => TRACE_NEED_COL_RE.test(h));
  for (const row of trace.rows) {
    if (row.cells.every((c) => !c)) continue;
    if (needCol >= 0 && !row.cells[needCol]) {
      report('error', 'TD-TRACE', offset + row.line + 1, '该决策行「承接需求」为空——孤儿决策，无法回指目标');
    }
    if (verifyCol >= 0 && !row.cells[verifyCol]) {
      report('error', 'TD-TRACE', offset + row.line + 1, '该决策行「验证手段」为空——决策无法验收');
    }
    if (upstreamTokens.size && needCol >= 0) {
      const refs = (row.cells[needCol] || '').match(/[A-Z]{1,4}-\d+/g) || [];
      for (const r of refs) {
        if (!upstreamTokens.has(r)) {
          report('warn', 'TD-TRACE-UPSTREAM', offset + row.line + 1,
            `承接需求「${r}」在上游文档里找不到——编号漂移或凭空引用`);
        }
      }
    }
  }
}

/** 从 CREATE TABLE 体里抽列名（跳过约束关键字） */
function ddlColumns(blocks) {
  const SKIP = new Set([
    'primary', 'foreign', 'unique', 'key', 'index', 'constraint', 'check', 'create',
    'table', 'if', 'not', 'exists', 'references', 'on', 'default', 'comment',
  ]);
  const cols = new Set();
  for (const b of blocks) {
    if (!/create\s+table/i.test(b.lines.join('\n'))) continue;
    let inside = false;
    for (const raw of b.lines) {
      const line = raw.trim();
      if (/^create\s+table/i.test(line)) { inside = true; continue; }
      if (!inside) continue;
      if (/^\)/.test(line)) { inside = false; continue; }
      const m = line.match(/^`?([A-Za-z_][A-Za-z0-9_]*)`?\s+\S/);
      if (m && !SKIP.has(m[1].toLowerCase())) cols.add(m[1]);
    }
  }
  return cols;
}

function tableColumns(tables) {
  const cols = new Set();
  for (const t of tables) {
    const h = t.header.join(' ');
    if (!/字段|列名/.test(h)) continue;
    if (!/类型|说明|注释|含义/.test(h)) continue;
    const col = t.header.findIndex((x) => /字段|列名/.test(x));
    for (const row of t.rows) {
      const raw = (row.cells[col] || '').replace(/[`*]/g, '').trim();
      const m = raw.match(/^([A-Za-z_][A-Za-z0-9_]*)$/);
      if (m) cols.add(m[1]);
    }
  }
  return cols;
}

function checkDdl(scanLines, rawScanLines, headings, offset) {
  // 只在存在「附录 DDL」且正文有字段表时比；缺一边就不判（那是结构问题，不是门禁的活）
  const blocks = fencedBlocks(rawScanLines);
  const ddl = ddlColumns(blocks);
  if (!ddl.size) return;
  const tables = findTables(scanLines);
  const body = tableColumns(tables);
  if (!body.size) return;
  const onlyDdl = [...ddl].filter((c) => !body.has(c));
  const onlyBody = [...body].filter((c) => !ddl.has(c));
  if (onlyDdl.length || onlyBody.length) {
    const anchor = headings.find((h) => /附录|DDL/i.test(h.text));
    const parts = [];
    if (onlyDdl.length) parts.push(`只在 DDL：${onlyDdl.join('、')}`);
    if (onlyBody.length) parts.push(`只在正文表：${onlyBody.join('、')}`);
    report('warn', 'TD-DDL-MISMATCH', offset + (anchor ? anchor.line + 1 : 1),
      `附录 DDL 与正文字段表不一致（${parts.join('；')}）——附录 DDL 是唯一可执行真源，必须逐项一致`);
  }
}

function checkMarkers(scanLines, offset) {
  const buckets = new Map([['[待核实]', []], ['[待澄清]', []], ['[假设]', []]]);
  for (let i = 0; i < scanLines.length; i += 1) {
    for (const [mark, arr] of buckets) {
      if (scanLines[i].includes(mark)) arr.push(offset + i + 1);
    }
  }
  for (const [mark, arr] of buckets) {
    if (!arr.length) continue;
    const where = arr.slice(0, 5).join('、') + (arr.length > 5 ? ` 等 ${arr.length} 处` : '');
    const vaults = ['开放问题', '待确认', '未决', '假设与约束']
      .filter((k) => scanLines.some((l) => new RegExp(`^#{1,6}\\s*.*${k}`).test(l)));
    const vault = vaults.length ? `「${vaults.join(' / ')}」` : '开放问题 / 假设与约束';
    report('note', 'TD-MARKER', arr[0], `${mark} ${arr.length} 处（行 ${where}）——确认都已收口到${vault}`);
  }
  // 三章互斥的检查交给评审者；这里只保证「有记号就要有开放问题章节」
  const total = [...buckets.values()].reduce((n, a) => n + a.length, 0);
  // 「假设与约束」也是合法收口点：轻量档没有开放问题章节时，[假设] 应落在这里
  if (total && !scanLines.some((l) => /^#{1,6}\s*.*(开放问题|待确认|未决|假设与约束)/.test(l))) {
    report('warn', 'TD-MARKER-UNCOLLECTED', offset + 1,
      `有 ${total} 处未定记号，但全文没有「开放问题 / 待确认 / 假设与约束」章节——未定项散在正文里`);
  }
}

/** 有架构/流程/数据模型章节却一张图都没有：结构关系用文字写，读者要自己脑内连线 */
function checkDiagrams(rawLines, scanLines, offset, tier) {
  if (tier === 'light') return;
  const text = rawLines.join('\n');
  // 「有图」只认三种真形态：mermaid 围栏、markdown 图片、内联 svg。
  // 不能把正文里出现的 .jpg 当图——商品图 URL 会把这条规则骗过去。
  const hasDiagram = /```\s*mermaid|```\s*(dot|plantuml)/i.test(text)
    || /!\[[^\]]*\]\(/.test(text)
    || /<svg[\s>]/i.test(text);
  if (hasDiagram) return;
  const structural = scanLines.some((l) => /^#{1,6}\s*.*(架构|上下文|拓扑|流程|数据模型|部署|边界)/.test(l));
  if (!structural) return;
  report('warn', 'TD-NO-DIAGRAM', offset + 1,
    '有架构/流程/数据模型类章节，但全文一张图都没有——结构与流转是图的活，纯文字等于让评审在脑内连线');
}

/** 图引用必须落地：写了 ![](x.svg) 但文件不存在，评审看到的是断链 */
function checkAssets(rawLines, docAbs, offset) {
  const missing = [];
  for (let i = 0; i < rawLines.length; i += 1) {
    const tags = rawLines[i].match(/!\[[^\]]*\]\(\s*[^)\s]+\s*\)/g);
    if (!tags) continue;
    for (const tag of tags) {
      const p = tag.replace(/^!\[[^\]]*\]\(\s*/, '').replace(/\s*\)$/, '');
      if (/^(https?:|data:)/.test(p)) continue;
      if (!existsSync(resolve(dirname(docAbs), p.split('#')[0]))) missing.push({ line: i + 1, p });
    }
  }
  if (!missing.length) return;
  const list = missing.slice(0, 4).map((m) => `${m.p}(行 ${m.line})`).join('、');
  report('warn', 'TD-ASSET-MISSING', offset + missing[0].line, `引用的图不存在：${list}——图表资产要和文档一起落盘`);
}

/** 交付文档不该引用技能内部文件：读者手上没有 quality-bar.md / templates.md */
const INTERNAL_REF_RE = /(quality-bar|templates|scenarios|focus-areas|data-model|quantification|review-gate)\.md|references\/[a-z-]+\.md|\bSKILL\.md\b|本技能/;
function checkInternalRefs(scanLines, offset) {
  const hits = [];
  for (let i = 0; i < scanLines.length; i += 1) {
    if (INTERNAL_REF_RE.test(scanLines[i])) hits.push(i + 1);
  }
  if (!hits.length) return;
  const where = hits.slice(0, 5).join('、') + (hits.length > 5 ? ` 等 ${hits.length} 处` : '');
  report('warn', 'TD-INTERNAL-REF', offset + hits[0],
    `${hits.length} 处引用了技能内部文件/术语（行 ${where}）——交付文档要能独立读懂，读者手上没有这些文件`);
}

/** 体量提示：超过 ~20 屏（≈900 行）就该拆「总纲 + 子方案」，这是 note 不阻断 */
function checkSize(rawLines, offset) {
  if (rawLines.length > 900) {
    report('note', 'TD-SIZE', offset + 1,
      `文档 ${rawLines.length} 行，超过 ~20 屏的阅读上限——考虑拆成「总纲 + 子方案」并互链（SKILL.md 体量红线）`);
  }
}

function inferTier(scanLines) {
  const text = scanLines.join('\n');
  if (/^##\s*摘要/m.test(text)) return 'full';
  if (/^##\s*(待确认与开放问题|方案与选型对比)/m.test(text)) return 'full';
  if (/^###\s*(阶段与里程碑|资源需求)/m.test(text)) return 'standard';
  return 'light';
}

// ———————————————————————————— 主流程 ————————————————————————————

const upstreamTokens = new Set();
for (const u of upstreamPaths) {
  const text = readFileSync(resolve(u), 'utf8');
  for (const m of text.matchAll(/\b([A-Z]{1,4}-\d+)\b/g)) upstreamTokens.add(m[1]);
}

let failed = false;

for (const target of targets) {
  const abs = resolve(target);
  if (!existsSync(abs) || !statSync(abs).isFile()) {
    currentFile = disp(abs);
    report('error', 'TD-TARGET-MISSING', 0, `目标不存在或不是文件：${target}`);
    targetMissing = true;
    continue;
  }
  currentFile = disp(abs);
  const raw = readFileSync(abs, 'utf8');
  const { body, offset } = splitFrontmatter(raw);
  const scan = blankFences(body);
  const headings = parseHeadings(scan);
  const tier = tierOpt || inferTier(scan);

  checkStatusBlock(scan, offset);
  checkPlaceholders(scan, offset);
  checkShellSections(body, headings, offset);
  checkSize(body, offset);
  checkInternalRefs(scan, offset);
  checkDiagrams(body, scan, offset, tier);
  checkAssets(body, abs, offset);
  checkVague(scan, offset);
  checkGoalNumbers(scan, offset);
  checkEmptyPhrases(scan, offset);
  checkNumbers(scan, offset);
  checkOptions(scan, headings, offset);
  checkTrace(scan, offset, tier, upstreamTokens);
  checkDdl(scan, body, headings, offset);
  checkMarkers(scan, offset);
}

// ———————————————————————————— 输出 ————————————————————————————

const errors = findings.filter((f) => f.level === 'error');
const warns = findings.filter((f) => f.level === 'warn');
const notes = findings.filter((f) => f.level === 'note');

if (asJson) {
  console.log(JSON.stringify({
    findings,
    summary: { error: errors.length, warn: warns.length, note: notes.length },
  }, null, 2));
} else if (!quiet) {
  const render = (list, color) => {
    for (const f of list) {
      console.log(`${color}${f.level === 'error' ? '✗' : f.level === 'warn' ? '!' : '·'} ${f.code}${C.reset} ${C.dim}${f.file}${f.line ? ':' + f.line : ''}${C.reset} ${f.msg}`);
    }
  };
  if (errors.length) { console.log(`${C.bold}${C.red}error${C.reset}`); render(errors, C.red); }
  if (warns.length) { console.log(`${C.bold}${C.yellow}warn${C.reset}`); render(warns, C.yellow); }
  if (notes.length) { console.log(`${C.bold}${C.cyan}note${C.reset}`); render(notes, C.cyan); }
}

const strictFail = strict && warns.length > 0;
const exitCode = (errors.length || targetMissing || strictFail) ? 1 : 0;

if (!asJson && !quiet) {
  const verdict = exitCode === 0 ? `${C.cyan}通过${C.reset}` : `${C.red}不通过${C.reset}`;
  const strictTag = strictFail && !errors.length ? '（--strict：warn 视为失败）' : '';
  console.log(`${verdict}  ${errors.length} error / ${warns.length} warn / ${notes.length} note${strictTag}`);
  if (exitCode === 0) {
    console.log(`${C.dim}注意：门禁只覆盖机械项；语义判断（Rule 是否可执行、边界是否合理）走 references/review-gate.md${C.reset}`);
  }
}

process.exit(exitCode);
