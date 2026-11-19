#!/usr/bin/env node
/**
 * verify-sources.mjs 回归测试。
 *
 * 断言：逐字命中通过、编造/篡改必须失败、省略写法按段核验、噪声只报近似、用法错误退出 2。
 * 跑法：node skills/resume-interview/scripts/tests/verify-sources-test.mjs
 */

import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, '..', 'verify-sources.mjs');
const TMP = mkdtempSync(join(tmpdir(), 'ri-src-'));

const RESUME = [
  '张三  后端工程师',
  '项目经历',
  '订单中台  2023.03-2023.09',
  '主导订单服务拆分，P99 下降 75%',
  '负责 Kafka 异步同步题目、知识点数据。',
].join('\n');

let pass = 0;
let fail = 0;
const failures = [];

function check(name, condition, detail = '') {
  if (condition) {
    pass += 1;
    console.log(`  ok   ${name}`);
  } else {
    fail += 1;
    failures.push(name);
    console.log(`  FAIL ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

let counter = 0;
function handbook(sources) {
  const body = sources
    .map((s, i) => `### Q${i + 1} 题目\n\n- 题源：${s}\n- 优先级：必问\n`)
    .join('\n');
  const file = join(TMP, `hb-${counter += 1}.md`);
  writeFileSync(file, `# 面试手册\n\n## 面试\n\n${body}`);
  return file;
}

const resumeFile = join(TMP, 'resume.txt');
writeFileSync(resumeFile, RESUME);

function run(file, resume = resumeFile) {
  const args = [SCRIPT, file];
  if (resume) args.push('--resume', resume);
  const r = spawnSync(process.execPath, args, { encoding: 'utf8' });
  return { status: r.status, out: `${r.stdout}${r.stderr}` };
}

console.log('题源核验');
{
  const r = run(handbook(['「主导订单服务拆分，P99 下降 75%」— 项目经历']));
  check('逐字命中通过', r.status === 0 && r.out.includes('逐字命中'), r.out.split('\n').pop());
}
{
  const r = run(handbook(['「主导订单服务拆分，P99 下降 90%」— 项目经历']));
  check('改数字必须失败', r.status === 1 && r.out.includes('[SRC-MISS]'), r.out);
}
{
  const r = run(handbook(['「我负责了整套交易系统的架构设计」— 项目经历']));
  check('编造的引文必须失败', r.status === 1 && r.out.includes('[SRC-MISS]'));
}
{
  const r = run(handbook(['「张三 ... 2023.03-2023.09」— 工作经历']));
  check('省略写法按段核验', r.status === 0, r.out.split('\n').pop());
}
{
  const r = run(handbook(['「主导订单服务X拆分，P99 下降 75%」— 项目经历']));
  check('插入一个噪声字只报近似', r.status === 0 && r.out.includes('[SRC-NEAR]'), r.out);
}
{
  const r = run(handbook(['没有引号的题源']));
  check('题源没有引文判失败', r.status === 1 && r.out.includes('[SRC-MISS]'));
}
{
  const r = run(handbook(['「主导订单服务拆分」']), null);
  check('缺 --resume 退出 2', r.status === 2);
}
{
  const r = run(handbook(['「主导订单服务拆分」']), join(TMP, 'nope.txt'));
  check('简历文件不存在退出 2', r.status === 2);
}

console.log(`\n${fail === 0 ? 'PASS' : 'FAIL'} — ${pass} 条断言通过，${fail} 条失败`);
process.exit(fail === 0 ? 0 : 1);
