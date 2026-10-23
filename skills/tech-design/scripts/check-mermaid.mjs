#!/usr/bin/env node
// check-mermaid.mjs —— tech-design 的 Mermaid 校验入口（薄壳）
//
// 用法：
//   node check-mermaid.mjs <file.md> [file2.md ...]
//   # 未传参数时从 stdin 读入
//
// 职责：定位并转调 project-insight/scripts/check-mermaid.mjs（同一套
// mermaid + jsdom 引擎，单一真源，避免重复维护解析/垫片逻辑）。该校验器对
// 任意 Markdown 中的 mermaid 代码块做 parse（flowchart 额外 render）校验，
// 任一失败以非 0 退出码结束并打印 [MERMAID-ERROR]。
//
// 依赖：skills/project-insight/scripts/ 下需已执行过 npm install
// （node_modules 不入库）。若用 cp -r 复制注册，需在副本对应目录重装。

import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const skillRoot = resolve(here, '..'); // skills/<本skill>
const skillsRoot = resolve(skillRoot, '..');
const targetScript = join(skillsRoot, 'project-insight', 'scripts', 'check-mermaid.mjs');
const depsDir = join(skillsRoot, 'project-insight', 'scripts', 'node_modules');

if (!existsSync(targetScript)) {
  console.error(`[依赖缺失] 找不到校验引擎: ${targetScript}`);
  console.error('  本脚本复用 project-insight 的 check-mermaid.mjs，请确认 agent-skills 仓库结构完整。');
  process.exit(2);
}
if (!existsSync(depsDir)) {
  console.error('[依赖缺失] skills/project-insight/scripts/node_modules 不存在。');
  console.error('  （node_modules 不入库）请先在该目录执行：npm install');
  process.exit(2);
}

const child = spawnSync(process.execPath, [targetScript, ...process.argv.slice(2)], {
  stdio: 'inherit',
});
process.exit(child.status ?? 1);
