#!/usr/bin/env node
// check-all.mjs —— project-wiki 的唯一门禁入口（薄壳编排）
//
// 用法：
//   node check-all.mjs <输出目录|a.md b.md ...> [--source-repo <源码根>] [--strict] [--preview]
//
// 为什么要有这个入口：校验器一旦分散成多条命令，就会"只跑了其中一个就当通过"，
// 而漏跑校验器 = 静默放过——那正是本 skill 最不能接受的事。所以收成一条命令、一个退出码。
//
// 编排：
//   1. check-docs.mjs（本 skill 自研）—— 代码预算 / 依据行真实性 / 结构 / 索引一致性
//   2. project-insight/scripts/check-mermaid.mjs（复用引擎）—— Mermaid 真解析 + flowchart render
//   3. project-insight/scripts/audit-svg-topology.mjs（复用引擎，仅当有 .svg 资产时）
//
// 依赖：只用 node 内置模块。Mermaid 解析所需 mermaid + jsdom 位于
//   skills/project-insight/scripts/node_modules（不入库）——本 skill 只转调，无需自行安装。
//
// 退出码：0 = 全部通过；1 = 任一子校验失败；2 = 依赖缺失/用法错误。

import { existsSync, readdirSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const SKILL_ROOT = resolve(HERE, '..');
const SKILLS_ROOT = resolve(SKILL_ROOT, '..');
const ENGINE = join(SKILLS_ROOT, 'project-insight', 'scripts');

const argv = process.argv.slice(2);
const targets = [];   // 仅位置参数（文档目录/文件），用于收集 .md / .svg
const passthrough = []; // 透传给 check-docs 的完整参数
let sourceRepo = null;
let preview = false;

for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === '--preview') { preview = true; continue; }
  if (a === '--source-repo') {
    const v = argv[++i];
    sourceRepo = v;
    // 子进程 cwd 是本脚本目录，相对路径必须在这里先绝对化，否则 check-docs 解析不到目标
    passthrough.push(a, v === undefined ? v : resolve(v));
    continue;
  }
  if (a === '-h' || a === '--help') {
    console.log('用法: node check-all.mjs <输出目录|a.md b.md ...> [--source-repo <源码根>] [--strict] [--preview]');
    process.exit(0);
  }
  if (a.startsWith('--')) { passthrough.push(a); continue; }
  passthrough.push(resolve(a));
  targets.push(a);
}

if (!targets.length) {
  console.error('用法: node check-all.mjs <输出目录|a.md b.md ...> [--source-repo <源码根>] [--strict] [--preview]');
  process.exit(2);
}

function run(label, scriptPath, args) {
  console.log(`\n===== ${label} =====`);
  const r = spawnSync(process.execPath, [scriptPath, ...args], {
    cwd: HERE,
    stdio: 'inherit',
  });
  return r.status ?? 1;
}

// —— 收集 .md / .svg（用于决定要不要跑对应校验器）——
function collect(dirOrFiles, ext) {
  const out = [];
  const walk = (dir) => {
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (e.name === 'node_modules' || e.name === '.git' || e.name.startsWith('.')) continue;
      const p = join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.toLowerCase().endsWith(ext)) out.push(p);
    }
  };
  for (const t of dirOrFiles) {
    if (t.startsWith('--')) continue;
    const abs = resolve(t);
    if (!existsSync(abs)) continue;
    if (statSync(abs).isDirectory()) walk(abs);
    else if (abs.toLowerCase().endsWith(ext)) out.push(abs);
  }
  return [...new Set(out)].sort();
}

const mdFiles = collect(targets, '.md');
const svgFiles = collect(targets, '.svg');

let failed = 0;

// 1. 自研门禁
failed += run('文档质量门禁（check-docs）', join(HERE, 'check-docs.mjs'), passthrough) === 0 ? 0 : 1;

// 2. Mermaid 真解析
let warnOnly = false;
if (mdFiles.length) {
  const engineScript = join(ENGINE, 'check-mermaid.mjs');
  const depsDir = join(ENGINE, 'node_modules');
  if (!existsSync(engineScript) || !existsSync(depsDir)) {
    console.error(`\n[依赖缺失] 找不到 Mermaid 校验引擎或依赖：${engineScript}`);
    console.error('  本脚本复用 project-insight 的引擎（单一真源）。请确认 ai-kit 仓库结构完整，');
    console.error('  并在 skills/project-insight/scripts/ 下执行过 npm install（node_modules 不入库）。');
    process.exit(2);
  }
  const code = run('Mermaid 真解析（project-insight 引擎）', engineScript, mdFiles);
  if (code !== 0) failed += 1;
} else {
  console.log('\n===== Mermaid 真解析 =====\n（未发现 .md 文件，跳过）');
  warnOnly = true;
}

// 3. 结构类图边拓扑（仅当有 SVG 资产）
if (svgFiles.length) {
  const auditScript = join(ENGINE, 'audit-svg-topology.mjs');
  if (existsSync(auditScript)) {
    const code = run('SVG 边拓扑审计（project-insight 引擎）', auditScript, svgFiles);
    if (code !== 0) failed += 1;
  }
  if (preview) {
    const previewScript = join(ENGINE, 'render-svg-preview.mjs');
    if (existsSync(previewScript)) {
      const code = run('SVG 目视预览（project-insight 引擎）', previewScript, svgFiles);
      // 预览失败不阻断（依赖本机 rsvg-convert）
      if (code !== 0) console.log('\n（预览未生成：可能缺 rsvg-convert，不阻断校验）');
    }
  }
} else {
  console.log('\n===== SVG 边拓扑审计 =====\n（未发现 .svg 资产，跳过）');
}

console.log(`\n########## check-all 汇总 ##########`);
console.log(failed === 0
  ? '全部门禁通过。'
  : `${failed} 项门禁未通过，请按上方输出逐条修复（不静默放过）。`);
if (warnOnly) console.log('提示：本次未发现 .md 文件，请确认传入的是输出目录而非源码目录。');
process.exit(failed === 0 ? 0 : 1);
