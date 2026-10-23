#!/usr/bin/env node
// render-svg-preview.mjs —— tech-design 的 SVG 目视预览入口（薄壳）
//
// 用法：
//   node render-svg-preview.mjs <a.svg> [b.svg ...]
//   node render-svg-preview.mjs --out <dir> --width 1200 [--dark] [--keep-svg] <a.svg> [...]
//
// 职责：定位并转调 project-insight/scripts/render-svg-preview.mjs（同一套渲染
// 逻辑，单一真源）。SVG 统一用 `:root` CSS 变量 + `prefers-color-scheme` 做
// 浅深色适配，而 librsvg **不解析 CSS 自定义属性**——直接渲染会全黑或缺色，
// 容易被误判为「图坏了」。该脚本先把 `var(--x)` 展平成字面色值，再出 PNG。
//
// 输出：<out>/<name>.preview.png（--dark 时额外输出 .preview.dark.png）
//
// 依赖：node 内置模块 + 本机 `rsvg-convert`（缺了会被下游脚本明确报错）。

import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const skillRoot = resolve(here, '..'); // skills/<本skill>
const skillsRoot = resolve(skillRoot, '..');
const targetScript = join(skillsRoot, 'project-insight', 'scripts', 'render-svg-preview.mjs');

if (!existsSync(targetScript)) {
  console.error(`[依赖缺失] 找不到预览引擎: ${targetScript}`);
  console.error('  本脚本复用 project-insight 的 render-svg-preview.mjs，请确认 agent-skills 仓库结构完整。');
  process.exit(2);
}

const child = spawnSync(process.execPath, [targetScript, ...process.argv.slice(2)], {
  stdio: 'inherit',
});
process.exit(child.status ?? 1);
