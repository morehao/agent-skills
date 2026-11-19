#!/usr/bin/env node
/**
 * 题源核验：手册里的「题源」引文，是否真的出自简历原文。
 *
 * 用法：
 *   node verify-sources.mjs <手册.md>... --resume <简历.txt>
 *
 * 退出码：0 全部定位到 / 1 有引文找不到 / 2 用法或读取错误。
 *
 * 判定三档：
 *   OK    归一化后逐字存在
 *   NEAR  只差几个字符（PDF 抽取的水印/断行噪声），打印距离供人复核
 *   MISS  找不到，判失败
 *
 * 它只回答「这段话在不在原文里」。位置标得对不对（项目经历 vs 工作经历）它不管——
 * 那需要简历的结构信息，交给人读。
 */

import { readFileSync, existsSync } from 'node:fs';

const USAGE = `用法：
  node verify-sources.mjs <手册.md>... --resume <简历.txt>

退出码：0 全部定位到 / 1 有引文找不到 / 2 用法或读取错误`;

function normalize(text) {
  return text
    .normalize('NFKC')
    .replace(/[\s\u3000\u00a0\u200b-\u200d\ufeff]/g, '')
    .toLowerCase();
}

function levenshtein(a, b) {
  const m = a.length;
  const n = b.length;
  if (Math.abs(m - n) > 40) return Math.max(m, n);
  let prev = Array.from({ length: n + 1 }, (_, j) => j);
  for (let i = 1; i <= m; i += 1) {
    const cur = [i];
    for (let j = 1; j <= n; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
    }
    prev = cur;
  }
  return prev[n];
}

/** 在原文里找引文：先取若干锚点定位，再用编辑距离确认。 */
function locate(quote, haystack) {
  const len = quote.length;
  // 数字守卫：编辑距离会把「75% → 90%」当成 2 个小改动放过，而改数字正是最该抓的。
  const numbers = quote.match(/\d{2,}/g) ?? [];
  for (const n of numbers) {
    if (!haystack.includes(n)) return { verdict: 'MISS', distance: Infinity, note: `数字 ${n} 不在原文` };
  }
  if (len < 6) return { verdict: 'MISS', distance: Infinity, note: '引文过短，无法核验' };
  // 短句给 3–4 字余量（PDF 水印会在句中插字），长句封顶 8 字，避免把改写当噪声放过。
  const tolerance = Math.min(8, Math.max(3, Math.ceil(len * 0.12)));
  const anchors = [Math.floor(len / 2), 0, Math.max(0, len - 10)].map((start) =>
    quote.slice(start, Math.min(len, start + 10)),
  );

  let best = Infinity;
  for (const anchor of anchors) {
    if (anchor.length < 6) continue;
    let from = 0;
    let hits = 0;
    while (hits < 40) {
      const at = haystack.indexOf(anchor, from);
      if (at === -1) break;
      hits += 1;
      from = at + 1;
      const offset = quote.indexOf(anchor);
      const start = Math.max(0, at - offset);
      // 锚点前面可能被水印插了字，导致起点偏移；在 ±4 字内滑窗取最小距离。
      for (let shift = -4; shift <= 4; shift += 1) {
        const from = start + shift;
        if (from < 0) continue;
        const window = haystack.slice(from, from + len + 8);
        best = Math.min(best, levenshtein(quote, window.slice(0, len)));
        if (best === 0) return { verdict: 'OK', distance: 0 };
      }
    }
  }
  if (best <= tolerance) return { verdict: 'NEAR', distance: best, tolerance };
  return { verdict: 'MISS', distance: best, tolerance };
}

function extractQuotes(value) {
  const quotes = [];
  const pattern = /[「“]([^」”]{4,})[」”]/g;
  for (const match of value.matchAll(pattern)) {
    // 「前段 ... 后段」是合法的省略写法：按段分别核验，省略处不要求匹配。
    const segments = match[1]
      .split(/\.{3,}|…+/)
      .map((s) => s.trim())
      .filter((s) => normalize(s).length >= 4);
    quotes.push(...segments);
  }
  return quotes;
}

function collectSources(lines) {
  const sources = [];
  let current = null;
  for (let i = 0; i < lines.length; i += 1) {
    const heading = /^###\s+(Q\d+)\b\s*(.*)$/.exec(lines[i]);
    if (heading) {
      current = { id: heading[1], title: heading[2].trim(), line: i + 1 };
      continue;
    }
    if (/^##\s+/.test(lines[i])) current = null;
    if (!current) continue;
    const field = /^-\s*题源[：:]\s*(.*)$/.exec(lines[i]);
    if (field) {
      sources.push({ ...current, value: field[1], line: i + 1, quotes: extractQuotes(field[1]) });
    }
  }
  return sources;
}

function main() {
  const args = process.argv.slice(2);
  if (args.includes('--help') || args.includes('-h')) {
    console.log(USAGE);
    return 0;
  }
  const resumeIndex = args.indexOf('--resume');
  if (resumeIndex === -1 || !args[resumeIndex + 1]) {
    console.error(`缺 --resume <简历.txt>\n\n${USAGE}`);
    return 2;
  }
  const resumePath = args[resumeIndex + 1];
  const files = args.filter((a, i) => !a.startsWith('-') && i !== resumeIndex + 1);
  if (!files.length) {
    console.error(USAGE);
    return 2;
  }
  if (!existsSync(resumePath)) {
    console.error(`简历文本不存在：${resumePath}`);
    return 2;
  }

  const haystack = normalize(readFileSync(resumePath, 'utf8'));
  let miss = 0;
  let near = 0;
  let ok = 0;
  let checked = 0;

  for (const file of files) {
    if (!existsSync(file)) {
      console.error(`手册不存在：${file}`);
      return 2;
    }
    const lines = readFileSync(file, 'utf8').split(/\r?\n/);
    const sources = collectSources(lines);
    if (!sources.length) {
      console.log(`[SRC-NONE] ${file} 没有找到「- 题源：」字段`);
      continue;
    }
    for (const source of sources) {
      if (!source.quotes.length) {
        miss += 1;
        console.log(`[SRC-MISS] ${file}:${source.line} ${source.id} 题源没有「」/“”引文`);
        continue;
      }
      for (const quote of source.quotes) {
        checked += 1;
        const result = locate(normalize(quote), haystack);
        if (result.verdict === 'OK') {
          ok += 1;
        } else if (result.verdict === 'NEAR') {
          near += 1;
          console.log(
            `[SRC-NEAR] ${file}:${source.line} ${source.id} 与原文差 ${result.distance} 字（容差 ${result.tolerance}），可能是抽取噪声，请人工确认：${quote.slice(0, 24)}…`,
          );
        } else {
          miss += 1;
          console.log(`[SRC-MISS] ${file}:${source.line} ${source.id} 在简历文本里找不到：${quote.slice(0, 40)}…`);
        }
      }
    }
  }

  console.log(`\n${miss === 0 ? 'PASS' : 'FAIL'} — ${checked} 条引文：${ok} 条逐字命中 / ${near} 条近似 / ${miss} 条找不到`);
  if (near) console.log('近似命中不阻断：请人工确认这句是否真在原文里（PDF 水印会造成插入噪声）。');
  return miss === 0 ? 0 : 1;
}

process.exit(main());
