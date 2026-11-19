#!/usr/bin/env node
/**
 * resume-interview 手册结构门禁。
 *
 * 用法：
 *   node check-interview-doc.mjs <手册.md>...
 *   node check-interview-doc.mjs <手册.md> --strict
 *   node check-interview-doc.mjs --list-rules
 *
 * 退出码：0 无 error（--strict 下无 error/warn）/ 1 有阻断项 / 2 用法或读取错误。
 *
 * 只判结构自洽，不判题目好不好、答案对不对——语义判断留给作者自检与面试官本人。
 */

import { readFileSync, existsSync } from 'node:fs';

const RULES = [
  ['RI-META', 'error', '元数据块缺失，或 candidate / minutes / date / level 缺失或格式非法'],
  ['RI-TITLE', 'warn', '缺 H1 标题'],
  ['RI-QTITLE', 'warn', '题目缺标题'],
  ['RI-SECTION', 'error', '缺「面试前 / 面试 / 覆盖核对 / 面试后」中的某个二级段落'],
  ['RI-ORDER', 'warn', '四个段落顺序与契约不一致'],
  ['RI-PRE', 'error', '「面试前」缺画像或必须核实'],
  ['RI-PRE-SOFT', 'warn', '「面试前」缺时间表'],
  ['RI-QUESTION', 'error', '没有任何 `### Q<编号>` 题目（围栏内的题目不算）'],
  ['RI-DUP', 'error', '题号重复'],
  ['RI-GAP', 'warn', '题号不连续'],
  ['RI-EVIDENCE', 'error', '题目缺 `题源`，或题源未用「」/“”引用简历原文'],
  ['RI-EVIDENCE-LOC', 'warn', '题源没有位置说明（`— 项目 · 段落`）'],
  ['RI-POINT', 'warn', '题目缺 `考点`'],
  ['RI-TIME-FIELD', 'error', '题目缺可解析的 `时长：N 分钟`'],
  ['RI-LISTEN', 'error', '题目缺 `要听的点`'],
  ['RI-STAR', 'error', '`要听的点` 缺 ★、★ 多于一处、或 ★ 不在 meta.level 对应的档位'],
  ['RI-LEVELS', 'warn', '`要听的点` 未按行覆盖 4/3/2/1 四档'],
  ['RI-ANSWER', 'error', '题目缺 `示范答案`'],
  ['RI-ANSWER-SHORT', 'warn', '`示范答案` 少于 60 字'],
  ['RI-FLAG', 'warn', '题目缺 `危险信号`'],
  ['RI-FOLLOWUP', 'note', '题目没有追问（可选）'],
  ['RI-BUDGET', 'error', '各题时长合计超过面试时长，或与时间表不一致'],
  ['RI-BUDGET-LOW', 'warn', '各题时长合计不足面试时长的 60%'],
  ['RI-COVERAGE', 'error', '「覆盖核对」缺失、无表格或无数据行'],
  ['RI-COVERAGE-REF', 'error', '覆盖表引用了不存在的题号'],
  ['RI-COVERAGE-BARE', 'warn', '覆盖表某行既无题号也无 `覆盖豁免：`'],
  ['RI-DIM', 'warn', '「面试后」缺维度评分表'],
  ['RI-VERDICT', 'warn', '「面试后」缺判定规则'],
  ['RI-TODO', 'error', '残留 TODO / TBD / FIXME / 裸「待补」'],
  ['RI-PLACEHOLDER', 'note', '存在 `〔待补充〕` / `〔假设〕` 占位符（允许，需在交付说明里点出）'],
];

const SEVERITY = new Map(RULES.map(([code, sev]) => [code, sev]));
const REQUIRED_SECTIONS = ['面试前', '面试', '覆盖核对', '面试后'];
const LEVELS = ['初级', '中级', '高级', '架构'];
const PLACEHOLDER_RE = /〔(待补充|待补|假设)[:：]/g;
const TODO_RE = /\b(TODO|TBD|FIXME)\b/;
const BARE_WAIT_RE = /待补(?!充)/;

const USAGE = `用法：
  node check-interview-doc.mjs <手册.md>...
  node check-interview-doc.mjs <手册.md> --strict
  node check-interview-doc.mjs --list-rules

退出码：0 通过 / 1 有阻断项 / 2 用法或读取错误`;

class Findings {
  constructor() {
    this.items = [];
  }

  add(code, file, line, message) {
    const severity = SEVERITY.get(code);
    if (!severity) throw new Error(`unknown rule: ${code}`);
    this.items.push({ code, severity, file, line, message });
  }

  countBy(sev) {
    return this.items.filter((i) => i.severity === sev).length;
  }
}

function listRules() {
  const width = Math.max(...RULES.map(([c]) => c.length));
  for (const [code, severity, text] of RULES) {
    console.log(`${code.padEnd(width)}  ${severity.padEnd(5)}  ${text}`);
  }
  console.log(`\n共 ${RULES.length} 条规则。error 阻断；warn 在 --strict 下阻断；note 只提示，永不阻断。`);
}

/** 标记代码围栏内部（含围栏行），围栏内的一切不参与结构解析。 */
function markCodeLines(lines) {
  const mask = new Array(lines.length).fill(false);
  let inFence = false;
  for (let i = 0; i < lines.length; i += 1) {
    if (/^\s*(```|~~~)/.test(lines[i])) {
      mask[i] = true;
      inFence = !inFence;
      continue;
    }
    mask[i] = inFence;
  }
  return mask;
}

function splitFrontMatter(lines) {
  if (lines.length === 0 || !/^<!--\s*resume-interview\s*$/.test(lines[0].trim())) {
    return { meta: null, metaEndLine: 0 };
  }
  const meta = new Map();
  for (let i = 1; i < lines.length; i += 1) {
    if (/^-->\s*$/.test(lines[i].trim())) return { meta, metaEndLine: i + 1 };
    const match = /^([A-Za-z][\w-]*)\s*[:：]\s*(.*)$/.exec(lines[i].trim());
    if (match) meta.set(match[1].toLowerCase(), match[2].trim());
  }
  return { meta, metaEndLine: 0 };
}

function parseSections(lines, codeMask) {
  const sections = [];
  for (let i = 0; i < lines.length; i += 1) {
    if (codeMask[i]) continue;
    const match = /^##\s+(.+?)\s*$/.exec(lines[i]);
    if (!match) continue;
    sections.push({ name: match[1], line: i + 1, start: i, end: lines.length });
  }
  for (let i = 0; i < sections.length - 1; i += 1) sections[i].end = sections[i + 1].start;
  return sections;
}

function sectionByName(sections, name) {
  return sections.find((s) => s.name === name) ?? null;
}

function parseFields(lines, from, to, codeMask) {
  const fields = new Map();
  let current = null;
  for (let i = from; i < to; i += 1) {
    if (codeMask[i]) continue;
    const raw = lines[i];
    const started = /^-\s+(?!★?\s*[4321]\s*[：:])([^：:]{1,24})[：:]\s*(.*)$/.exec(raw);
    if (started) {
      current = { key: started[1].trim(), line: i + 1, value: started[2] };
      fields.set(current.key, current);
      continue;
    }
    if (current && raw.trim() !== '') current.value += `\n${raw}`;
  }
  return fields;
}

function parseQuestions(lines, section, codeMask) {
  const hits = [];
  for (let i = section.start; i < section.end; i += 1) {
    if (codeMask[i]) continue;
    const match = /^###\s+Q(\d+)\b\s*(.*)$/.exec(lines[i]);
    if (match) hits.push({ num: Number(match[1]), title: match[2].trim(), line: i + 1, start: i });
  }
  for (let i = 0; i < hits.length; i += 1) {
    hits[i].end = i + 1 < hits.length ? hits[i + 1].start : section.end;
    hits[i].fields = parseFields(lines, hits[i].start + 1, hits[i].end, codeMask);
  }
  return hits;
}

/** 锚点必须按行写：`- ★ 3：…` / `- 4：…`，允许顶格或缩进。 */
function parseAnchors(text) {
  const anchors = [];
  for (const line of text.split('\n')) {
    const match = /^\s*[-*]\s*(★\s*)?([4321])\s*[：:]\s*(.*)$/.exec(line);
    if (match) anchors.push({ level: Number(match[2]), star: Boolean(match[1]), text: match[3] });
  }
  return anchors;
}

function checkMeta(findings, file, lines) {
  const { meta } = splitFrontMatter(lines);
  if (!meta) {
    findings.add('RI-META', file, 1, '缺元数据块（`<!-- resume-interview` … `-->`）');
    return { minutes: null, level: null, metaEndLine: 0 };
  }
  for (const key of ['candidate', 'minutes', 'date']) {
    if (!meta.get(key)) findings.add('RI-META', file, 1, `元数据缺 \`${key}\``);
  }
  const minutes = Number(meta.get('minutes'));
  if (meta.get('minutes') && (!Number.isFinite(minutes) || minutes <= 0 || minutes > 480)) {
    findings.add('RI-META', file, 1, `\`minutes\` 非法：${meta.get('minutes')}`);
  }
  if (meta.get('date') && !/^\d{4}-\d{2}-\d{2}$/.test(meta.get('date'))) {
    findings.add('RI-META', file, 1, `\`date\` 需为 YYYY-MM-DD：${meta.get('date')}`);
  }
  const level = meta.get('level');
  if (level && !LEVELS.includes(level)) {
    findings.add('RI-META', file, 1, `\`level\` 需为 ${LEVELS.join(' / ')}：${level}`);
  }
  return {
    minutes: Number.isFinite(minutes) && minutes > 0 && minutes <= 480 ? minutes : null,
    level: LEVELS.includes(level) ? level : null,
    metaEndLine: splitFrontMatter(lines).metaEndLine,
  };
}

function expectedStarLevel(level) {
  if (level === '高级' || level === '架构') return 4;
  if (level === '初级' || level === '中级') return 3;
  return null;
}

function checkQuestions(findings, file, questions, minutes, level) {
  let total = 0;
  const seen = new Set();
  const durations = new Map();
  for (const q of questions) {
    const id = `Q${q.num}`;
    if (seen.has(q.num)) findings.add('RI-DUP', file, q.line, `${id} 题号重复`);
    seen.add(q.num);
    if (!q.title) findings.add('RI-QTITLE', file, q.line, `${id} 缺标题`);

    const source = q.fields.get('题源');
    if (!source || !source.value.trim()) {
      findings.add('RI-EVIDENCE', file, q.line, `${id} 缺 \`题源\``);
    } else {
      if (!/[「“]/.test(source.value)) {
        findings.add('RI-EVIDENCE', file, source.line, `${id} 题源未用「」或“”引用简历原文（ASCII 引号不算）`);
      }
      if (!/—|——|\s-\s|·\s*项目/.test(source.value)) {
        findings.add('RI-EVIDENCE-LOC', file, source.line, `${id} 题源缺位置说明（\`— 项目 · 段落\`）`);
      }
    }

    if (!q.fields.get('考点')) findings.add('RI-POINT', file, q.line, `${id} 缺 \`考点\``);

    const timeField = q.fields.get('时长');
    const minutesMatch = timeField ? /(\d+(?:\.\d+)?)\s*分/.exec(timeField.value) : null;
    if (!timeField || !minutesMatch) {
      findings.add('RI-TIME-FIELD', file, q.line, `${id} 缺可解析的 \`时长：N 分钟\``);
    } else {
      durations.set(q.num, Number(minutesMatch[1]));
      total += Number(minutesMatch[1]);
    }

    const listen = q.fields.get('要听的点');
    if (!listen || !listen.value.trim()) {
      findings.add('RI-LISTEN', file, q.line, `${id} 缺 \`要听的点\``);
    } else {
      const anchors = parseAnchors(listen.value);
      const stars = anchors.filter((a) => a.star);
      if (stars.length === 0) findings.add('RI-STAR', file, listen.line, `${id} 要听的点缺 ★ 及格线`);
      if (stars.length > 1) findings.add('RI-STAR', file, listen.line, `${id} 要听的点有多处 ★`);
      const expected = expectedStarLevel(level);
      if (expected && stars.length === 1 && stars[0].level !== expected) {
        findings.add(
          'RI-STAR',
          file,
          listen.line,
          `${id} ★ 标在 ${stars[0].level} 档，与 meta.level（${level}，应标 ${expected}）不一致`,
        );
      }
      const missing = ['4', '3', '2', '1'].filter((lv) => !anchors.some((a) => String(a.level) === lv));
      if (missing.length) {
        findings.add('RI-LEVELS', file, listen.line, `${id} 要听的点缺 ${missing.join('/')} 档（须按行写「- N：」）`);
      }
    }

    const answer = q.fields.get('示范答案');
    if (!answer || !answer.value.trim()) {
      findings.add('RI-ANSWER', file, q.line, `${id} 缺 \`示范答案\``);
    } else if (answer.value.replace(/\s/g, '').length < 60) {
      findings.add('RI-ANSWER-SHORT', file, answer.line, `${id} 示范答案不足 60 字`);
    }

    if (!q.fields.get('危险信号')) findings.add('RI-FLAG', file, q.line, `${id} 缺 \`危险信号\``);
    if (!q.fields.get('追问')) findings.add('RI-FOLLOWUP', file, q.line, `${id} 无追问（可选）`);
  }

  if (questions.length) {
    const nums = questions.map((q) => q.num).sort((a, b) => a - b);
    for (let i = 1; i < nums.length; i += 1) {
      if (nums[i] !== nums[i - 1] + 1) {
        const line = questions.find((q) => q.num === nums[i])?.line ?? questions[0].line;
        findings.add('RI-GAP', file, line, `题号不连续：Q${nums[i - 1]} → Q${nums[i]}`);
        break;
      }
    }
  }

  if (minutes && total > 0) {
    if (total > minutes) {
      findings.add('RI-BUDGET', file, questions[0].line, `题目合计 ${total} 分钟 > 面试时长 ${minutes} 分钟`);
    } else if (total < minutes * 0.6) {
      findings.add('RI-BUDGET-LOW', file, questions[0].line, `题目合计 ${total} 分钟，不足 ${minutes} 分钟的 60%`);
    }
  }
  return { total, durations };
}

function checkSchedule(findings, file, lines, pre, questions, durations, minutes) {
  if (!pre) return;
  const preFields = parseFields(lines, pre.start + 1, pre.end, markCodeLines(lines));
  const schedule = preFields.get('时间表');
  if (!schedule) return;
  const pairs = [...schedule.value.matchAll(/Q(\d+)\s*(\d+)\s*[′'分]/g)];
  for (const [, num, mins] of pairs) {
    const q = Number(num);
    if (durations.has(q) && durations.get(q) !== Number(mins)) {
      findings.add('RI-BUDGET', file, schedule.line, `时间表写 Q${q} ${mins}′，题目时长写 ${durations.get(q)} 分钟`);
    }
  }
  const totalMatch = /合计\s*(\d+)\s*[′'分]/.exec(schedule.value);
  if (totalMatch && minutes && Number(totalMatch[1]) !== minutes) {
    findings.add('RI-BUDGET', file, schedule.line, `时间表合计 ${totalMatch[1]}′ ≠ meta.minutes ${minutes}`);
  }
}

function checkCoverage(findings, file, lines, section, questionNums) {
  if (!section) return;
  const rows = [];
  for (let i = section.start + 1; i < section.end; i += 1) {
    const line = lines[i].trim();
    if (!line.startsWith('|')) continue;
    const cells = line.replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
    if (cells.length < 2) continue;
    if (cells.every((c) => /^:?-{2,}:?$/.test(c))) continue;
    rows.push({ cells, line: i + 1 });
  }
  if (!rows.length) {
    findings.add('RI-COVERAGE', file, section.line, '覆盖核对没有数据行');
    return;
  }
  const headerIndex = rows[0].cells.findIndex((c) => /落到|对应|题号|问题|哪一问/.test(c));
  const targetIndex = headerIndex >= 0 ? headerIndex : rows[0].cells.length - 1;
  for (const row of rows.slice(1)) {
    const target = row.cells[targetIndex] ?? row.cells[row.cells.length - 1];
    const refs = [...target.matchAll(/Q(\d+)/g)].map((m) => Number(m[1]));
    if (refs.length === 0) {
      if (!/覆盖豁免[:：]/.test(target)) {
        findings.add('RI-COVERAGE-BARE', file, row.line, `覆盖行既无题号也无 \`覆盖豁免：\`：${target}`);
      }
      continue;
    }
    for (const ref of refs) {
      if (!questionNums.has(ref)) {
        findings.add('RI-COVERAGE-REF', file, row.line, `覆盖表引用 Q${ref}，但手册里没有这道题`);
      }
    }
  }
}

function checkAfter(findings, file, lines, section) {
  if (!section) return;
  const body = lines.slice(section.start + 1, section.end);
  const headerIndex = body.findIndex((l) => /^\|\s*维度\s*\|/.test(l.trim()));
  if (headerIndex === -1) {
    findings.add('RI-DIM', file, section.line, '「面试后」缺维度评分表');
  } else {
    const header = body[headerIndex];
    if (!/4/.test(header) || !/1/.test(header)) {
      findings.add('RI-DIM', file, section.line, '维度评分表缺 4 / 1 档列');
    }
  }
  if (!body.some((l) => /^-\s*判定.*[：:]/.test(l.trim()))) {
    findings.add('RI-VERDICT', file, section.line, '「面试后」缺 `判定：` 规则');
  }
}

function checkGlobal(findings, file, lines) {
  lines.forEach((line, index) => {
    if (TODO_RE.test(line) || BARE_WAIT_RE.test(line)) {
      findings.add('RI-TODO', file, index + 1, `残留未收口记号：${line.trim().slice(0, 60)}`);
    }
    const matches = line.match(PLACEHOLDER_RE);
    if (matches) {
      findings.add('RI-PLACEHOLDER', file, index + 1, `占位符 ${matches.length} 处：${line.trim().slice(0, 60)}`);
    }
  });
}

function checkFile(file, findings) {
  if (!existsSync(file)) {
    findings.add('RI-META', file, 1, '文件不存在');
    return false;
  }
  let text;
  try {
    text = readFileSync(file, 'utf8');
  } catch (error) {
    findings.add('RI-META', file, 1, `读取失败：${error.message}`);
    return false;
  }
  const lines = text.split(/\r?\n/);
  const codeMask = markCodeLines(lines);
  const { minutes, level, metaEndLine } = checkMeta(findings, file, lines);
  const sections = parseSections(lines, codeMask);

  const hasH1 = lines.slice(metaEndLine).some((l) => /^#\s+\S/.test(l.trim()));
  if (!hasH1) findings.add('RI-TITLE', file, 1, '缺 H1 标题');

  for (const name of REQUIRED_SECTIONS) {
    if (!sectionByName(sections, name)) {
      findings.add('RI-SECTION', file, 1, `缺 \`## ${name}\` 段落`);
    }
  }
  const positions = REQUIRED_SECTIONS.map((n) => sectionByName(sections, n)?.line ?? null);
  if (positions.every((p) => p !== null)) {
    for (let i = 1; i < positions.length; i += 1) {
      if (positions[i] < positions[i - 1]) {
        findings.add('RI-ORDER', file, positions[i], `段落顺序应为 ${REQUIRED_SECTIONS.join(' → ')}`);
        break;
      }
    }
  }

  const pre = sectionByName(sections, '面试前');
  if (pre) {
    const preFields = parseFields(lines, pre.start + 1, pre.end, codeMask);
    if (!preFields.get('画像')) findings.add('RI-PRE', file, pre.line, '「面试前」缺 `画像：`');
    if (!preFields.get('必须核实')) findings.add('RI-PRE', file, pre.line, '「面试前」缺 `必须核实：`');
    if (!preFields.get('时间表')) findings.add('RI-PRE-SOFT', file, pre.line, '「面试前」缺 `时间表：`');
  }

  const interview = sectionByName(sections, '面试');
  let questionNums = new Set();
  let durations = new Map();
  if (interview) {
    const questions = parseQuestions(lines, interview, codeMask);
    if (!questions.length) {
      findings.add('RI-QUESTION', file, interview.line, '「面试」段落里没有 `### Q<编号>` 题目');
    }
    questionNums = new Set(questions.map((q) => q.num));
    ({ durations } = checkQuestions(findings, file, questions, minutes, level));
    checkSchedule(findings, file, lines, pre, questions, durations, minutes);
  }

  checkCoverage(findings, file, lines, sectionByName(sections, '覆盖核对'), questionNums);
  checkAfter(findings, file, lines, sectionByName(sections, '面试后'));
  checkGlobal(findings, file, lines);
  return true;
}

function report(findings, fileCount, strict) {
  const order = { error: 0, warn: 1, note: 2 };
  findings.items.sort((a, b) => order[a.severity] - order[b.severity] || a.line - b.line);
  for (const item of findings.items) {
    console.log(`[${item.code}] ${item.file}:${item.line} ${item.message}`);
  }
  const errors = findings.countBy('error');
  const warns = findings.countBy('warn');
  const notes = findings.countBy('note');
  const blocked = errors + (strict ? warns : 0);
  console.log(
    `\n${blocked === 0 ? 'PASS' : 'FAIL'} — ${fileCount} 个文件，${errors} error / ${warns} warn / ${notes} note` +
      (strict ? '（--strict：warn 按 error 处理）' : ''),
  );
  if (blocked === 0 && notes > 0) console.log('note 不阻断：请在交付说明里说明占位符与假设。');
  return blocked === 0 ? 0 : 1;
}

function main() {
  const args = process.argv.slice(2);
  if (args.includes('--help') || args.includes('-h')) {
    console.log(USAGE);
    return 0;
  }
  if (args.includes('--list-rules')) {
    listRules();
    return 0;
  }

  const strict = args.includes('--strict');
  const files = args.filter((a) => !a.startsWith('-'));
  const unknown = args.filter((a) => a.startsWith('-') && a !== '--strict');
  if (unknown.length) {
    console.error(`未知参数：${unknown.join(' ')}\n\n${USAGE}`);
    return 2;
  }
  if (!files.length) {
    console.error(USAGE);
    return 2;
  }

  const findings = new Findings();
  let readFailure = false;
  for (const file of files) {
    if (!checkFile(file, findings)) readFailure = true;
  }
  const code = report(findings, files.length, strict);
  if (readFailure) {
    console.error('读取失败：文件不存在或不可读，按用法错误处理。');
    return 2;
  }
  return code;
}

process.exit(main());
