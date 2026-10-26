#!/usr/bin/env node
// check-doc.mjs —— 架构分析文档的通用体检（默认模式也能用）
//
// 用法：
//   node check-doc.mjs [--source-repo <源码根>] [--strict] <文档.md> [更多.md]
//
// 检查项（全部只读，不改文档）：
//   [DOC-LINK]         Markdown 相对链接 / 图片指向的本地文件不存在
//   [DOC-SVG]          被引用的 SVG 缺 <title>/<desc>、缺 viewBox、含外部资源
//   [DOC-EVIDENCE]     证据附录里的 `[path:start-end](url)` 路径不存在或行号越界
//   [DOC-PATH]         正文 code span 里的 `path:line` 路径不存在（提示级，抽检用）
//   [DOC-FIGURE-ONLY]  某个小节只有图、没有导读/着落（提示级）
//
// 退出码：0 = 通过（可带提示）；1 = 有错误（`--strict` 下提示也计为失败）；2 = 用法/读取错误。
//
// 说明：证据语义的精确校验仍由 verify-references.mjs 负责（锚点重定位）；
// 本脚本只做"路径/资产/链接存在性"这类确定性检查，不判断内容质量。

import { readFileSync, existsSync, statSync } from 'node:fs';
import { resolve, dirname, relative, isAbsolute } from 'node:path';

const SKIP_SCHEME = /^(?:[a-z][a-z0-9+.-]*:|\/|~)/i;
const IMG_RE = /!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
const LINK_RE = /(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
const EVIDENCE_RE = /\[([^\][]+?\.[A-Za-z0-9]+):(\d+)-(\d+)\]\(([^)]*)\)/g;
const CODE_PATH_RE = /`([A-Za-z0-9_@./-]+\.[A-Za-z0-9]+):(\d+)(?:-(\d+))?`/g;

function parseArgs(argv) {
  let sourceRepo = null;
  let strict = false;
  const files = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--source-repo') {
      sourceRepo = argv[++i];
      if (!sourceRepo) usage('--source-repo 需要一个目录参数');
    } else if (a === '--strict') {
      strict = true;
    } else if (a === '--help' || a === '-h') {
      usage();
    } else if (a.startsWith('-')) {
      usage(`未知参数：${a}`);
    } else {
      files.push(a);
    }
  }
  if (!files.length) usage('至少需要一个 Markdown 文件');
  if (sourceRepo && !existsSync(sourceRepo)) usage(`source-repo 不存在：${sourceRepo}`);
  return { sourceRepo: sourceRepo ? resolve(sourceRepo) : null, strict, files };
}

function usage(msg) {
  if (msg) console.error(`[用法错误] ${msg}`);
  console.error('用法: node check-doc.mjs [--source-repo <源码根>] [--strict] <文档.md> [更多.md]');
  process.exit(2);
}

// 把围栏代码块替换为空行，保留行号；避免把示例代码里的链接/路径当成真实内容。
function maskFences(text) {
  const lines = text.split('\n');
  let inFence = false;
  let marker = '';
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trimStart();
    if (!inFence && /^(```|~~~)/.test(t)) {
      inFence = true;
      marker = t.slice(0, 3);
      lines[i] = '';
    } else if (inFence && t.startsWith(marker)) {
      inFence = false;
      marker = '';
      lines[i] = '';
    } else if (inFence) {
      lines[i] = '';
    }
  }
  return lines.join('\n');
}

function lineOf(text, idx) {
  return text.slice(0, idx).split('\n').length;
}

function cleanTarget(raw) {
  let t = raw.trim();
  if (t.startsWith('<') && t.endsWith('>')) t = t.slice(1, -1);
  t = t.split('#')[0].split('?')[0];
  try {
    t = decodeURI(t);
  } catch {
    /* 保留原样 */
  }
  return t;
}

function isLocalTarget(t) {
  return t && !SKIP_SCHEME.test(t);
}

function checkSvg(path, lineNo, rel, errors) {
  let svg;
  try {
    svg = readFileSync(path, 'utf8');
  } catch (err) {
    errors.push([lineNo, `[DOC-SVG] 无法读取 SVG：${rel}（${err.message}）`]);
    return;
  }
  if (!/<title[\s>]/.test(svg)) errors.push([lineNo, `[DOC-SVG] ${rel} 缺 <title>`]);
  if (!/<desc[\s>]/.test(svg)) errors.push([lineNo, `[DOC-SVG] ${rel} 缺 <desc>`]);
  if (!/viewBox\s*=\s*["'][^"']+["']/.test(svg)) errors.push([lineNo, `[DOC-SVG] ${rel} 缺固定 viewBox`]);
  if (/<image\b/i.test(svg)) errors.push([lineNo, `[DOC-SVG] ${rel} 含 <image> 外部图片`]);
  if (/<script\b/i.test(svg)) errors.push([lineNo, `[DOC-SVG] ${rel} 含 <script>`]);
  if (/href\s*=\s*["']https?:/i.test(svg)) errors.push([lineNo, `[DOC-SVG] ${rel} 含远程 href`]);
  if (/@import/i.test(svg)) errors.push([lineNo, `[DOC-SVG] ${rel} 含 @import`]);
}

function checkLinks(masked, docPath, errors) {
  // 行内代码里出现的链接样式是示例，不当作真实链接；保留行号。
  const linkText = masked.replace(/`[^`\n]*`/g, '');
  const dir = dirname(docPath);
  const seen = new Set();
  for (const re of [LINK_RE, IMG_RE]) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(linkText)) !== null) {
      const raw = m[1];
      if (!isLocalTarget(raw)) continue;
      const target = cleanTarget(raw);
      if (!target || seen.has(target)) continue;
      seen.add(target);
      const abs = isAbsolute(target) ? target : resolve(dir, target);
      const lineNo = lineOf(linkText, m.index);
      if (!existsSync(abs)) {
        errors.push([lineNo, `[DOC-LINK] 本地目标不存在：${target}`]);
        continue;
      }
      if (/\.svg$/i.test(abs)) checkSvg(abs, lineNo, relative(dir, abs) || target, errors);
    }
  }
}

function checkEvidence(masked, sourceRepo, docPath, errors, warnings) {
  const seen = new Set();
  EVIDENCE_RE.lastIndex = 0;
  let m;
  while ((m = EVIDENCE_RE.exec(masked)) !== null) {
    const rel = m[1];
    const start = parseInt(m[2], 10);
    const end = parseInt(m[3], 10);
    const lineNo = lineOf(masked, m.index);
    if (seen.has(`${rel}:${start}:${end}`)) continue;
    seen.add(`${rel}:${start}:${end}`);
    if (!sourceRepo) continue;
    const abs = resolve(sourceRepo, rel);
    const relToRoot = relative(sourceRepo, abs);
    if (relToRoot.startsWith('..') || isAbsolute(relToRoot)) {
      errors.push([lineNo, `[DOC-EVIDENCE] 路径越出 source_repo：${rel}`]);
      continue;
    }
    if (!existsSync(abs) || !statSync(abs).isFile()) {
      errors.push([lineNo, `[DOC-EVIDENCE] 路径不存在：${rel}`]);
      continue;
    }
    const total = readFileSync(abs, 'utf8').split('\n').length;
    if (end > total || start < 1 || end < start) {
      errors.push([lineNo, `[DOC-EVIDENCE] 行号越界：${rel}:${start}-${end}（文件共 ${total} 行）`]);
    }
  }
  if (!sourceRepo) return;
  CODE_PATH_RE.lastIndex = 0;
  while ((m = CODE_PATH_RE.exec(masked)) !== null) {
    const rel = m[1];
    const line = parseInt(m[2], 10);
    const end = m[3] ? parseInt(m[3], 10) : line;
    const lineNo = lineOf(masked, m.index);
    const abs = resolve(sourceRepo, rel);
    const relToRoot = relative(sourceRepo, abs);
    if (relToRoot.startsWith('..') || isAbsolute(relToRoot)) continue;
    if (!existsSync(abs) || !statSync(abs).isFile()) {
      warnings.push([lineNo, `[DOC-PATH] 正文路径不存在（提示）：${rel}`]);
      continue;
    }
    const total = readFileSync(abs, 'utf8').split('\n').length;
    if (end > total) warnings.push([lineNo, `[DOC-PATH] 正文行号越界（提示）：${rel}:${end}（文件共 ${total} 行）`]);
  }
}

function checkFigureOnly(text, warnings) {
  const lines = text.split('\n');
  const sections = [];
  let current = null;
  for (let i = 0; i < lines.length; i++) {
    const m = /^(#{2,6})\s+(.+?)\s*$/.exec(lines[i]);
    if (m) {
      if (current) sections.push(current);
      current = { level: m[1].length, title: m[2], start: i + 1, body: [] };
    } else if (current) {
      current.body.push(lines[i]);
    }
  }
  if (current) sections.push(current);
  for (const s of sections) {
    const body = s.body.join('\n');
    const hasFigure = /```mermaid|!\[|<img\b|<svg\b/.test(body);
    if (!hasFigure) continue;
    const stripped = body
      .replace(/```[\s\S]*?```/g, '')
      .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
      .replace(/<!--[\s\S]*?-->/g, '')
      .replace(/^\s*[-*]\s*$/gm, '')
      .replace(/[#>*_`|:：\-\s]/g, '');
    if (stripped.length < 20) {
      warnings.push([s.start, `[DOC-FIGURE-ONLY] 小节「${s.title}」只有图，缺导读或着落`]);
    }
  }
}

function main() {
  const { sourceRepo, strict, files } = parseArgs(process.argv.slice(2));
  let errorCount = 0;
  let warnCount = 0;
  for (const file of files) {
    const docPath = resolve(file);
    let text;
    try {
      text = readFileSync(docPath, 'utf8');
    } catch (err) {
      console.error(`[DOC-ERROR] 无法读取 ${file}：${err.message}`);
      errorCount += 1;
      continue;
    }
    const masked = maskFences(text);
    const errors = [];
    const warnings = [];
    checkLinks(masked, docPath, errors);
    checkEvidence(masked, sourceRepo, docPath, errors, warnings);
    checkFigureOnly(text, warnings);

    if (errors.length === 0) {
      console.log(`[DOC-OK] ${file}${warnings.length ? `（${warnings.length} 条提示）` : ''}`);
    }
    for (const [lineNo, msg] of errors) console.log(`${file}:${lineNo} ${msg}`);
    for (const [lineNo, msg] of warnings) console.log(`${file}:${lineNo} ${msg}`);
    errorCount += errors.length;
    warnCount += warnings.length;
  }
  if (errorCount > 0 || (strict && warnCount > 0)) {
    console.error(`\n[DOC-FAIL] 错误 ${errorCount} 条，提示 ${warnCount} 条${strict ? '（--strict：提示也计为失败）' : ''}`);
    process.exit(1);
  }
  console.log(`\n[DOC-PASS] 错误 0 条，提示 ${warnCount} 条`);
}

main();
