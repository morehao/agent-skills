#!/usr/bin/env node
// audit-svg-topology.mjs —— tech-design 的 SVG 边拓扑审计入口（薄壳）
//
// 用法：
//   node audit-svg-topology.mjs <a.svg> [b.svg ...]
//   node audit-svg-topology.mjs --expect <expected.txt> [--strict] [--tolerance 6] <a.svg>
//
// 职责：定位并转调 project-insight/scripts/audit-svg-topology.mjs（同一套解析
// 引擎，单一真源，避免重复维护坐标/端点判定逻辑）。该审计逐条打印
// 「起点节点 → 终点节点」，用于发现结构类图最常见的隐性错误——「看着对、
// 边连错」（缺边/多边/分支挂错节点，而标签全对、渲染不报错）。
// 这是目前唯一能程序化发现该类错误的手段。
//
// 期望清单格式（每行一条，`#` 起头为注释，`->` 两侧为节点标签）：
//   客户端上传文档 -> 原文落对象存储
//
// 只接受 **.svg 文件**：因此文档里的结构类图应落成同目录 .svg 资产，
// 而不是内联进 Markdown（内联 SVG 无法被本脚本解析）。
//
// 依赖：只用 node 内置模块 + git-free，无需 npm install。

import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const skillRoot = resolve(here, '..'); // skills/<本skill>
const skillsRoot = resolve(skillRoot, '..');
const targetScript = join(skillsRoot, 'project-insight', 'scripts', 'audit-svg-topology.mjs');

if (!existsSync(targetScript)) {
  console.error(`[依赖缺失] 找不到审计引擎: ${targetScript}`);
  console.error('  本脚本复用 project-insight 的 audit-svg-topology.mjs，请确认 agent-skills 仓库结构完整。');
  process.exit(2);
}

const child = spawnSync(process.execPath, [targetScript, ...process.argv.slice(2)], {
  stdio: 'inherit',
});
process.exit(child.status ?? 1);
