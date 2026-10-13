#!/usr/bin/env node
// plan-update.mjs —— project-wiki 的更新预检（规划输入，**不是门禁**）。
//
// 用法：
//   node plan-update.mjs <输出目录> --source-repo <源码根> --from <旧ref> --to <新ref> [--emit <快照.json>]
//   node plan-update.mjs <输出目录> --against <快照.json>
//
// 它为什么独立于 check-all：
//   check-all 判的是"产物质量"（通过 / 不通过），本脚本产出的是"该怎么改"的**清单**。
//   清单没有"通过"可言，硬塞进门禁会让两种语义混在一起。所以它自带 git 依赖、
//   自带 note 词汇，但**退出码只表达"清单有没有产出来"**（0 = 产出了；2 = 用法/依赖错误），
//   不表达通过与否。
//
// 它给出两张清单（数字与判定都可复现，不靠印象）：
//   一、受影响页 —— 页内依据行的路径落在 diff 变更文件集里；进一步看行级：
//       · 路径删除 / 改名 / 新增（旧基线尚不存在）→ 证据消失或错位（强）
//       · 依据行区间与 diff 旧侧变更块相交        → 论断可能失效（强）
//       · 仅行号漂移                              → 给出真实新行号（信息，不要求回应）
//   二、未覆盖的变更面 —— 新增文件没有被任何页的依据行引用，或能力自述/依赖/部署入口有变更
//       （这正是 page-plan 说的头号毛病"遗漏"的可程序化部分）
//
// 关键性质：**文件在两个 ref 间内容逐字相同 ⇒ 引用它的依据行依然成立**。
//   因此"未受影响页不动"是可证明的，不需要锚点指纹。
//
// 严重度：本脚本产出的码全部是 note（不阻断）；它们的处置义务落在交付清单里，
//   见 references/update-flow.md「交付清单」。
//
// 依赖：只用 node 内置模块 + 系统 git。不 clone、不 checkout、不写产物目录，
//   快照默认写系统临时目录（唯一中间态，不进产物、不进源码仓）。

import { readFileSync, writeFileSync, existsSync, statSync, readdirSync, realpathSync } from 'node:fs';
import { resolve, join, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { extractCitations, extractCodeBlocks, countBodyNonEmpty } from './lib/doc-parse.mjs';

const USAGE = `用法:
  node plan-update.mjs <输出目录> --source-repo <源码根> --from <旧ref> --to <新ref> [--emit <快照.json>]
  node plan-update.mjs <输出目录> --against <快照.json>`;

// ———————————————————————————— 参数 ————————————————————————————

const argv = process.argv.slice(2);
const positional = [];
const opt = { sourceRepo: null, from: null, to: null, emit: null, against: null };
for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === '--source-repo') { opt.sourceRepo = argv[++i]; continue; }
  if (a === '--from') { opt.from = argv[++i]; continue; }
  if (a === '--to') { opt.to = argv[++i]; continue; }
  if (a === '--emit') { opt.emit = argv[++i]; continue; }
  if (a === '--against') { opt.against = argv[++i]; continue; }
  if (a === '-h' || a === '--help') { console.log(USAGE); process.exit(0); }
  positional.push(a);
}

if (positional.length !== 1) {
  console.error(USAGE);
  process.exit(2);
}
const docsDir = resolve(positional[0]);
if (!existsSync(docsDir) || !statSync(docsDir).isDirectory()) {
  console.error(`[用法错误] 输出目录不存在或不是目录：${docsDir}`);
  process.exit(2);
}

function git(repo, args) {
  try {
    return execFileSync('git', ['-C', repo, ...args], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 60000, maxBuffer: 64 * 1024 * 1024,
    }).trim();
  } catch (e) {
    const err = { message: (e.stderr || e.message || '').toString().trim() };
    throw err;
  }
}

// ———————————————————————————— 文档结构（与 check-docs 共用同一解析实现）————————————————————————————

function collectMd(dir) {
  const out = [];
  const walk = (d) => {
    let entries;
    try { entries = readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (e.name === 'node_modules' || e.name === '.git' || e.name.startsWith('.')) continue;
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.toLowerCase().endsWith('.md')) out.push(p);
    }
  };
  walk(dir);
  return out.sort();
}

/** 结构指纹：页身份（文件名 + 标题）之外，能反映"内容有没有缩水"的可程序化指标 */
function structureOf(dir) {
  const pages = [];
  for (const file of collectMd(dir)) {
    const text = readFileSync(file, 'utf8');
    const lines = text.split('\n');
    const headings = lines
      .filter((l) => /^#{1,6}\s+/.test(l))
      .map((l) => l.trim().replace(/\s+/g, ' '));
    const blocks = extractCodeBlocks(lines);
    const diagramBlocks = blocks.filter((b) => b.lang === 'mermaid');
    let hasSvg = false;
    for (const l of lines) if (/\]\([^)]+\.svg\)/.test(l) || /<img[^>]+\.svg/.test(l)) hasSvg = true;
    const { citations } = extractCitations(lines);
    const { bodyNonEmpty } = countBodyNonEmpty(lines, blocks);
    pages.push({
      file: file.slice(dir.length + 1),
      headings,
      citations: citations.map((c) => ({ path: c.path, start: c.start, end: c.end, line: c.line })),
      figures: diagramBlocks.length + (hasSvg ? 1 : 0),
      bodyNonEmpty,
    });
  }
  return { pages };
}

const snapshot = {
  tool: 'plan-update',
  schema: 1,
  docs: docsDir,
  generatedAt: new Date().toISOString(),
  ...(opt.from ? { from: opt.from } : {}),
  ...(opt.to ? { to: opt.to } : {}),
  ...structureOf(docsDir),
};

// ———————————————————————————— 模式二：--against（改写后比对结构指纹）————————————————————————————

if (opt.against) {
  const snapshotPath = resolve(opt.against);
  if (!existsSync(snapshotPath)) {
    console.error(`[用法错误] 快照不存在：${snapshotPath}`);
    process.exit(2);
  }
  let before;
  try { before = JSON.parse(readFileSync(snapshotPath, 'utf8')); } catch (e) {
    console.error(`[用法错误] 快照无法解析：${e.message}`);
    process.exit(2);
  }
  const after = structureOf(docsDir);
  const afterMap = new Map(after.pages.map((p) => [p.file, p]));
  const findings = [];
  for (const b of before.pages ?? []) {
    const a = afterMap.get(b.file);
    if (!a) {
      findings.push(['DOC-UPDATE-PAGE-DROPPED', b.file, 1, `页在改写后消失（原 ${b.headings.length} 个标题、${b.citations.length} 条依据行）——页集合只增不删；确要删除须用户确认`]);
      continue;
    }
    const removedHeadings = b.headings.filter((h) => !a.headings.includes(h));
    if (removedHeadings.length) {
      findings.push(['DOC-UPDATE-SHRUNK', a.file, 1, `删掉 ${removedHeadings.length} 个标题：${removedHeadings.slice(0, 3).map((h) => `「${h.slice(0, 30)}」`).join('、')}${removedHeadings.length > 3 ? ' 等' : ''}——每一处删减都要在交付清单里给理由`]);
    }
    if (a.citations.length < b.citations.length) {
      findings.push(['DOC-UPDATE-SHRUNK', a.file, 1, `依据行从 ${b.citations.length} 条降到 ${a.citations.length} 条——依据变少意味着论断失去出处`]);
    }
    if (a.figures < b.figures) {
      findings.push(['DOC-UPDATE-SHRUNK', a.file, 1, `图从 ${b.figures} 张降到 ${a.figures} 张——"凡有形状必给图"是铁律，丢图最常见于整页重写`]);
    }
    if (b.bodyNonEmpty > 0 && a.bodyNonEmpty < b.bodyNonEmpty * 0.75) {
      findings.push(['DOC-UPDATE-SHRUNK', a.file, 1, `正文有效行数从 ${b.bodyNonEmpty} 降到 ${a.bodyNonEmpty}（降幅 >25%）——整页重写时最容易连带丢内容`]);
    }
  }
  const added = after.pages.filter((p) => !(before.pages ?? []).some((b) => b.file === p.file));
  console.log('## 更新预检·改写后结构比对（plan-update.mjs --against）\n');
  console.log(`对照快照：${snapshotPath}（生成于 ${before.generatedAt ?? '未知'}）`);
  console.log(`页数：${(before.pages ?? []).length} → ${after.pages.length}\n`);
  if (!findings.length) {
    console.log('结构指纹无收缩：页集合、标题、依据行、图、正文体量均未减少。');
  } else {
    for (const [code, file, line, msg] of findings) {
      console.log(`[${code}] ${file}:${line} —— ${msg}`);
    }
  }
  for (const p of added) console.log(`[信息] 新增页：${p.file}（记得回写首页索引）`);
  console.log('\n这些是 note：不阻断。请在交付清单里逐条回应（已处理 / 无需处理 / 转用户决定）。');
  process.exit(0);
}

// ———————————————————————————— 模式一：计划（diff 两端 → 两张清单）————————————————————————————

if (!opt.sourceRepo || !opt.from || !opt.to) {
  console.error(USAGE);
  process.exit(2);
}
const repo = resolve(opt.sourceRepo);
if (!existsSync(repo)) {
  console.error(`[用法错误] --source-repo 不存在：${repo}`);
  process.exit(2);
}
const repoReal = realpathSync(repo);

let nameStatus;
try {
  nameStatus = git(repoReal, ['diff', '--name-status', '-M', `${opt.from}..${opt.to}`]);
} catch (e) {
  console.error(`[用法错误] git diff ${opt.from}..${opt.to} 失败：${e.message}`);
  console.error('  两端都要能在源码仓里解析（旧端通常是首页契约行里的 ref）。');
  process.exit(2);
}

/** 变更文件表：path → { status, newPath } */
const changes = new Map();
for (const line of nameStatus.split('\n')) {
  if (!line.trim()) continue;
  const parts = line.split('\t');
  const status = parts[0][0];
  if (status === 'R') {
    changes.set(parts[1], { status: 'R', newPath: parts[2] });
    changes.set(parts[2], { status: 'R', newPath: parts[2], renamedFrom: parts[1] });
  } else {
    changes.set(parts[1], { status });
  }
}

/** 解析 `git diff -U0` 的旧侧变更块 → [{oldStart, oldEnd, delta}] */
function hunksOf(path) {
  let out;
  try {
    out = git(repoReal, ['diff', '-U0', `${opt.from}..${opt.to}`, '--', path]);
  } catch {
    return null;
  }
  const hunks = [];
  for (const l of out.split('\n')) {
    const m = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(l);
    if (!m) continue;
    const oldStart = parseInt(m[1], 10);
    const oldCount = m[2] === undefined ? 1 : parseInt(m[2], 10);
    const newCount = m[4] === undefined ? 1 : parseInt(m[4], 10);
    hunks.push({
      oldStart,
      oldEnd: oldCount === 0 ? oldStart : oldStart + oldCount - 1,
      oldCount,
      delta: newCount - oldCount,
    });
  }
  return hunks;
}

const citedPaths = new Set();
for (const p of snapshot.pages) for (const c of p.citations) citedPaths.add(c.path);

const touched = [];   // [page, line, 依据, 说明]
const drift = [];     // [page, 依据, 旧行号, 新行号]
const provablyUnaffected = [];
const unevaluable = [];   // 没有依据行的页：diff 判不了它受不受影响

for (const page of snapshot.pages) {
  if (!page.citations.length) { unevaluable.push(page.file); continue; }
  const reasons = [];
  let drifted = false;
  for (const c of page.citations) {
    const ch = changes.get(c.path);
    if (!ch) continue;
    const loc = `${c.path}:${c.start}${c.end !== c.start ? `-${c.end}` : ''}`;
    if (ch.status === 'D') {
      reasons.push([c.line, loc, '该路径在新区间已被删除——论断证据已消失，需重新核实或移除']);
      continue;
    }
    if (ch.status === 'R') {
      reasons.push([c.line, loc, `路径已改名为 ${ch.newPath}（或由 ${ch.renamedFrom ?? '?'} 改名而来）——依据行需更新`]);
      continue;
    }
    if (ch.status === 'A') {
      reasons.push([c.line, loc, '该路径在旧基线尚不存在——依据行本就无法核对，请确认引用的版本']);
      continue;
    }
    const hunks = hunksOf(c.path);
    if (hunks === null) { reasons.push([c.line, loc, '无法读取该文件的 diff（可能是二进制或权限问题），需人工复核']); continue; }
    const hit = hunks.some((h) => h.oldCount > 0 && h.oldStart <= c.end && h.oldEnd >= c.start);
    if (hit) {
      const h = hunks.find((x) => x.oldCount > 0 && x.oldStart <= c.end && x.oldEnd >= c.start);
      reasons.push([c.line, loc, `依据区间与变更块相交（旧侧 ${h.oldStart}-${h.oldEnd}）——论断可能已失效，必须复核`]);
      continue;
    }
    // 仅漂移：内容未变，但前面的增删让行号移动了。给出真实新行号（等价于无指纹版的 STALE 解析）
    const delta = hunks.filter((h) => h.oldEnd < c.start).reduce((n, h) => n + h.delta, 0);
    if (delta !== 0) {
      drifted = true;
      drift.push([page.file, loc, `${c.start + delta}${c.end !== c.start ? `-${c.end + delta}` : ''}`]);
    }
  }
  if (reasons.length) {
    for (const [line, loc, why] of reasons) touched.push([page.file, line, loc, why]);
  } else if (!drifted) {
    provablyUnaffected.push(page.file);
  }
}

// —— 未覆盖的变更面 ——
const NOISE_DIR_RE = /(^|\/)(tests?|specs?|__tests__|fixtures?|testdata|examples?|e2e)\//i;
const LOCKFILES = new Set(['package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'cargo.lock', 'go.sum', 'composer.lock', 'poetry.lock', 'gemfile.lock']);
const BINARY_EXT_RE = /\.(png|jpe?g|gif|ico|webp|bmp|woff2?|ttf|otf|eot|pdf|zip|tarball|gz|tgz|bz2|xz|7z|jar|war|so|dylib|dll|exe|bin|mp[34]|mov|avi|class|o|a)$/i;
const CAPABILITY_FILES = new Set(['readme.md', 'readme', 'changelog.md', 'changelog', 'package.json', 'go.mod', 'cargo.toml', 'pyproject.toml', 'pom.xml', 'build.gradle', 'build.gradle.kts', 'requirements.txt', 'docker-compose.yml', 'docker-compose.yaml', 'dockerfile']);

const uncovered = [];
const skipped = [];
for (const [path, ch] of changes) {
  if (ch.status !== 'A') continue;
  if (citedPaths.has(path)) continue;
  if (NOISE_DIR_RE.test(path) || LOCKFILES.has(basename(path).toLowerCase()) || BINARY_EXT_RE.test(path) || path.startsWith('.')) {
    skipped.push(path);
    continue;
  }
  uncovered.push(path);
}

const capabilityChanged = [];
for (const [path, ch] of changes) {
  if (ch.status === 'D') continue;
  const b = basename(path).toLowerCase();
  if (CAPABILITY_FILES.has(b)) capabilityChanged.push(`${path}（${ch.status === 'A' ? '新增' : '修改'}）`);
}

// —— 输出 ——
const CAP = 40;
console.log('## 更新预检（plan-update.mjs）\n');
console.log(`基线区间：${opt.from}..${opt.to}（变更文件 ${nameStatus.split('\n').filter((l) => l.trim()).length} 个）；文档目录：${docsDir}`);
console.log('本清单不表达通过与否，退出码 0 只表示"清单已产出"。\n');

console.log(`### 一、受影响页（${new Set(touched.map((t) => t[0])).size} 页）`);
if (!touched.length) {
  console.log(drift.length
    ? '- 无强命中；但下方有行号漂移，见漂移清单。'
    : '- 无：没有任何页的依据行落在变更文件里。');
}
for (const [page, line, loc, why] of touched) {
  console.log(`[DOC-UPDATE-TOUCHED] ${page}:${line} —— \`${loc}\`：${why}`);
}

if (drift.length) {
  console.log(`\n### 行号漂移（仅位置移动，内容未变；容差内可不改，超出请就地更新依据行）`);
  for (const [page, loc, now] of drift) console.log(`- ${page}：\`${loc}\` → 新行号 \`${now}\``);
}

console.log(`\n### 二、未覆盖的变更面（${uncovered.length + capabilityChanged.length} 项）`);
if (!uncovered.length && !capabilityChanged.length) console.log('- 无：新增文件都已被某页的依据行引用，能力自述/依赖/部署入口也没有变化。');
for (const path of uncovered.slice(0, CAP)) {
  console.log(`[DOC-UPDATE-UNCOVERED] ${path} —— 新增文件未被任何页的依据行引用；若它承载了新能力，按 page-plan.md 判断是否该成页`);
}
if (uncovered.length > CAP) console.log(`[DOC-UPDATE-UNCOVERED] …另有 ${uncovered.length - CAP} 个新增文件未列出（已截断，非"没有"）`);
for (const c of capabilityChanged) {
  console.log(`[DOC-UPDATE-UNCOVERED] ${c} —— 能力自述/依赖/部署入口有变更，请复核页集与"现状与边界"是否需更新`);
}
if (skipped.length) console.log(`（已排除 ${skipped.length} 个测试/示例/锁文件/二进制路径，避免噪声淹没真信号）`);

console.log(`\n### 三、未受影响页（${provablyUnaffected.length} 页，可证明仍成立）`);
console.log(provablyUnaffected.length
  ? provablyUnaffected.map((p) => `- ${p}`).join('\n')
  : '- 无');
if (provablyUnaffected.length) {
  console.log('  这些页的全部依据行路径在两个 ref 之间内容逐字未变 ⇒ 行号与内容都不可能变，**不要重写**。');
}

if (unevaluable.length) {
  console.log(`\n### 无依据行的页（diff 判不了，需人读：${unevaluable.length} 页）`);
  for (const p of unevaluable) console.log(`- ${p}`);
}

// —— 结构快照 ——
const snapPath = opt.emit
  ? resolve(opt.emit)
  : join(tmpdir(), `project-wiki-structure-${basename(docsDir)}-${Date.now()}.json`);
writeFileSync(snapPath, `${JSON.stringify(snapshot, null, 2)}\n`, 'utf8');
console.log(`\n### 结构快照`);
console.log(`已写入：${snapPath}`);
console.log('改写完成后跑 `--against <该快照>` 比对结构指纹（标题/依据行/图/正文体量是否缩水）。');
console.log('交付清单需逐条回应上面的 note（含 --against 的产出）；这些 note 不阻断，但必须显形。');
process.exit(0);
