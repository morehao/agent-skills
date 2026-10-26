#!/usr/bin/env node
// check-narrative-all.mjs —— 叙述型文档的一键校验入口
//
// 把原先靠人记着跑的多个脚本合成一条命令，避免"只跑了其中一个就当通过"：
//   1. scan-narrative.mjs   零索引 / 跨文档隔离 / SVG 资产 / 标题编号 / 交叉引用 / 孤立图
//   2. check-mermaid.mjs    mermaid 真解析 + 渲染（flowchart 额外走 render）
//   3. audit-svg-topology.mjs  逐张 SVG 打印「起点 → 终点」，核对边拓扑
//   4.（可选 --preview）render-svg-preview.mjs  出 PNG 供目视核验
//
// 用法：
//   node check-narrative-all.mjs <architecture-design.md> [...]
//   node check-narrative-all.mjs --repo-root <解读目录> [--preview] [--strict-topology] <architecture-design.md>
//
// 退出码：0 = 全部通过；1 = 文档级检查失败或（strict 模式下）边拓扑审计失败。
// 说明：SVG 边拓扑审计默认只报 `WARN`（存量资产可能存在历史性的小间距，不应因此卡住整篇文档），
// 新画图时用 `--strict-topology` 或直接单跑 `audit-svg-topology.mjs` 作为硬门禁。

import { existsSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

function run(args) {
  const r = spawnSync(process.execPath, args, { cwd: HERE, encoding: 'utf8' });
  return { code: r.status ?? 1, out: (r.stdout || '').trim(), err: (r.stderr || '').trim() };
}

function main() {
  const argv = process.argv.slice(2);
  let repoRoot = null, preview = false, strictTopology = false;
  const files = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--repo-root') { repoRoot = argv[++i]; continue; }
    if (argv[i] === '--preview') { preview = true; continue; }
    if (argv[i] === '--strict-topology') { strictTopology = true; continue; }
    files.push(argv[i]);
  }
  if (!files.length) {
    console.error('用法: node check-narrative-all.mjs [--repo-root <dir>] [--preview] [--strict-topology] <narrative.md> [...]');
    process.exit(2);
  }

  // 子进程以本脚本所在目录为 cwd（check-mermaid 的 node_modules 在那里），
  // 因此用户给的相对路径必须先在**当前工作目录**解析成绝对路径再传下去。
  const absFiles = files.map((f) => resolve(f));
  const absRoot = repoRoot ? resolve(repoRoot) : null;

  const summary = [];
  const step = (name, args, { fatal = true, quiet = false } = {}) => {
    const r = run(args);
    const ok = r.code === 0;
    summary.push([name, ok ? 'OK' : (fatal ? 'FAIL' : 'WARN')]);
    if (!quiet || !ok) {
      if (r.out) console.log(r.out);
      if (r.err && !ok) console.error(r.err);
    }
    return { ok, ...r };
  };

  // 1) 叙述型结构校验
  step('scan-narrative', ['scan-narrative.mjs', ...(absRoot ? ['--repo-root', absRoot] : []), ...absFiles]);

  // 2) mermaid 校验
  step('check-mermaid', ['check-mermaid.mjs', ...absFiles]);

  // 3) SVG 边拓扑审计（收集文档引用到的资产）
  const svgs = new Set();
  for (const f of absFiles) {
    if (!existsSync(f)) continue;
    const text = readFileSync(f, 'utf8');
    const dir = absRoot || dirname(f);
    for (const m of text.matchAll(/!\[[^\]]*\]\(([^)]+\.svg)\)/g)) {
      const p = resolve(dir, m[1]);
      if (existsSync(p)) svgs.add(p);
    }
  }
  if (svgs.size) {
    step('audit-svg-topology', ['audit-svg-topology.mjs', ...(strictTopology ? ['--strict'] : []), ...[...svgs].sort()], { fatal: strictTopology });
  } else {
    summary.push(['audit-svg-topology', 'SKIP']);
  }

  // 4) 可选：出预览图（落在调用方工作目录的 .tmp/ 下，避免污染 skills 仓库）
  if (preview && svgs.size) {
    step('render-svg-preview', ['render-svg-preview.mjs', '--out', join(process.cwd(), '.tmp', 'svg-preview'), ...[...svgs].sort()]);
  }

  console.log('\n=== 汇总 ===');
  for (const [name, st] of summary) console.log(`${st.padEnd(5)} ${name}  (${files.map((f) => basename(f)).join(', ')})`);
  const bad = summary.filter(([, st]) => st === 'FAIL');
  const warned = summary.filter(([, st]) => st === 'WARN');
  if (bad.length) {
    console.log(`\n共 ${bad.length} 步失败：${bad.map(([n]) => n).join(', ')}。修复后重跑。`);
    process.exit(1);
  }
  if (warned.length) {
    console.log(`\n文档级检查全部通过；${warned.length} 步为提示级（${warned.map(([n]) => n).join(', ')}）——`
      + '新画的图请用 `--strict-topology` 或直接单跑 `audit-svg-topology.mjs` 作为硬门禁。');
  }
  console.log('\n全部通过。提示：不可程序化的部分（每条论断能否回指证据型文档）仍须人工复核，每次改完重跑。');
  process.exit(0);
}

main();
