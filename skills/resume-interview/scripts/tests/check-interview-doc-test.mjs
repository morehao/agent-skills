#!/usr/bin/env node
/**
 * check-interview-doc.mjs 回归测试。
 *
 * 断言三类：合规文档必须通过、故意违规必须被拦住、note 永不阻断。
 * 跑法：node skills/resume-interview/scripts/tests/check-interview-doc-test.mjs
 * 退出码：0 全通过 / 1 有断言失败。
 */

import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, '..', 'check-interview-doc.mjs');
const GOOD = readFileSync(join(HERE, 'fixtures', 'good.md'), 'utf8');
const TMP = mkdtempSync(join(tmpdir(), 'ri-gate-'));

let pass = 0;
let fail = 0;
const failures = [];

function check(name, condition, detail = '') {
  if (condition) {
    pass += 1;
    console.log(`  ok   ${name}`);
  } else {
    fail += 1;
    failures.push(`${name}${detail ? ` — ${detail}` : ''}`);
    console.log(`  FAIL ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

let counter = 0;
function run(content, flags = []) {
  const file = join(TMP, `doc-${counter += 1}.md`);
  writeFileSync(file, content);
  const result = spawnSync(process.execPath, [SCRIPT, file, ...flags], { encoding: 'utf8' });
  return { status: result.status, out: `${result.stdout}${result.stderr}`, file };
}

function expect(name, content, flags, status, codes) {
  const result = run(content, flags);
  const missing = codes.filter((code) => !result.out.includes(`[${code}]`));
  check(
    `${name}（退出码 ${status}）`,
    result.status === status && missing.length === 0,
    missing.length ? `缺 ${missing.join(',')}；实际退出码 ${result.status}` : '',
  );
  return result;
}

console.log('合规文档');
{
  const r = run(GOOD, ['--strict']);
  check('good.md 严格模式通过', r.status === 0 && r.out.includes('PASS'), r.out.split('\n').pop());
}
{
  const r = run(GOOD);
  check('good.md 默认模式通过且 0 note', r.status === 0 && r.out.includes('0 note'));
}

console.log('\n结构缺失');
expect('缺元数据块', GOOD.replace(/<!-- resume-interview[\s\S]*?-->\n\n/, ''), [], 1, ['RI-META']);
expect('元数据缺 minutes', GOOD.replace('minutes: 60', 'minutes: 未定'), [], 1, ['RI-META']);
expect('缺「面试后」段落', GOOD.split('## 面试后')[0], [], 1, ['RI-SECTION']);
expect('没有任何题目', GOOD.replace(/### Q\d[\s\S]*?(?=## 覆盖核对)/, ''), [], 1, ['RI-QUESTION', 'RI-COVERAGE-REF']);
expect(
  '段落顺序颠倒',
  GOOD.replace('## 面试前', '## 占位前').replace('## 面试后', '## 面试前').replace('## 占位前', '## 面试后'),
  [],
  1,
  ['RI-ORDER'],
);
expect(
  '缺「必须核实」',
  GOOD.replace(/^- 必须核实：.*$/m, ''),
  [],
  1,
  ['RI-PRE'],
);

console.log('\n题目必填项');
expect(
  '题源缺失',
  GOOD.replace(/^- 题源：.*$/m, ''),
  [],
  1,
  ['RI-EVIDENCE'],
);
expect(
  '题源没有原文引用',
  GOOD.replace('「主导订单服务拆分，P99 下降 75%」', '主导订单服务拆分'),
  [],
  1,
  ['RI-EVIDENCE'],
);
expect(
  '缺 ★ 及格线',
  GOOD.replace('★ 4：', '4：'),
  [],
  1,
  ['RI-STAR'],
);
expect(
  '缺 3 档锚点',
  GOOD.replace(/^  - 3：.*$/m, ''),
  [],
  0,
  ['RI-LEVELS'],
);
expect(
  '缺 3 档锚点在 --strict 下阻断',
  GOOD.replace(/^  - 3：.*$/m, ''),
  ['--strict'],
  1,
  ['RI-LEVELS'],
);
expect(
  '缺示范答案',
  GOOD.replace(/^- 示范答案：.*$/m, ''),
  [],
  1,
  ['RI-ANSWER'],
);
expect(
  '示范答案过短',
  GOOD.replace(/^- 示范答案：.*$/m, '- 示范答案：不知道。'),
  [],
  0,
  ['RI-ANSWER-SHORT'],
);
expect(
  '缺危险信号只记 warn',
  GOOD.replace(/^- 危险信号：.*$/m, ''),
  [],
  0,
  ['RI-FLAG'],
);
expect(
  '缺追问只记 note',
  GOOD.replace(/^- 追问：.*$/m, ''),
  [],
  0,
  ['RI-FOLLOWUP'],
);
expect(
  '题号重复',
  GOOD.replace('### Q3 P99 数字是怎么测出来的', '### Q2 P99 数字是怎么测出来的'),
  [],
  1,
  ['RI-DUP'],
);

console.log('\n预算与覆盖');
expect(
  '题目超时',
  GOOD.replace('- 时长：18 分钟', '- 时长：40 分钟'),
  [],
  1,
  ['RI-BUDGET'],
);
expect(
  '覆盖表引用不存在的题号',
  GOOD.replace('| 订单中台（拆分、P99） | Q1、Q3 |', '| 订单中台（拆分、P99） | Q1、Q9 |'),
  [],
  1,
  ['RI-COVERAGE-REF'],
);
expect(
  '覆盖行既不落题号也无豁免',
  GOOD.replace('| 团队管理 | 覆盖豁免：简历无带人经历，不编题 |', '| 团队管理 | — |'),
  [],
  0,
  ['RI-COVERAGE-BARE'],
);
expect(
  '覆盖核对无数据行',
  GOOD.replace(/\| 简历里的技能[\s\S]*?(?=## 面试后)/, '只有一句话，没有表。\n\n'),
  [],
  1,
  ['RI-COVERAGE'],
);

console.log('\n未收口记号与占位符');
expect('残留 TODO', `${GOOD}\nTODO: 补上面试官的维度权重\n`, [], 1, ['RI-TODO']);
expect('裸「待补」', `${GOOD}\n- 备注：结论待补\n`, [], 1, ['RI-TODO']);
{
  const r = run(GOOD.replace('压测峰值是 2000 QPS。', '压测峰值是 2000 QPS。〔待补充：线上真实峰值〕'));
  check('占位符只记 note 且不阻断', r.status === 0 && r.out.includes('[RI-PLACEHOLDER]') && r.out.includes('PASS'));
}
{
  const r = run(GOOD.replace('压测峰值是 2000 QPS。', '压测峰值是 2000 QPS。〔待补充：线上真实峰值〕'), ['--strict']);
  check('占位符在 --strict 下仍不阻断', r.status === 0);
}

console.log('\n命令行契约');
{
  const r = spawnSync(process.execPath, [SCRIPT, '--list-rules'], { encoding: 'utf8' });
  check('--list-rules 列出规则且退出 0', r.status === 0 && r.stdout.includes('RI-EVIDENCE'));
}
{
  const r = spawnSync(process.execPath, [SCRIPT], { encoding: 'utf8' });
  check('无参数退出 2', r.status === 2);
}
{
  const r = spawnSync(process.execPath, [SCRIPT, join(TMP, 'nope.md')], { encoding: 'utf8' });
  check('文件不存在退出 2', r.status === 2);
}
{
  const r = spawnSync(process.execPath, [SCRIPT, join(TMP, 'missing.md'), '--bogus'], { encoding: 'utf8' });
  check('未知参数退出 2', r.status === 2);
}

console.log(`\n${fail === 0 ? 'PASS' : 'FAIL'} — ${pass} 条断言通过，${fail} 条失败`);
if (fail) {
  for (const f of failures) console.log(`  - ${f}`);
}
process.exit(fail === 0 ? 0 : 1);
