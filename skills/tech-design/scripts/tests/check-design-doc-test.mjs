#!/usr/bin/env node
// check-design-doc-test.mjs —— tech-design 文档门禁的回归测试（零依赖）。
//
// 原则（与 project-wiki/scripts/tests/gates-regression.sh 一致）：
//   ① 合规文档必须通过；② **故意违规必须被拦住**；③ note 不阻断，--strict 下也不阻断。
// 用法：node skills/tech-design/scripts/tests/check-design-doc-test.mjs
// 退出码：0 全部通过 / 1 有断言失败。

import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const script = resolve(here, '..', 'check-design-doc.mjs');
const fixtures = join(here, 'fixtures');

const C = { reset: '\u001b[0m', red: '\u001b[31m', green: '\u001b[32m', dim: '\u001b[2m', bold: '\u001b[1m' };
let failures = 0;
let checks = 0;

function run(args) {
  const r = spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
  return { code: r.status, out: r.stdout || '', err: r.stderr || '' };
}

function ok(name, cond, detail = '') {
  checks += 1;
  if (cond) {
    console.log(`${C.green}✓${C.reset} ${name}`);
  } else {
    failures += 1;
    console.log(`${C.red}✗ ${name}${C.reset}${detail ? `\n    ${C.dim}${detail}${C.reset}` : ''}`);
  }
}

function expectTags(name, res, tags) {
  const missing = tags.filter((t) => !res.out.includes(t));
  ok(name, missing.length === 0, missing.length ? `未报出的 tag：${missing.join('、')}\n输出：\n${res.out}` : '');
}

const good = join(fixtures, 'good-full.md');
const bad = join(fixtures, 'bad-full.md');
const warnOnly = join(fixtures, 'warn-only.md');
const edgeOk = join(fixtures, 'edge-ok.md');
const edgeDdlType = join(fixtures, 'edge-ddl-type.md');
const edgeLogo = join(fixtures, 'edge-logo.md');
const edgeStandard = join(fixtures, 'edge-standard.md');

// ① 合规文档必须通过（含 --strict：note 永不参与失败判定）
{
  const r = run([good, '--tier', 'full']);
  ok('合规完整档通过', r.code === 0, r.out + r.err);
  ok('合规完整档无 error/warn 输出', !r.out.includes('✗ ') && !r.out.includes('! '), r.out);
  ok('合规完整档带 note 提示（不静默）', r.out.includes('TD-MARKER'), r.out);

  const strict = run([good, '--tier', 'full', '--strict']);
  ok('--strict 下 note 不阻断', strict.code === 0, strict.out + strict.err);
}

// ② 故意违规必须被拦住
{
  const r = run([bad, '--tier', 'full']);
  ok('违规文档退出码 1', r.code === 1, r.out);
  expectTags('违规文档报出全部 error 级 tag', r, [
    'TD-STATUS-BLOCK', 'TD-PLACEHOLDER', 'TD-NA', 'TD-OPTION', 'TD-TRACE',
  ]);
  expectTags('违规文档报出 warn 级 tag', r, [
    'TD-VAGUE', 'TD-GOAL-NO-NUMBER', 'TD-EMPTY-WORDS', 'TD-NUM-BASIS', 'TD-INTERNAL-REF',
    'TD-NO-DIAGRAM', 'TD-DDL-MISMATCH',
    'TD-TIER-STRUCTURE', 'TD-GOAL-ANTI', 'TD-SILENT-LIST', 'TD-KNOWN-GAP',
  ]);
}

// ③ 档位门禁：轻量档不要求追溯表
{
  const r = run([bad, '--tier', 'light', '--json']);
  ok('轻量档仍判失败（其它 error 存在）', r.code === 1, r.out);
  let parsed = null;
  try { parsed = JSON.parse(r.out); } catch { /* 下面断言会失败 */ }
  ok('--json 输出可解析', parsed !== null && Array.isArray(parsed.findings), r.out);
  ok('轻量档不要求 TD-TRACE', parsed && !parsed.findings.some((f) => f.code === 'TD-TRACE'), r.out);
}

// ④ --strict 只提升 warn
{
  const plain = run([warnOnly, '--tier', 'light']);
  ok('仅 warn 的文档默认通过', plain.code === 0, plain.out);
  const strict = run([warnOnly, '--tier', 'light', '--strict']);
  ok('同一文档 --strict 下失败', strict.code === 1, strict.out);
  expectTags('warn 文档报出形容词', plain, ['TD-VAGUE']);
  expectTags('图引用不存在被报出', plain, ['TD-ASSET-MISSING']);
}

// ⑤ 档位推断（不传 --tier 时按结构判；标准档不得被误判为完整档）
{
  const r = run([good]);
  ok('完整档结构可被推断（追溯表仍校验）', r.code === 0 && r.out.includes('推断为「full」'), r.out + r.err);
}

// ⑥ 用法与目标错误
{
  const noArg = run([]);
  ok('无参数退出码 2', noArg.code === 2, noArg.out + noArg.err);

  const badTier = run([good, '--tier', 'huge']);
  ok('非法 --tier 退出码 2', badTier.code === 2, badTier.out + badTier.err);

  const unknown = run([good, '--nope']);
  ok('未知参数退出码 2', unknown.code === 2, unknown.out + unknown.err);

  const missing = run([join(fixtures, 'not-exist.md')]);
  ok('目标不存在退出码 1', missing.code === 1, missing.out);
  expectTags('目标不存在报 TD-TARGET-MISSING', missing, ['TD-TARGET-MISSING']);

  const missingUpstream = run([good, '--upstream', join(fixtures, 'not-exist-prd.md')]);
  ok('--upstream 不存在退出码 2', missingUpstream.code === 2, missingUpstream.out + missingUpstream.err);
}

// ⑦ --upstream 编号对账
{
  const prd = join(fixtures, 'upstream-prd.md');
  const r = run([good, '--tier', 'full', '--upstream', prd]);
  ok('承接需求编号能对上上游', r.code === 0 && !r.out.includes('TD-TRACE-UPSTREAM'), r.out);

  const drift = join(fixtures, 'upstream-prd-drift.md');
  const d = run([good, '--tier', 'full', '--upstream', drift]);
  ok('上游编号漂移被检出（warn，不判失败）', d.code === 0 && d.out.includes('TD-TRACE-UPSTREAM'), d.out);
}

// ⑧ JSON 汇总与明细一致
{
  const r = run([bad, '--tier', 'full', '--json']);
  const p = JSON.parse(r.out);
  const count = (lv) => p.findings.filter((f) => f.level === lv).length;
  ok('JSON summary 与 findings 一致',
    p.summary.error === count('error') && p.summary.warn === count('warn') && p.summary.note === count('note'),
    r.out);
}

// ⑨ 未定记号可收口到「假设与约束」；验收百分比不该被当成性能缺口径
{
  const f = join(fixtures, 'light-assumption.md');
  const r = run([f, '--tier', 'light']);
  ok('轻量档示例通过（无 error 无 warn）', r.code === 0 && !r.out.includes('✗ ') && !r.out.includes('! '), r.out);
  ok('记号收口到「假设与约束」不报未收口', !r.out.includes('TD-MARKER-UNCOLLECTED'), r.out);
  ok('验收百分比不误判为「数字缺口径」', !r.out.includes('TD-NUM-BASIS'), r.out);
}

// ⑪ 修复回归：档位误判 / DDL 属性 / 标题形容词误伤 / 内部引用误伤 / 选项同义词 / 多行状态块 / 装饰图
{
  const std = run([edgeStandard]);
  ok('标准档不再被误判为完整档', std.out.includes('推断为「standard」') && !std.out.includes('推断为「full」'), std.out);

  const light = run([join(fixtures, 'light-assumption.md')]);
  ok('轻量档可被推断为 light', light.out.includes('推断为「light」'), light.out);

  const edge = run([edgeOk, '--tier', 'light', '--json']);
  let codes = [];
  try { codes = JSON.parse(edge.out).findings.map((f) => f.code); } catch { /* 断言会失败 */ }
  ok('多行状态块不再误报 TD-STATUS-BLOCK', !codes.includes('TD-STATUS-BLOCK'), edge.out);
  ok('「保持当前实现不动」算不作为基线（不报 TD-OPTION）', !codes.includes('TD-OPTION'), edge.out);
  ok('仓库自有 data-model.md 不再误报 TD-INTERNAL-REF', !codes.includes('TD-INTERNAL-REF'), edge.out);
  ok('结构标题「高可用设计」不再误报 TD-VAGUE', !codes.includes('TD-VAGUE'), edge.out);

  const ddl = run([edgeDdlType, '--tier', 'light']);
  ok('DDL 类型不一致被检出', ddl.out.includes('TD-DDL-MISMATCH') && ddl.out.includes('类型'), ddl.out);

  const logo = run([edgeLogo, '--tier', 'standard']);
  ok('装饰性 logo 不当作架构图', logo.out.includes('TD-NO-DIAGRAM'), logo.out);
}

// ⑩ 规则清单是唯一真源：--list-rules 与源码里 report() 的码一一对应
{
  const r = run(['--list-rules']);
  ok('--list-rules 退出码 0', r.code === 0, r.out + r.err);

  const listed = r.out.trim().split('\n').filter(Boolean).map((l) => l.split('\t')[0]);
  ok('--list-rules 输出 ≥20 条且含关键码',
    listed.length >= 20
      && ['TD-STATUS-BLOCK', 'TD-OPTION', 'TD-TRACE', 'TD-NO-DIAGRAM', 'TD-ASSET-MISSING', 'TD-INTERNAL-REF']
        .every((c) => listed.includes(c)),
    r.out);

  const src = readFileSync(script, 'utf8');
  const used = [...new Set(
    [...src.matchAll(/report\('(?:error|warn|note)',\s*'([A-Z-]+)'/g)].map((m) => m[1]),
  )].sort();
  const listedSet = [...new Set(listed)].sort();
  ok('规则清单覆盖源码全部 report() 码（无漏列/多列）',
    used.length === listedSet.length && used.every((c, i) => c === listedSet[i]),
    `源码用：${used.join(',')}\n清单：${listedSet.join(',')}`);
}

// ⑫ 配图：轻量档不再跳过；按章节查（一张图不能放行全篇）；图豁免可显式收口
{
  const ddl = run([edgeDdlType, '--tier', 'light', '--json']);
  let ddlCodes = [];
  try { ddlCodes = JSON.parse(ddl.out).findings.map((f) => f.code); } catch { /* 断言会失败 */ }
  ok('轻量档也要求数据模型配图', ddlCodes.includes('TD-NO-DIAGRAM'), ddl.out);

  const partial = run([join(fixtures, 'diagram-partial.md'), '--tier', 'light', '--json']);
  let pf = [];
  try { pf = JSON.parse(partial.out).findings.filter((f) => f.code === 'TD-NO-DIAGRAM'); } catch { /* 断言会失败 */ }
  ok('按章节查图：总体架构缺图仍报出，不因其它章节有图而放行',
    pf.length === 1 && pf[0].msg.includes('总体架构'), partial.out);

  const exempt = run([join(fixtures, 'diagram-exempt.md'), '--tier', 'light', '--json']);
  let ef = [];
  try { ef = JSON.parse(exempt.out).findings.filter((f) => f.code === 'TD-NO-DIAGRAM'); } catch { /* 断言会失败 */ }
  ok('「图豁免：理由」可显式收口，不静默放过', ef.length === 0, exempt.out);

  const std = run([edgeStandard, '--tier', 'standard', '--json']);
  let stdCodes = [];
  try { stdCodes = JSON.parse(std.out).findings.map((f) => f.code); } catch { /* 断言会失败 */ }
  ok('标准档低于最小图集报 TD-DIAGRAM-MIN', stdCodes.includes('TD-DIAGRAM-MIN'), std.out);
}

// ⑬ 挑战点：缺失与超量都要报（收敛器是硬要求，不是可选章节）
{
  const miss = run([join(fixtures, 'challenge-missing.md'), '--tier', 'light', '--json']);
  let missCodes = [];
  try { missCodes = JSON.parse(miss.out).findings.map((f) => f.code); } catch { /* 断言会失败 */ }
  ok('缺「挑战点」章节被检出', missCodes.includes('TD-CHALLENGE'), miss.out);

  const over = run([join(fixtures, 'challenge-overflow.md'), '--tier', 'light', '--json']);
  let overFindings = [];
  try { overFindings = JSON.parse(over.out).findings.filter((f) => f.code === 'TD-CHALLENGE'); } catch { /* 断言会失败 */ }
  ok('挑战点超过 3 条被检出', overFindings.length === 1 && /超过 3 条/.test(overFindings[0].msg), over.out);
}

// ⑭ 章节豁免：与「图豁免」同一约定——写理由才算收口，抄占位符不算
{
  const r = run([join(fixtures, 'section-exempt.md'), '--tier', 'full', '--json']);
  let codes = [];
  try { codes = JSON.parse(r.out).findings.map((f) => f.code); } catch { /* 断言会失败 */ }
  ok('「章节豁免：<理由>」能收口完整档必备章节', !codes.includes('TD-TIER-STRUCTURE'), r.out);
  ok('「章节豁免：<理由>」能收口沉默清单 / 已知未覆盖',
    !codes.includes('TD-SILENT-LIST') && !codes.includes('TD-KNOWN-GAP'), r.out);

  const ph = run([join(fixtures, 'section-exempt-placeholder.md'), '--tier', 'full', '--json']);
  let phCodes = [];
  try { phCodes = JSON.parse(ph.out).findings.map((f) => f.code); } catch { /* 断言会失败 */ }
  ok('豁免理由原样抄占位符不算收口', phCodes.includes('TD-TIER-STRUCTURE'), ph.out);
}

// ⑮ 追溯表「挑战点」列：强制列 + 双向核对（引用未声明 / 空 / 孤儿挑战点）
{
  const miss = run([join(fixtures, 'trace-challenge-missing.md'), '--tier', 'standard', '--json']);
  let missFindings = [];
  try { missFindings = JSON.parse(miss.out).findings.filter((f) => f.code === 'TD-TRACE-CHALLENGE'); } catch { /* 断言会失败 */ }
  ok('追溯表缺「挑战点」列被检出', missFindings.length === 1 && /缺「挑战点」列/.test(missFindings[0].msg), miss.out);

  const bad = run([join(fixtures, 'trace-challenge-bad.md'), '--tier', 'standard', '--json']);
  let badMsgs = [];
  try {
    badMsgs = JSON.parse(bad.out).findings.filter((f) => f.code === 'TD-TRACE-CHALLENGE').map((f) => f.msg);
  } catch { /* 断言会失败 */ }
  const joined = badMsgs.join('\n');
  ok('追溯表引用未声明的挑战点编号被检出', /C3/.test(joined) && /没有这个编号/.test(joined), bad.out);
  ok('追溯表挑战点列为空被检出', /为空/.test(joined), bad.out);
  ok('孤儿挑战点（无决策承接）被检出', /孤儿挑战点/.test(joined), bad.out);
}

// ⑯ 挑战点：豁免 / 嵌套不误报 / 编号超量
{
  const ex = run([join(fixtures, 'challenge-exempt.md'), '--tier', 'light', '--json']);
  let codes = [];
  try { codes = JSON.parse(ex.out).findings.map((f) => f.code); } catch { /* 断言会失败 */ }
  ok('「挑战点豁免：<理由>」可收口缺失章节', !codes.includes('TD-CHALLENGE'), ex.out);

  const nested = run([join(fixtures, 'challenge-nested.md'), '--tier', 'light', '--json']);
  let nf = [];
  try { nf = JSON.parse(nested.out).findings.filter((f) => f.code === 'TD-CHALLENGE'); } catch { /* 断言会失败 */ }
  ok('嵌套子项与「其余按标准做法」清单不算超量', nf.length === 0, nested.out);

  const ids = run([join(fixtures, 'challenge-overflow-ids.md'), '--tier', 'light', '--json']);
  let idf = [];
  try { idf = JSON.parse(ids.out).findings.filter((f) => f.code === 'TD-CHALLENGE'); } catch { /* 断言会失败 */ }
  ok('C 编号写法的挑战点超量被检出', idf.length === 1 && /超过 3 条/.test(idf[0].msg), ids.out);
}

// ⑰ 追溯表边界：正文 / fence 里的 C4 不算声明、多表都查、未编号只 warn
{
  const edge = run([join(fixtures, 'trace-challenge-edge.md'), '--tier', 'standard', '--json']);
  let codes = [];
  try { codes = JSON.parse(edge.out).findings.map((f) => f.code); } catch { /* 断言会失败 */ }
  ok('正文「C4 模型」与 fence 内 C4 不误判为挑战点',
    !codes.includes('TD-TRACE-CHALLENGE') && !codes.includes('TD-CHALLENGE'), edge.out);

  const second = run([join(fixtures, 'trace-challenge-second.md'), '--tier', 'standard', '--json']);
  let sm = [];
  try { sm = JSON.parse(second.out).findings.filter((f) => f.code === 'TD-TRACE-CHALLENGE').map((f) => f.msg); } catch { /* 断言会失败 */ }
  ok('第二张追溯表的空挑战点也被检出', sm.some((m) => /为空/.test(m)), second.out);

  const un = run([join(fixtures, 'challenge-unnumbered.md'), '--tier', 'standard', '--json']);
  let ucodes = [];
  let um = [];
  try {
    const p = JSON.parse(un.out).findings;
    ucodes = p.map((f) => f.code);
    um = p.filter((f) => f.code === 'TD-CHALLENGE').map((f) => f.msg);
  } catch { /* 断言会失败 */ }
  ok('挑战点未编号是 warn 且不触发追溯表 error',
    um.some((m) => /没有编号/.test(m)) && !ucodes.includes('TD-TRACE-CHALLENGE'), un.out);
}

// ⑱ 章节豁免：类目不因理由文本越界，敷衍理由不算收口
{
  const scope = run([join(fixtures, 'section-exempt-scope.md'), '--tier', 'full', '--json']);
  let tf = [];
  try { tf = JSON.parse(scope.out).findings.filter((f) => f.code === 'TD-TIER-STRUCTURE').map((f) => f.msg); } catch { /* 断言会失败 */ }
  ok('豁免理由里的「监控」不会连带豁免可观测性',
    tf.length === 1 && /可观测性设计/.test(tf[0]) && !/安全设计/.test(tf[0]), scope.out);

  const lazy = run([join(fixtures, 'section-exempt-lazy.md'), '--tier', 'full', '--json']);
  let lf = [];
  try { lf = JSON.parse(lazy.out).findings.filter((f) => f.code === 'TD-TIER-STRUCTURE').map((f) => f.msg); } catch { /* 断言会失败 */ }
  ok('「章节豁免：成本分析 无」不算有效收口', lf.some((m) => /成本分析/.test(m)), lazy.out);
}

// ———————————————————————————— 汇总 ————————————————————————————

if (failures) {
  console.log(`\n${C.bold}${C.red}${failures}/${checks} 条断言失败${C.reset}`);
  process.exit(1);
}
console.log(`\n${C.green}全部 ${checks} 条断言通过${C.reset}`);
