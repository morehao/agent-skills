#!/usr/bin/env node
// scan-narrative.mjs —— 「叙述型架构设计文档」的核实机制
//
// 用途：校验一篇**零代码索引**的架构设计文档是否真的做到了它声称的事。
// 叙述型文档放弃了「逐条可验证引用」这层防幻觉机制，本脚本负责补上可程序化
// 的那部分约束；不可程序化的部分（论断能否回指证据型文档）留给人工复核，
// 并在输出中显式提示。
//
// 用法：
//   node scan-narrative.mjs <narrative.md> [more.md ...]
//   node scan-narrative.mjs --repo-root <dir> <narrative.md>   # 额外校验 md 引用的 SVG 资产
//
// 退出码：0 = 全部通过；1 = 存在违规（逐条列出）。
//
// 检查项：
//   [CODE-INDEX]    正文出现 `路径.ext:行号` 形式的代码索引
//   [ANCHOR]        正文出现 `<!-- anchor: ... -->` 锚点指纹
//   [REPO-PATH]     正文出现仓库相对源码路径（如 internal/...、cmd/...）
//   [CROSS-DOC]     正文链接到同目录其它解读文档（叙述型必须与证据型完全隔离）
//   [DETAILS-CODE]  <details> 折叠块里不能藏代码索引（藏起来也算出现）
//   [SVG-MISSING]   引用的 .svg 资产不存在（需 --repo-root）
//   [SVG-EXTERNAL]  SVG 含外部资源引用或禁用特性（自包含约束）
//   [SVG-NO-META]   SVG 缺 <title> 或 <desc>（允许带属性，如 <title id="...">）
//   [HEADING-SEQ]   标题编号重复 / 与所属章不一致 / 未递增（叙述型文档允许 ## 一、 与 ### N.M 编号）
//   [XREF-DANGLING] 正文的「见 N.M / 第N章 / 附录 X」指向不存在的章节
//   [COST-MISSING]  「设计决策/取舍」章节存在，但通篇没有"代价"类表述（警告级）
//   [NO-FIGURE]     通篇既无 mermaid 块也无 .svg 引用（警告级）
//   [FIGURE-ONLY]   某小节只有图、没有正文（警告级）
//   [HEADING-SEQ-GAP] 小节编号跳号（警告级）

import { readFileSync, existsSync, realpathSync } from 'node:fs';
import { resolve, dirname, join, basename } from 'node:path';

// —— 允许出现的「宿主机绝对路径」（文档自我说明用），不属于代码索引 ——
const ALLOWED_ABS = [/https?:\/\//, /^\/Users\//, /^\/home\//, /^~\/\.dsh\//];

const RULES = [
  {
    id: 'CODE-INDEX',
    level: 'error',
    // `path/to/file.ext:123` 或 `path.ext:123-456`
    re: /[A-Za-z0-9_./-]+\.[A-Za-z][A-Za-z0-9]{0,5}:\d{1,5}(?:-\d{1,5})?/g,
    why: '叙述型文档不得出现「路径:行号」式代码索引',
  },
  {
    id: 'ANCHOR',
    level: 'error',
    re: /<!--\s*anchor(?:-base64)?:/g,
    why: '叙述型文档不得含锚点指纹（那是证据型文档的机制）',
  },
  {
    id: 'REPO-PATH',
    level: 'error',
    // 仓库相对源码路径：形如 internal/...、cmd/...、pkg/a/b.go
    // 要求：源码顶层目录 + 该段至少含一个「长段（≥3 字符）」或一个文件扩展名，
    // 以排除 `api/ingestor 模式` 这类运行模式写法造成的误判。
    re: /(?<![\w/.-])(?:(?:internal|cmd|src|lib|pkg|docker|conf|scripts|sdk|deepdoc)\/[A-Za-z0-9_./-]+|(?:agent|deepdoc|rag|app)\/(?:[A-Za-z0-9_.-]{3,}(?:\/[A-Za-z0-9_./-]*)?|\S*\.[A-Za-z]\w{0,5}))/g,
    why: '叙述型文档不得出现仓库相对源码路径',
  },
  {
    id: 'CROSS-DOC',
    level: 'error',
    // 指向同目录其它 .md 的链接（排除外部 URL）
    re: /\]\((?!https?:\/\/)([A-Za-z0-9_./-]+\.md)\)/g,
    why: '叙述型文档必须与证据型文档完全隔离，不得互相引用',
  },
];

function stripCodeFences(text) {
  // 保留 mermaid 块（其中可能含行号？不会），屏蔽普通代码块，避免误报示例
  return text.replace(/^```(?!mermaid)[\s\S]*?^```/gm, (m) => m.replace(/[^\n]/g, ' '));
}

function scanText(text, file) {
  const hits = [];
  const scannable = stripCodeFences(text);
  for (const rule of RULES) {
    rule.re.lastIndex = 0;
    let m;
    while ((m = rule.re.exec(scannable)) !== null) {
      const raw = m[1] ?? m[0];
      if (ALLOWED_ABS.some((a) => a.test(raw))) continue;
      // CROSS-DOC 只关心"同目录的解读文档"，即不带目录前缀的 *.md
      if (rule.id === 'CROSS-DOC' && raw.includes('/')) continue;
      const line = scannable.slice(0, m.index).split('\n').length;
      hits.push({ id: rule.id, level: rule.level, file, line, text: raw.slice(0, 80), why: rule.why });
    }
  }
  // details 块内不得藏代码索引
  for (const m of text.matchAll(/<details>[\s\S]*?<\/details>/g)) {
    for (const rule of RULES.filter((r) => r.id === 'CODE-INDEX' || r.id === 'ANCHOR')) {
      rule.re.lastIndex = 0;
      let mm;
      while ((mm = rule.re.exec(m[0])) !== null) {
        const line = text.slice(0, m.index + mm.index).split('\n').length;
        hits.push({ id: 'DETAILS-CODE', level: 'error', file, line, text: (mm[0] || '').slice(0, 80), why: '折叠块内同样不得出现代码索引' });
      }
    }
  }
  return hits;
}

function scanSvg(p, file, line) {
  const hits = [];
  const s = readFileSync(p, 'utf8');
  const ext = /(?:href|src|xlink:href)\s*=\s*["'](?!#)[^"']+|<script|<foreignObject|<image|url\((?!#)/g;
  for (const m of s.matchAll(ext)) {
    hits.push({ id: 'SVG-EXTERNAL', level: 'error', file, line, text: m[0].slice(0, 60), why: 'SVG 必须自包含：不得引用外部资源或用禁用标签' });
  }
  // 允许带属性的写法（<title id="...">、role/aria-*）：按标签名匹配，不做字面串匹配
  if (!/<title[\s>]/.test(s) || !/<desc[\s>]/.test(s)) {
    hits.push({ id: 'SVG-NO-META', level: 'error', file, line, text: basename(p), why: 'SVG 必须有 <title> 与 <desc>' });
  }
  return hits;
}

// —— 标题编号 / 交叉引用 / 孤立图 ——
// 叙述型文档使用 `## 一、` 与 `### N.M` 编号（设计文档惯例，交叉引用依赖它），
// 因此需要程序兜住"重排后编号重复、引用失效"这类错误；未采用编号体系的文档自动跳过。

const CN_DIGIT = { 零: 0, 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };

function cn2num(s) {
  if (/^\d+$/.test(s)) return Number(s);
  let n = 0, cur = 0, seen = false;
  for (const ch of s) {
    if (ch === '十') { n += (cur || 1) * 10; cur = 0; seen = true; }
    else if (CN_DIGIT[ch] !== undefined) { cur = CN_DIGIT[ch]; seen = true; }
    else return null;
  }
  return seen ? n + cur : null;
}

function scanStructure(text, file) {
  const hits = [], warns = [];
  const lines = text.split('\n');
  const heads = [];
  lines.forEach((ln, i) => {
    const m = /^(#{2,3})\s+(.+?)\s*$/.exec(ln);
    if (!m) return;
    const level = m[1].length;
    const t = m[2];
    let ch = null, sub = null;
    if (level === 2) {
      const c = /^([一二三四五六七八九十百零\d]+)\s*[、.．,]/.exec(t);
      if (c) ch = cn2num(c[1]);
    } else {
      const s = /^(\d+)\s*\.\s*(\d+)/.exec(t);
      if (s) { ch = Number(s[1]); sub = Number(s[2]); }
    }
    heads.push({ level, ch, sub, line: i + 1, text: t });
  });

  const useNumbering = heads.some((h) => h.ch !== null);
  if (useNumbering) {
    // 1) 章序号唯一
    const seenCh = new Map();
    for (const h of heads.filter((h) => h.level === 2 && h.ch !== null)) {
      if (seenCh.has(h.ch)) {
        hits.push({ id: 'HEADING-SEQ', level: 'error', file, line: h.line, text: h.text.slice(0, 60), why: `章序号「${h.ch}」重复（首次出现在第 ${seenCh.get(h.ch)} 行）` });
      } else seenCh.set(h.ch, h.line);
    }
    // 2) 小节编号：唯一 / 属章正确 / 同章递增
    const seenSec = new Map();
    let curCh = null, lastSub = 0;
    for (const h of heads) {
      if (h.level === 2 && h.ch !== null) { curCh = h.ch; lastSub = 0; continue; }
      if (h.level !== 3 || h.sub === null) continue;
      const key = `${h.ch}.${h.sub}`;
      if (seenSec.has(key)) {
        hits.push({ id: 'HEADING-SEQ', level: 'error', file, line: h.line, text: h.text.slice(0, 60), why: `小节编号「${key}」重复（首次出现在第 ${seenSec.get(key)} 行）` });
      } else seenSec.set(key, h.line);
      if (curCh !== null && h.ch !== curCh) {
        hits.push({ id: 'HEADING-SEQ', level: 'error', file, line: h.line, text: h.text.slice(0, 60), why: `小节编号「${key}」与所属章「${curCh}」不一致` });
      }
      if (h.ch === curCh) {
        if (h.sub <= lastSub) {
          hits.push({ id: 'HEADING-SEQ', level: 'error', file, line: h.line, text: h.text.slice(0, 60), why: `小节编号未递增（前一个为 ${h.ch}.${lastSub}）` });
        } else if (lastSub && h.sub > lastSub + 1) {
          warns.push({ id: 'HEADING-SEQ-GAP', file, line: h.line, text: '', why: `小节编号跳号：${h.ch}.${lastSub} → ${h.ch}.${h.sub}` });
        }
        lastSub = Math.max(lastSub, h.sub);
      }
    }
    // 3) 交叉引用可解析（只在「见 / 参见 / 详见 / 呼应 + 编号」与「第N章」「附录 X」处判定，
    //    避免把 "3.1 GB" 这类数字误判成引用）
    const validSec = new Set(seenSec.keys());
    const validCh = new Set(seenCh.keys());
    const appendix = new Set(
      heads.map((h) => /^附录\s*([A-Z])/.exec(h.text)).filter(Boolean).map((m) => m[1]),
    );
    const scannable = stripCodeFences(text);
    const refs = [
      [/(?:见|参见|详见|呼应)\s*(\d+)\s*\.\s*(\d+)/g, (m) => `${m[1]}.${m[2]}`, validSec, '小节'],
      [/第\s*([一二三四五六七八九十百零\d]+)\s*章/g, (m) => cn2num(m[1]), validCh, '章'],
      [/附录\s*([A-Z])/g, (m) => m[1], appendix, '附录'],
    ];
    for (const [re, key, valid, kind] of refs) {
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(scannable)) !== null) {
        const k = key(m);
        if (k === null || valid.has(k)) continue;
        const line = scannable.slice(0, m.index).split('\n').length;
        hits.push({ id: 'XREF-DANGLING', level: 'error', file, line, text: m[0].slice(0, 40), why: `引用的${kind}「${k}」不存在` });
      }
    }
  }

  // 4) 孤立图：小节内除图之外没有任何内容（图前需导读段、图后需着落）
  const bounds = heads.map((h, idx) => ({
    ...h,
    end: idx + 1 < heads.length ? heads[idx + 1].line - 1 : lines.length,
  }));
  for (const b of bounds) {
    const body = lines.slice(b.line, b.end);
    if (!body.some((l) => /^\s*!\[/.test(l) || /^\s*```mermaid/.test(l))) continue;
    const hasOther = body.some((l) => {
      const s = l.trim();
      if (!s) return false;
      if (/^!\[/.test(s)) return false;
      if (/^```/.test(s)) return false;
      if (/^<!--/.test(s)) return false;
      if (/^#{1,6}\s/.test(s)) return false;
      if (/^<\/?(div|p|br|img|figure|figcaption)\b/i.test(s)) return false;
      return true;
    });
    if (!hasOther) {
      warns.push({ id: 'FIGURE-ONLY', file, line: b.line, text: b.text.slice(0, 40), why: '该小节只有图、没有正文：图前需要导读段，图后需要读图要点' });
    }
  }
  return { hits, warns };
}

function main() {
  const argv = process.argv.slice(2);
  let repoRoot = null;
  const files = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--repo-root') { repoRoot = argv[++i]; continue; }
    files.push(argv[i]);
  }
  if (files.length === 0) {
    console.error('用法: node scan-narrative.mjs [--repo-root <dir>] <narrative.md> [...]');
    process.exit(2);
  }

  const hits = [];
  const warns = [];
  for (const f of files) {
    if (!existsSync(f)) { hits.push({ id: 'MISSING-FILE', level: 'error', file: f, line: 0, text: f, why: '文件不存在' }); continue; }
    const text = readFileSync(f, 'utf8');
    hits.push(...scanText(text, f));
    const struct = scanStructure(text, f);
    hits.push(...struct.hits);
    warns.push(...struct.warns);

    // SVG 资产
    const dir = repoRoot ? resolve(repoRoot) : dirname(resolve(f));
    for (const m of text.matchAll(/!\[[^\]]*\]\(([^)]+\.svg)\)/g)) {
      const rel = m[1];
      const p = resolve(dir, rel);
      const line = text.slice(0, m.index).split('\n').length;
      if (!existsSync(p)) { hits.push({ id: 'SVG-MISSING', level: 'error', file: f, line, text: rel, why: '引用的 SVG 资产不存在' }); continue; }
      hits.push(...scanSvg(p, f, line));
    }

    // 警告级：图与代价
    const hasMermaid = /^```mermaid/m.test(text);
    const hasSvg = /!\[[^\]]*\]\([^)]+\.svg\)/.test(text);
    if (!hasMermaid && !hasSvg) warns.push({ id: 'NO-FIGURE', file: f, line: 0, text: '', why: '通篇无任何图（mermaid 或 svg）' });
    const decisionSec = /^##+.*(设计决策|关键取舍|取舍与代价|设计权衡)/m.test(text);
    if (decisionSec && !/代价|权衡|cost|trade-?off/i.test(text)) {
      warns.push({ id: 'COST-MISSING', file: f, line: 0, text: '', why: '「设计决策」章节存在但通篇未提任何代价/权衡' });
    }
  }

  for (const h of hits) {
    console.log(`[${h.id}] ${h.file}:${h.line} —— ${h.why}：\`${h.text}\``);
  }
  for (const w of warns) {
    const at = w.line ? `${w.file}:${w.line}` : w.file;
    const extra = w.text ? `：\`${w.text}\`` : '';
    console.log(`[${w.id}]（警告）${at} —— ${w.why}${extra}`);
  }
  console.log('');
  if (hits.length === 0) {
    console.log(`核实结果：${files.length} 个叙述型文档通过零索引/自包含/SVG 资产/编号与引用检查${warns.length ? `（另有 ${warns.length} 条警告）` : ''}。`);
    console.log('提示：本脚本只覆盖可程序化的约束。「每条论断能否回指证据型文档」属人工复核项，不落盘、每次改完重跑。');
    process.exit(0);
  }
  console.log(`核实结果：发现 ${hits.length} 处违规${warns.length ? `、${warns.length} 条警告` : ''}，请修复后重跑。`);
  process.exit(1);
}

main();
