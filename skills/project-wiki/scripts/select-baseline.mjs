#!/usr/bin/env node
// select-baseline.mjs —— project-wiki 的版本基线入口（薄壳）
//
// 用法：
//   node select-baseline.mjs <本地路径|远端URL> [--ref <ref>] [--package <名>] [--json]
//
// 职责：定位并转调 project-insight/scripts/select-baseline.mjs（同一套基线选择逻辑，
// 单一真源）。基线决定"这份文档描述的是哪个版本"——行号只在确定的快照上成立，
// 不定基线就开写，等于文档一诞生就已经过时且无法核对。
//
// 优先级（由引擎实现）：稳定 tag > 稳定分支（release*/stable*/maintenance*/1.x）
//   > 默认分支（main/master/远端 HEAD）> 无 main/master 的兜底矩阵。
// 选出后写进首页契约行（唯一一处，单基线）：
//   **本文档依据**：`<ref>`（`<短SHA>`，<YYYY-MM-DD>）
// 引擎返回退出码 2（[BASELINE-STALE] / [BASELINE-AMBIGUOUS]）= 需用户三选一裁决，
// 不自行挑一个就开写；细则见 references/version-contract.md。
//
// 依赖：只用 node 内置模块 + git，无需 npm install。

import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const skillRoot = resolve(here, '..'); // skills/project-wiki
const skillsRoot = resolve(skillRoot, '..');
const targetScript = join(skillsRoot, 'project-insight', 'scripts', 'select-baseline.mjs');

if (!existsSync(targetScript)) {
  console.error(`[依赖缺失] 找不到基线选择引擎: ${targetScript}`);
  console.error('  本脚本复用 project-insight 的 select-baseline.mjs，请确认 ai-kit 仓库结构完整。');
  process.exit(2);
}

const child = spawnSync(process.execPath, [targetScript, ...process.argv.slice(2)], {
  stdio: 'inherit',
});

// 引擎的输出沿用了 project-insight 的落点话术（解读基线 / CHANGELOG.md）。
// 本 skill 的落点是首页一行，这里补一句适配说明，避免照抄错落点。
if ((child.status ?? 1) === 0) {
  console.log('\n本 skill 的落点（与 project-insight 不同）：把 ref、短 SHA、日期写进首页 README.md 的契约行——');
  console.log('  **本文档依据**：`<ref>`（`<短SHA>`，<YYYY-MM-DD>）');
  console.log('日期取基线 ref 的提交日期：git -C <源码根> log -1 --format=%cs <ref>');
  console.log('只写这一处（单基线）：不维护 CHANGELOG、不写"已核对至"；它就是下次更新取 diff 的左端。');
  console.log('校验收尾要带上：check-all <输出目录> --source-repo <基线工作树> --expect-baseline <ref>');
} else if ((child.status ?? 1) === 2) {
  console.log('\n本 skill 的裁决（引擎要求确认时）：按结构化三选一，别自己挑一个就往下写——');
  console.log('  ① 接受这个陈旧 tag：在正文写读者可见的声明「本文档基于 <ref>（<日期>），晚于该版本的变更未涵盖」');
  console.log('  ② 改按默认分支：契约行写分支 ref，并声明「未发布版本」');
  console.log('  ③ 用户直接给出 ref');
  console.log('陈旧冲突的含义与理由见 references/version-contract.md。');
}

process.exit(child.status ?? 1);
