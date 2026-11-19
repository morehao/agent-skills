#!/usr/bin/env node
/**
 * check-interview-doc.mjs 回归测试。
 *
 * 断言四类：合规文档必须通过（含合规变体）、故意违规必须被拦住、软项按严重度分档、note 永不阻断。
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
  return { status: result.status, out: `${result.stdout}${result.stderr}` };
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

console.log('合规文档与合规变体');
{
  const r = run(GOOD, ['--strict']);
  check('good.md 严格模式通过', r.status === 0 && r.out.includes('PASS'), r.out.split('\n').pop());
}
{
  const r = run(GOOD);
  check('good.md 默认模式 0 note', r.status === 0 && r.out.includes('0 note'));
}
{
  const r = run(GOOD.replace(/^  - /gm, '- '));
  check('锚点顶格写也算合规', r.status === 0, r.out.split('\n').pop());
}
{
  const r = run(GOOD.replace(/「主导订单服务拆分，P99 下降 75%」/, '“主导订单服务拆分，P99 下降 75%”'));
  check('中文弯引号可作题源引号', r.status === 0);
}
{
  const r = run(`${GOOD.replace('# 面试手册：', '说明行\n'.repeat(11) + '# 面试手册：')}`);
  check('H1 在元数据 + 11 行之后仍能识别', r.status === 0, r.out.split('\n').pop());
}
{
  const r = run(GOOD.replace('| 简历里的技能 / 项目 | 落到哪一问 |', '| 简历里的技能 / 项目 | 对应问题 | 备注 |').replace(
    /^\| (?!简历里的)(.+?) \| (Q\d+(?:、Q\d+)*|覆盖豁免.+?) \|$/gm,
    '| $1 | $2 | — |',
  ));
  check('覆盖表三列 + 自定义表头仍合规', r.status === 0, r.out.split('\n').pop());
}
{
  const fenced = GOOD.replace('## 面试\n', '## 面试\n\n```markdown\n## 教育背景（示例，不应影响解析）\n```\n');
  const r = run(fenced);
  check('围栏里的 ## 不截断段落', r.status === 0, r.out.split('\n').pop());
}

console.log('\n围栏与解析边界');
expect(
  '题目只写在围栏里不算题目',
  GOOD.replace(/### Q1[\s\S]*?(?=## 覆盖核对)/, '```markdown\n### Q1 假题目\n- 题源：「x」— y\n```\n\n'),
  [],
  1,
  ['RI-QUESTION'],
);

console.log('\n结构缺失');
expect('缺元数据块', GOOD.replace(/<!-- resume-interview[\s\S]*?-->\n\n/, ''), [], 1, ['RI-META']);
expect('元数据缺 minutes', GOOD.replace('minutes: 60', 'minutes: 未定'), [], 1, ['RI-META']);
expect('元数据 level 非法', GOOD.replace('level: 中级', 'level: 资深'), [], 1, ['RI-META']);
expect('缺「面试后」段落', GOOD.split('## 面试后')[0], [], 1, ['RI-SECTION']);
expect('没有任何题目', GOOD.replace(/### Q\d[\s\S]*?(?=## 覆盖核对)/, ''), [], 1, ['RI-QUESTION', 'RI-COVERAGE-REF']);
expect(
  '段落顺序颠倒',
  GOOD.replace('## 面试前', '## 占位前').replace('## 面试后', '## 面试前').replace('## 占位前', '## 面试后'),
  [],
  1,
  ['RI-ORDER'],
);
expect('缺「必须核实」', GOOD.replace(/^- 必须核实：.*$/m, ''), [], 1, ['RI-PRE']);
expect('缺 H1 只记 warn', GOOD.replace('# 面试手册：张三 · 后端工程师\n', ''), [], 0, ['RI-TITLE']);
expect('缺 H1 在 --strict 下阻断', GOOD.replace('# 面试手册：张三 · 后端工程师\n', ''), ['--strict'], 1, ['RI-TITLE']);
expect('缺「时间表」只记 warn', GOOD.replace(/^- 时间表：.*$/m, ''), [], 0, ['RI-PRE-SOFT']);
expect('题号不连续只记 warn', GOOD.replace('### Q2 Kafka', '### Q7 Kafka'), [], 1, ['RI-GAP']);

console.log('\n题目必填项');
expect('题源缺失', GOOD.replace(/^- 题源：.*$/m, ''), [], 1, ['RI-EVIDENCE']);
expect('题源用 ASCII 引号', GOOD.replace('「主导订单服务拆分，P99 下降 75%」', '"主导订单服务拆分"'), [], 1, ['RI-EVIDENCE']);
expect('题源缺位置说明只记 warn', GOOD.replace('」— 项目经历 · 订单中台（2023.03–2023.09）', '」'), [], 0, ['RI-EVIDENCE-LOC']);
expect('缺考点只记 warn', GOOD.replace(/^- 考点：.*$/m, ''), [], 0, ['RI-POINT']);
expect('缺 ★ 及格线', GOOD.replace('- ★ 3：', '- 3：'), [], 1, ['RI-STAR']);
expect('★ 标错档（中级应标 3）', GOOD.replace('- ★ 3：', '- ★ 4：').replace('- 4：', '- 3：'), [], 1, ['RI-STAR']);
expect('同一题两个 ★', GOOD.replace('- 4：', '- ★ 4：'), [], 1, ['RI-STAR']);
expect('缺 2 档锚点', GOOD.replace(/^\s*- 2：.*$/m, ''), [], 0, ['RI-LEVELS']);
expect('缺 2 档锚点在 --strict 下阻断', GOOD.replace(/^\s*- 2：.*$/m, ''), ['--strict'], 1, ['RI-LEVELS']);
expect(
  '单行写比例不算四档',
  GOOD.replace(/(^- 要听的点：[\s\S]*?)(?=^- 示范答案：)/m, '- 要听的点：★ 口径 4:3 与 3:1、2:1、1:1\n'),
  [],
  1,
  ['RI-LEVELS', 'RI-STAR'],
);
expect('缺要听的点', GOOD.replace(/(^- 要听的点：[\s\S]*?)(?=^- 示范答案：)/m, ''), [], 1, ['RI-LISTEN']);
expect('缺示范答案', GOOD.replace(/^- 示范答案：.*$/m, ''), [], 1, ['RI-ANSWER']);
expect('示范答案过短', GOOD.replace(/^- 示范答案：.*$/m, '- 示范答案：不知道。'), [], 0, ['RI-ANSWER-SHORT']);
expect('缺危险信号只记 warn', GOOD.replace(/^- 危险信号：.*$/m, ''), [], 0, ['RI-FLAG']);
expect('缺追问只记 note', GOOD.replace(/^- 追问：.*$/m, ''), [], 0, ['RI-FOLLOWUP']);
expect('题号重复', GOOD.replace('### Q3 P99', '### Q1 P99'), [], 1, ['RI-DUP']);
expect('时长无法解析', GOOD.replace('- 时长：18 分钟', '- 时长：看情况'), [], 1, ['RI-TIME-FIELD']);

console.log('\n预算、时间表与覆盖');
expect('题目超时', GOOD.replace('- 时长：18 分钟', '- 时长：40 分钟'), [], 1, ['RI-BUDGET']);
expect(
  '时长合计不足 60%',
  GOOD.replace(/- 时长：\d+ 分钟/g, '- 时长：5 分钟').replace(/^- 时间表：.*$/m, ''),
  [],
  0,
  ['RI-BUDGET-LOW'],
);
expect('时间表与题目时长不一致', GOOD.replace('- 时长：12 分钟', '- 时长：15 分钟'), [], 1, ['RI-BUDGET']);
expect(
  '覆盖表引用不存在的题号',
  GOOD.replace('| 订单中台（拆分、P99） | Q1、Q3 |', '| 订单中台（拆分、P99） | Q1、Q9 |'),
  [],
  1,
  ['RI-COVERAGE-REF'],
);
expect('覆盖行无题号也无豁免', GOOD.replace('| 团队管理 | 覆盖豁免：简历无带人经历，不编题 |', '| 团队管理 | — |'), [], 0, ['RI-COVERAGE-BARE']);
expect('覆盖核对无数据行', GOOD.replace(/\| 简历里的技能[\s\S]*?(?=## 面试后)/, '只有一句话，没有表。\n\n'), [], 1, ['RI-COVERAGE']);
expect('缺维度评分表只记 warn', GOOD.replace(/^\| 维度 \|.*$/gm, ''), [], 0, ['RI-DIM']);
expect('缺判定规则只记 warn', GOOD.replace(/^- 判定：.*$/m, ''), [], 0, ['RI-VERDICT']);

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
  const lines = r.stdout.split('\n').filter((l) => /^RI-[A-Z-]+\s+(error|warn|note)\s/.test(l));
  check('--list-rules 列全 30 条且带严重度', r.status === 0 && lines.length === 30, `实际 ${lines.length} 条`);
}
{
  const r = spawnSync(process.execPath, [SCRIPT], { encoding: 'utf8' });
  check('无参数退出 2', r.status === 2);
}
{
  const good = join(TMP, 'good-for-missing.md');
  writeFileSync(good, GOOD);
  const r = spawnSync(process.execPath, [SCRIPT, good, join(TMP, 'nope.md')], { encoding: 'utf8' });
  check('文件不存在退出 2 且有输出', r.status === 2 && r.stdout.includes('[RI-META]'), 'stdout 为空');
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
