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

// ———————————————————————————— 汇总 ————————————————————————————

if (failures) {
  console.log(`\n${C.bold}${C.red}${failures}/${checks} 条断言失败${C.reset}`);
  process.exit(1);
}
console.log(`\n${C.green}全部 ${checks} 条断言通过${C.reset}`);
