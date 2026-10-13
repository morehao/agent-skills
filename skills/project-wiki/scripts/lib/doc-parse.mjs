// doc-parse.mjs —— project-wiki 的文档解析单一真源（零依赖，只用 node 内置模块）。
//
// 为什么单独抽出来：引用解析必须**只有一份实现**。
//   check-docs.mjs（产物质量门禁）与 plan-update.mjs（更新预检）都要从同一批 md 里
//   提取「依据行/行内引用」「代码块」「frontmatter 偏移」。若各写一份正则，
//   两边对同一种写法的判定就会漂移——一边算得出、另一边认不出，而"认不出"是静默的。
//   本文件即这两者共用的唯一解析实现。
//
// 用法：import { extractCitations, extractCodeBlocks, splitFrontmatter } from './lib/doc-parse.mjs';
//   调用方传入的 lines 必须是 text.split('\n') 的结果（行号 = 下标 + 1）。

// 引用：逐个 code span 解析，而不是全文件扫正则——否则"正则不认的写法"会静默漏检。
// PRIMARY：整个 code span 内容就是一个 `路径:行号`（允许 ./ ../ / 开头、允许无扩展名）
// 路径字符类含 `[` `]`：Next.js 之类的动态路由目录名就是 `src/app/[owner]/[repo]/page.tsx`，
// 不收的话这类真实引用会掉进 UNPARSED，等于「看得见却验不了」。
export const PRIMARY_CITATION_RE = /^(?:(?:\.{1,2}\/)+|\/)?[A-Za-z0-9_@][A-Za-z0-9_./@+[\]-]*(?:\.[A-Za-z][A-Za-z0-9]{0,9})?:(\d+)(?:-(\d+))?$/;
// 任意 code span（用于取出候选再分类）
export const CODE_SPAN_RE = /`([^`\n]+)`/g;
// 疑似引用：含 `/` 且以 `:行号` 结尾，但没被 PRIMARY 认出来 → 必须显式告知，不静默放过
export const SUSPECT_CITATION_RE = /\/.*:\d+(?:-\d+)?$/;

/**
 * 归一化引用写法：全角冒号、en/em dash、`#L12` 与 `:L12-L20` 锚点式行号。
 * 不做归一化的话，模型换个写法就绕过了校验——这正是"静默放过"的入口。
 */
export function normalizeSpan(raw) {
  let out = raw.replace(/：/g, ':').replace(/[–—]/g, '-').trim();
  out = out.replace(/#L(\d+)(?:\s*-\s*L?(\d+))?/gi, (_m, a, b) => (b ? `:${a}-${b}` : `:${a}`));
  out = out.replace(/:L(\d+)(?:\s*-\s*L?(\d+))?/gi, (_m, a, b) => (b ? `:${a}-${b}` : `:${a}`));
  return out;
}

/**
 * 从文档行里提取引用。
 *
 * `basis` 标记该引用是否落在「章末依据」块内：依据可以是「一行」，也可以是同一引用块里
 * 折行的「一块」——续行同样算依据。否则长依据列表一折行，后半截就被误判成散落在正文里的
 * 行内引用（从而触发 [DOC-INLINE-REFS] 误报）。
 *
 * 返回 { citations, inlineCitations, unparsed }：
 *   citations       全部引用，含 basis 标记
 *   inlineCitations 仅正文里的行内引用（basis 为 false）
 *   unparsed        形似引用但解析不出（不静默放过）
 */
export function extractCitations(lines) {
  const citations = [];
  const inlineCitations = [];
  const unparsed = [];
  let inBasisBlock = false;
  for (let i = 0; i < lines.length; i += 1) {
    if (/^\s*>?\s*依据\s*[:：]/.test(lines[i])) inBasisBlock = true;
    else if (!(inBasisBlock && /^\s*>/.test(lines[i]))) inBasisBlock = false;
    const isBasis = inBasisBlock;
    CODE_SPAN_RE.lastIndex = 0;
    let m;
    while ((m = CODE_SPAN_RE.exec(lines[i])) !== null) {
      const span = normalizeSpan(m[1]);
      const pm = PRIMARY_CITATION_RE.exec(span);
      if (pm) {
        // 路径 = span 去掉末尾的 `:start[-end]`
        const suffix = pm[0].slice(pm[0].lastIndexOf(':'));
        const rec = {
          path: span.slice(0, span.length - suffix.length),
          start: parseInt(pm[1], 10),
          end: pm[2] ? parseInt(pm[2], 10) : parseInt(pm[1], 10),
          line: i + 1,
          basis: isBasis,
        };
        citations.push(rec);
        if (!isBasis) inlineCitations.push(rec);
      } else if (span.includes('/') && SUSPECT_CITATION_RE.test(span)) {
        unparsed.push({ text: span, line: i + 1 });
      }
    }
  }
  return { citations, inlineCitations, unparsed };
}

/** 提取围栏代码块 [{lang, startLine, endLine, lines}] */
export function extractCodeBlocks(lines) {
  const blocks = [];
  let open = null;
  for (let i = 0; i < lines.length; i += 1) {
    const m = /^\s*```+\s*(\S*)\s*$/.exec(lines[i]);
    if (!m) continue;
    if (open === null) {
      open = { lang: (m[1] || '').toLowerCase(), startLine: i + 1, contentStart: i + 1 };
    } else {
      blocks.push({
        lang: open.lang,
        startLine: open.startLine,
        endLine: i + 1,
        lines: lines.slice(open.contentStart, i),
      });
      open = null;
    }
  }
  if (open !== null) {
    // 未闭合的围栏：按到文末处理，避免整段代码漏检
    blocks.push({ lang: open.lang, startLine: open.startLine, endLine: lines.length, lines: lines.slice(open.contentStart) });
  }
  return blocks;
}

/** 拆 frontmatter：返回 { frontmatter, body, bodyLine }（bodyLine 为正文首行在原文中的行号） */
export function splitFrontmatter(text) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text);
  if (!m) return { frontmatter: null, body: text, bodyLine: 1 };
  return {
    frontmatter: m[1],
    body: text.slice(m[0].length),
    bodyLine: m[0].split('\n').length,
  };
}

/** 正文有效行数（只数散文：围栏块与 frontmatter 不计入）——check-docs 与预检共用同一口径 */
export function countBodyNonEmpty(lines, blocks) {
  const { body, bodyLine } = splitFrontmatter(lines.join('\n'));
  const bodyLines = body.split('\n');
  const fenced = new Set();
  for (const b of blocks) for (let k = b.startLine; k <= b.endLine; k += 1) fenced.add(k);
  return {
    bodyNonEmpty: bodyLines.filter((l, idx) => l.trim() !== '' && !fenced.has(bodyLine + idx)).length,
    bodyLine,
  };
}
