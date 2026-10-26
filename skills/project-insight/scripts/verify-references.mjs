#!/usr/bin/env node
// verify-references.mjs —— 真源引用程序化校验（Grounding，防幻觉核心配套）。
//
// 用法：
//   node verify-references.mjs <source_repo> <解读.md> [file2.md ...]
//     <source_repo>  源码仓库根（= 本次选定基线的工作树），作为所有 `文件:行号` 引用验证的锚点。
//     其余参数  解读文档（本 skill 本次产出的全部 md）。
//
// 行为：
//   - 提取每个展示引用 `[仓库相对路径/文件.ext:start-end]()`，并匹配其紧邻的指纹注释。
//   - 指纹 = 可信锚点行（模型从源码上下文**逐字复制**的原文），两种形式：
//       · 首末行双锚点（推荐，产出物不再被整段源码淹没）：
//           <!-- anchor: <区间首行原文> … <末行原文> -->
//         （锚点行从行首截断 ≤80 字符、可去掉行首空白；单行区间只需一行锚点；
//           含 `--` 等破坏 HTML 注释的字符时用 base64：<!-- anchor-base64:<b64> -->）
//       · 旧格式（存量文档兼容，仍受支持）：<!-- snippet:<整段原文> --> / <!-- snippet-base64:<b64> -->
//   - 锚点校验：先在声称的行号处做**精确位置校验**（第 start 行附近以首锚开头、第 end 行
//     附近以末锚开头，双向验证），失败再全文件搜索锚点算出真实行号，与文档标注比对。
//     旧 snippet 格式沿用整段搜索定位（见 locateSnippet）。
//   - 无指纹注释时降级为弱校验：路径存在、文件可读、行号区间未越界即通过（标记 WEAK），
//     提示补充指纹以获得精确行号验证。
//   - 路径一律 realpath + commonpath 防穿越，越出 source_repo 直接标记 TRAVERSAL。
//
// 输出状态（TRAVERSAL / MISMATCH / UNVERIFIED 任一即非 0 退出码，不静默放过）：
//   [GROUNDER-OK]          锚点/指纹定位成功且行号吻合
//   [GROUNDER-MISMATCH]    定位成功但行号有偏差，打印真实行号供覆盖
//   [GROUNDER-WEAK]        无指纹/锚点不合格，弱校验通过（文件可读、行号未越界），建议补指纹
//   [GROUNDER-UNVERIFIED]  路径不存在 / 文件不可读 / 指纹定位失败（等价 [UNVERIFIED]）
//   [GROUNDER-TRAVERSAL]   路径越出 source_repo，已阻止
//
// 与 check-mermaid.mjs 同理：本脚本是校验工具，只读不改解读文档。

import { readFileSync, realpathSync } from 'node:fs';
import { resolve, join, sep } from 'node:path';
import { stdin, stdout } from 'node:process';

// commonPath 等价实现：判断 target 是否等于或位于 repo 目录之下（纯字符串前缀，已 realpath）
function isWithinRoot(repo, target) {
  if (target === repo) return true;
  return target.startsWith(repo + sep);
}

// —— 展示引用：`[仓库相对路径/文件.ext:start-end]()` ——
// 路径部分可含字母数字 / . _ -；行号区间 start-end 为数字。
const CITATION_RE = /\[([^\][]+?\.\w+):(\d+)-(\d+)\]\(\)/g;

// —— 指纹注释（新）：首末行双锚点 ——
// `<!-- anchor:<首行原文> … <末行原文> -->` 或含 `--` 时 `<!-- anchor-base64:<b64> -->`
const ANCHOR_RE = /<!--\s*anchor-base64:([A-Za-z0-9+/=]+)\s*-->|<!--\s*anchor:([\s\S]*?)-->/g;

// —— 指纹注释（旧，存量文档兼容）：整段 snippet ——
// `<!-- snippet:<整段原文> -->` 或 `<!-- snippet-base64:<b64> -->`
const LEGACY_FINGERPRINT_RE = /<!--\s*snippet-base64:([A-Za-z0-9+/=]+)\s*-->|<!--\s*snippet:([\s\S]*?)-->/g;

// 引用行之后允许出现指纹注释的最大间隔（行数）
const FINGERPRINT_PROXIMITY = 2;

// —— 锚点行质量底线：过短（<6 字符）或纯标点视为不合格，降级 WEAK ——
function isUsableAnchor(a) {
  if (!a) return false;
  const t = a.trim();
  return t.length >= 6 && /[A-Za-z0-9]/.test(t);
}

// —— 切分锚点注释内容为首锚 / 末锚（分隔符 ` … `，兼容英文 ` ... `）——
// 单行区间或未写末锚时 last === first；各自只取第一行，防多行内容混入。
function splitAnchors(content) {
  let first = content;
  let last = null;
  for (const sep of [' … ', ' ... ']) {
    const i = content.indexOf(sep);
    if (i !== -1) {
      first = content.slice(0, i);
      last = content.slice(i + sep.length);
      break;
    }
  }
  first = (first || '').split('\n')[0].trim();
  last = last == null ? first : last.split('\n')[0].trim();
  if (!last) last = first;
  return [first, last];
}

// —— 字符偏移 → 1-based 行号 ——
function lineOf(text, charIdx) {
  return text.slice(0, charIdx).split('\n').length;
}

// —— 全文件搜索锚点片段，返回首个命中行的 1-based 行号（定位真实行号用）——
function locateLine(text, frag) {
  const t = frag.trim();
  if (!t) return null;
  const i = text.indexOf(t);
  if (i === -1) return null;
  return lineOf(text, i);
}

// —— 全文件搜索末锚的最后一个命中行（定位真实末行用）——
function locateLineLast(text, frag) {
  const t = frag.trim();
  if (!t) return null;
  const i = text.lastIndexOf(t);
  if (i === -1) return null;
  return lineOf(text, i);
}

// —— 双锚点校验：{ status: 'ok' | 'mismatch' | 'unverified' | 'weak-invalid' } ——
// 精确位置校验：首锚命中 [docStart, docStart+2] 行窗、末锚命中 [docEnd-2, docEnd] 行窗
// （容忍区间首/末行为纯括号等平凡行时取相邻非平凡行的情况）。
// 位置校验失败 → 全文件搜索锚点算出真实行号（MISMATCH 供覆盖）；搜索失败 → UNVERIFIED。
function verifyAnchor(fileText, cit) {
  const { first, last } = cit.fingerprint;
  const hasLast = last !== first;
  if (!isUsableAnchor(first) || (hasLast && !isUsableAnchor(last))) {
    return { status: 'weak-invalid' };
  }
  const lines = fileText.split('\n');
  const s = cit.docStart - 1; // 0-based 首行
  const e = cit.docEnd - 1;   // 0-based 末行
  const inWindow = (lo, hi, anchor) => {
    for (let i = lo; i <= hi; i++) {
      const l = lines[i];
      if (l != null && l.trimStart().startsWith(anchor)) return true;
    }
    return false;
  };
  const startHit = inWindow(s, s + 2, first);
  const endHit = hasLast ? inWindow(e - 2, e, last) : null;
  if (startHit && (endHit === null || endHit)) {
    return { status: 'ok' };
  }
  const trueStart = locateLine(fileText, first);
  if (trueStart == null) return { status: 'unverified' };
  let trueEnd;
  if (hasLast) {
    const le = locateLineLast(fileText, last);
    trueEnd = le != null && le >= trueStart ? le : trueStart + (cit.docEnd - cit.docStart);
  } else {
    trueEnd = trueStart + (cit.docEnd - cit.docStart);
  }
  return { status: 'mismatch', trueStart, trueEnd };
}

// —— 旧 snippet 格式在真实源码里定位真实行号（1-based），存量兼容 ——
function locateSnippet(text, snippet) {
  snippet = snippet.replace(/\n+$/, '');
  if (!snippet) return null;
  // ① 精确整段搜索
  const pos = text.indexOf(snippet);
  if (pos !== -1) {
    const start = text.slice(0, pos).split('\n').length;
    const end = start + snippet.split('\n').length - 1;
    return { start, end };
  }
  // ② 退化策略：以 snippet 首非空行为锚点
  const first = snippet.split('\n').map((l) => l.trim()).find((l) => l.length > 0);
  if (first) {
    const idx = text.indexOf(first);
    if (idx !== -1) {
      const start = text.slice(0, idx).split('\n').length;
      const end = start + snippet.split('\n').length - 1;
      return { start, end };
    }
  }
  return null;
}

// —— 路径校验：返回 { status: 'ok'|'traversal'|'missing', path, reason } ——
// 先 resolve 处理 `..` 并判断是否越出根（捕获明显穿越）；
// 再 realpath 处理符号链接；realpath 成功但越界 → traversal；文件不存在 → missing。
function safeResolve(repoRoot, relPath) {
  const repo = realpathSync(repoRoot);
  const resolved = resolve(join(repo, relPath));
  if (!isWithinRoot(repo, resolved)) {
    return { status: 'traversal', path: null, reason: '路径经 resolve 后越出 source_repo 根' };
  }
  let real;
  try {
    real = realpathSync(resolved);
  } catch {
    return { status: 'missing', path: null, reason: '目标不存在或不可解析' };
  }
  if (!isWithinRoot(repo, real)) {
    return { status: 'traversal', path: null, reason: '路径经 realpath 解析后越出 source_repo 根（符号链接逃逸）' };
  }
  return { status: 'ok', path: real, reason: null };
}

// —— 收集全部指纹注释（anchor 与旧 snippet 统一列表，按行号排序）——
function collectFingerprints(text) {
  const out = [];
  let m;
  ANCHOR_RE.lastIndex = 0;
  while ((m = ANCHOR_RE.exec(text)) !== null) {
    const b64 = m[1];
    const raw = m[2];
    let content = null;
    if (b64) {
      try { content = Buffer.from(b64, 'base64').toString('utf8'); } catch { content = null; }
    } else if (raw !== undefined && !raw.includes('--')) {
      content = raw.trim();
    }
    if (content) {
      const [first, last] = splitAnchors(content);
      out.push({ lineNo: lineOf(text, m.index), kind: 'anchor', first, last });
    }
  }
  LEGACY_FINGERPRINT_RE.lastIndex = 0;
  while ((m = LEGACY_FINGERPRINT_RE.exec(text)) !== null) {
    const b64 = m[1];
    const raw = m[2];
    let snippet = null;
    if (b64) {
      try { snippet = Buffer.from(b64, 'base64').toString('utf8'); } catch { snippet = null; }
    } else if (raw !== undefined && !raw.includes('--')) {
      snippet = raw.trim();
    }
    if (snippet) {
      out.push({ lineNo: lineOf(text, m.index), kind: 'legacy', snippet });
    }
  }
  out.sort((a, b) => a.lineNo - b.lineNo);
  return out;
}

// —— 解析文档：返回 [{ path, docStart, docEnd, lineNo, fingerprint }] ——
function parseCitations(text) {
  const citations = [];
  let m;
  CITATION_RE.lastIndex = 0;
  while ((m = CITATION_RE.exec(text)) !== null) {
    citations.push({
      path: m[1],
      docStart: parseInt(m[2], 10),
      docEnd: parseInt(m[3], 10),
      lineNo: lineOf(text, m.index),
      fingerprint: null,
    });
  }
  const fingerprints = collectFingerprints(text);
  // 引用 ↔ 指纹配对：取"注释行号 ∈ [引用行, 引用行 + PROXIMITY]"的最先一个；已用即消耗。
  let fi = 0;
  for (const cit of citations) {
    while (fi < fingerprints.length && fingerprints[fi].lineNo < cit.lineNo) fi += 1;
    if (fi < fingerprints.length && fingerprints[fi].lineNo <= cit.lineNo + FINGERPRINT_PROXIMITY) {
      cit.fingerprint = fingerprints[fi];
      fi += 1;
    }
  }
  return citations;
}

function readSources(filePaths) {
  if (filePaths.length > 0) {
    return filePaths.map((p) => {
      const abs = resolve(p);
      try {
        return { name: abs, text: readFileSync(abs, 'utf8') };
      } catch (err) {
        throw new Error(`无法读取文件 ${p}: ${err.message}`);
      }
    });
  }
  return null;
}

/**
 * --diff 增量预检：把"现有解读文档的引用 ↔ 当前源码"重解析为规划输入清单。
 * 信息源单一 = 文档自身指纹锚点；不读任何外置清单文件。
 * 状态语义如下：
 *   STABLE       锚点精确匹配且行号吻合 → 论断可信，增量不重写该章节。
 *   STALE        锚点能定位但行号已移动 → 按真实行号复核该论断章节。
 *   UNRESOLVED   路径/锚点定位失败    → 证据已消失，需重新核实或移除该论断。
 * 返回 allStable：全部 STABLE 为 true（供 noop 止损：无 STALE/UNRESOLVED 则无需增量）。
 */
function runDiff(repoReal, sources) {
  let stableCount = 0;
  let staleCount = 0;
  let unresolvedCount = 0;
  const lines = [];
  for (const src of sources) {
    const citations = parseCitations(src.text);
    if (citations.length === 0) continue;
    for (const cit of citations) {
      const display = `${cit.path}:${cit.docStart}-${cit.docEnd}`;
      const resolved = safeResolve(repoReal, cit.path);
      if (resolved.status === 'traversal' || resolved.status === 'missing') {
        unresolvedCount += 1;
        lines.push(`- \`${display}\` → UNRESOLVED（文件缺失或越界，论断证据已消失，需重新核实或移除）`);
        continue;
      }
      let fileText;
      try {
        fileText = readFileSync(resolved.path, 'utf8');
      } catch {
        unresolvedCount += 1;
        lines.push(`- \`${display}\` → UNRESOLVED（文件不可读）`);
        continue;
      }
      if (!cit.fingerprint) {
        unresolvedCount += 1;
        lines.push(`- \`${display}\` → UNRESOLVED（无指纹注释，无法确认真伪，需人工复核）`);
        continue;
      }
      if (cit.fingerprint.kind === 'legacy') {
        const loc = locateSnippet(fileText, cit.fingerprint.snippet);
        if (!loc) {
          unresolvedCount += 1;
          lines.push(`- \`${display}\` → UNRESOLVED（snippet 定位失败）`);
        } else if (loc.start === cit.docStart && loc.end === cit.docEnd) {
          stableCount += 1;
          lines.push(`- \`${display}\` → STABLE`);
        } else {
          staleCount += 1;
          lines.push(`- \`${display}\` → STALE（真实行号 ${loc.start}-${loc.end}，请以真实行号复核）`);
        }
        continue;
      }
      const res = verifyAnchor(fileText, cit);
      if (res.status === 'ok') {
        stableCount += 1;
        lines.push(`- \`${display}\` → STABLE`);
      } else if (res.status === 'mismatch') {
        staleCount += 1;
        lines.push(`- \`${display}\` → STALE（真实行号 ${res.trueStart}-${res.trueEnd}，请以真实行号复核该论断）`);
      } else if (res.status === 'weak-invalid') {
        stableCount += 1;
        lines.push(`- \`${display}\` → STABLE-WEAK（锚点过短仅弱校验，建议补 ≥6 字符含标识符锚点）`);
      } else {
        unresolvedCount += 1;
        lines.push(`- \`${display}\` → UNRESOLVED（锚点定位失败，需人工复核）`);
      }
    }
  }
  console.log('## 引用增量预检（verify-references.mjs --diff）');
  lines.forEach((l) => console.log(l));
  console.log(`\n预检汇总：STABLE=${stableCount} STALE=${staleCount} UNRESOLVED=${unresolvedCount}`);
  return unresolvedCount === 0 && staleCount === 0;
}

async function main() {
  let args = process.argv.slice(2).filter((a) => a !== '--');
  let diffMode = false;
  if (args[0] === '--diff') {
    diffMode = true;
    args = args.slice(1);
  }
  if (args.length < 1) {
    console.error(
      diffMode
        ? '用法：node verify-references.mjs --diff <source_repo> [解读.md ...]'
        : '用法：node verify-references.mjs <source_repo> [解读.md ...]（解读.md 省略时从 stdin 读）',
    );
    process.exit(2);
  }
  const repoRoot = resolve(args[0]);
  let repoReal;
  try { repoReal = realpathSync(repoRoot); } catch {
    console.error(`[verify-references] source_repo 路径不存在或不可读：${repoRoot}`);
    process.exit(2);
  }

  const files = args.slice(1);
  let sources = readSources(files);
  if (!sources) {
    const chunks = [];
    stdin.on('data', (c) => chunks.push(c));
    await new Promise((res) => stdin.once('end', res));
    sources = [{ name: '<stdin>', text: chunks.join('') }];
  }
  let okCount = 0;
  let weakCount = 0;
  let mismatchCount = 0;
  let unverifiedCount = 0;
  let traversalCount = 0;

  if (diffMode) {
    const allStable = runDiff(repoReal, sources);
    stdout.write('', () => process.exit(allStable ? 0 : 1));
    return;
  }

  for (const src of sources) {
    const citations = parseCitations(src.text);
    if (citations.length === 0) {
      console.log(`[${src.name}] 未发现 [path:start-end]() 引用`);
      continue;
    }
    console.log(`[${src.name}] 共 ${citations.length} 条引用`);
    for (const cit of citations) {
      const display = `${cit.path}:${cit.docStart}-${cit.docEnd}（文档第 ${cit.lineNo} 行）`;
      // 1) 路径校验（穿越 / 缺失 / 正常）
      const resolved = safeResolve(repoReal, cit.path);
      if (resolved.status === 'traversal') {
        traversalCount += 1;
        console.log(`[GROUNDER-TRAVERSAL] ${display} —— ${resolved.reason}`);
        continue;
      }
      if (resolved.status === 'missing') {
        unverifiedCount += 1;
        console.log(`[GROUNDER-UNVERIFIED] ${display} —— 文件不存在或不可读`);
        continue;
      }
      // 2) 读源文件
      let fileText;
      try { fileText = readFileSync(resolved.path, 'utf8'); } catch {
        unverifiedCount += 1;
        console.log(`[GROUNDER-UNVERIFIED] ${display} —— 文件存在但读取失败`);
        continue;
      }
      // 3) 定位：有指纹 → 精确验证；无指纹 → 弱校验
      if (cit.fingerprint) {
        if (cit.fingerprint.kind === 'anchor') {
          const res = verifyAnchor(fileText, cit);
          if (res.status === 'ok') {
            okCount += 1;
            console.log(`[GROUNDER-OK] ${display} —— 首末行锚点双向验证通过`);
          } else if (res.status === 'mismatch') {
            mismatchCount += 1;
            console.log(`[GROUNDER-MISMATCH] ${display} → 真实行号 ${res.trueStart}-${res.trueEnd}，请用真实行号覆盖文档标注`);
          } else if (res.status === 'weak-invalid') {
            weakCount += 1;
            console.log(`[GROUNDER-WEAK] ${display} —— 锚点过短（<6 字符）或纯标点，仅弱校验通过；请用 ≥6 字符、含标识符的行作锚点`);
          } else {
            unverifiedCount += 1;
            console.log(`[GROUNDER-UNVERIFIED] ${display} —— 锚点在源码中定位失败，请人工复核（保留原样并标 [UNVERIFIED]）`);
          }
        } else {
          const loc = locateSnippet(fileText, cit.fingerprint.snippet);
          if (!loc) {
            unverifiedCount += 1;
            console.log(`[GROUNDER-UNVERIFIED] ${display} —— snippet 在源码中定位失败，请人工复核（保留原样并标 [UNVERIFIED]）`);
            continue;
          }
          if (loc.start === cit.docStart && loc.end === cit.docEnd) {
            okCount += 1;
            console.log(`[GROUNDER-OK] ${display} —— 行号吻合（旧 snippet 格式）`);
          } else {
            mismatchCount += 1;
            console.log(`[GROUNDER-MISMATCH] ${display} → 真实行号 ${loc.start}-${loc.end}，请用真实行号覆盖文档标注`);
          }
        }
      } else {
        // 弱校验：文件可读 + 行号区间未越界
        const lineCount = fileText.split('\n').length;
        if (cit.docStart >= 1 && cit.docEnd <= lineCount) {
          weakCount += 1;
          console.log(`[GROUNDER-WEAK] ${display} —— 无指纹注释，仅弱校验通过（文件可读、行号未越界）；建议为该引用补充首末行锚点以获得精确行号验证`);
        } else {
          unverifiedCount += 1;
          console.log(`[GROUNDER-UNVERIFIED] ${display} —— 无指纹注释且行号区间越界文件行数（${lineCount} 行），请人工复核`);
        }
      }
    }
  }

  console.log(`\n校验结果：OK=${okCount} WEAK=${weakCount} MISMATCH=${mismatchCount} UNVERIFIED=${unverifiedCount} TRAVERSAL=${traversalCount}`);
  if (traversalCount > 0) {
    console.log('存在路径穿越，请立即修复（可能是幻觉路径或漏了防穿越）。');
    process.exitCode = 2;
  } else if (mismatchCount > 0 || unverifiedCount > 0) {
    console.log('存在需人工复核的引用：MISMATCH 用真实行号覆盖；UNVERIFIED 保留原样并标 [UNVERIFIED] 供复核。');
    process.exitCode = 1;
  } else {
    console.log('全部引用经程序校验通过。');
    process.exitCode = 0;
  }
  stdout.write('', () => process.exit());
}

main().catch((err) => {
  console.error(err.message);
  process.exit(2);
});
