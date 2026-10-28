#!/usr/bin/env node
// check-mermaid.mjs —— 用 mermaid.parse() 真解析 + 对 flowchart 追加 render() 校验
// Markdown 里的所有 mermaid 代码块。
//
// 用法：
//   node check-mermaid.mjs <file.md> [file2.md ...]
//   # 未传参数时从 stdin 读入（配合 CI/管道）
//
// 行为：
//   - 提取每个 ```mermaid ... ``` 代码块，记录其在文件中的全局起止行号。
//   - 对每块调用 mermaid.detectType + mermaid.parse 做真实语法解析。
//   - 对 flowchart/graph 类型额外调用 mermaid.render()，以捕获「子图父链成环」
//     （如 "Setting A as parent of A would create a cycle"，parse 检测不到、render
//     布局期才报错）等布局语义错误；sequence/state 等类型仍只走 parse（纯 jsdom 下
//     render 会误报 DOM 局限）。
//   - render 在纯 jsdom 下的失败根源是**测量为空**：SVG 节点的 getBBox() /
//     getComputedTextLength() / getTotalLength() 默认不存在或返回 0，导致带标签的边
//     算不出落点，抛 "Could not find a suitable point for the given distance"。
//     故补齐垫片：CSSStyleSheet、DOMParser，以及返回非零值的三个测量方法。
//     修好后 `graph` 与 `flowchart` 两种声明都能正常渲染，无需改写图源码。
//   - 全部 OK 则以退出码 0 结束；任一失败打印 [MERMAID-ERROR] 并以非 0 退出码
//     结束（不静默放过，类比引用定位失败的 [UNVERIFIED]）。
//
// 原理：mermaid 默认依赖 DOMPurify（需要 DOM）。此处注入最小 jsdom 垫片，
//       使 mermaid.parse()/render() 能在纯 Node 下以真实解析器工作，而不必引入
//       puppeteer/Chromium。render 还需补 CSSStyleSheet 与 SVG 测量方法垫片（见下）。

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { stdin, stdout } from 'node:process';

// —— 依赖加载与 DOM 垫片 ——
// 脚本依赖 jsdom 与 mermaid。符号链接注册时依赖已就位；
// 复制注册因 scripts/node_modules 被 gitignore，需在 scripts/ 下重新 npm install。
// 注意顺序：先加载 jsdom 并注入全局 window/document/navigator，再加载 mermaid，
//           否则 mermaid 顶层导入 DOMPurify 时拿不到 DOM，parse 会报
//           「DOMPurify.sanitize is not a function」。
let JSDOM;
try {
  JSDOM = (await import('jsdom')).JSDOM;
} catch {
  console.error('[依赖缺失] 缺少 jsdom 依赖，请先在 scripts/ 目录执行：npm install');
  console.error('  （本 skill 通过符号链接注册时依赖已就位；若为复制注册，node_modules 不随 git 提交，需重新安装）');
  process.exit(2);
}

const dom = new JSDOM('', { pretendToBeVisual: true });
globalThis.window = dom.window;
globalThis.document = dom.window.document;
Object.defineProperty(globalThis, 'navigator', {
  value: dom.window.navigator,
  configurable: true,
  writable: true,
});

let mermaid;
try {
  mermaid = (await import('mermaid')).default;
} catch {
  console.error('[依赖缺失] 缺少 mermaid 依赖，请先在 scripts/ 目录执行：npm install');
  process.exit(2);
}

mermaid.initialize({ startOnLoad: false, securityLevel: 'loose' });

// —— 面向 render 阶段的 DOM/SVG 垫片 ——
// mermaid.parse() 只做语法解析，检测不到「子图父链成环」（如把某节点设为自身子图的
// parent，报 "Setting X as parent of X would create a cycle"）这类在 render 布局期
// 才暴露的语义错误。为捕获这类错误，脚本对 flowchart/graph 类型额外调用一次
// mermaid.render()。render 需要完整的 SVG DOM 能力，纯 Node + jsdom 下缺以下方法，
// 逐一补最小垫片（实验验证：补足后 render 能跑完布局并抛出成环错误）：
//   - CSSStyleSheet：render 引入 keyframes / 样式时会访问它
//   - SVGElement 测量方法 getBBox / getComputedTextLength / getTotalLength
// 只对 flowchart/graph 启用 render 校验；sequenceDiagram / stateDiagram 等在纯
// jsdom 下 render 会报「Cannot read properties of null」等 DOM 局限，与本脚本职责
// 无关，仍只走 parse（见 main()）。
const _svgGlobs = ['Element', 'HTMLElement', 'SVGElement', 'SVGSVGElement', 'SVGGraphicsElement', 'Node'];
for (const k of _svgGlobs) {
  if (typeof window[k] !== 'undefined' && globalThis[k] === undefined) globalThis[k] = window[k];
}
if (typeof globalThis.CSSStyleSheet === 'undefined') {
  // render 引入 keyframes / 样式时会访问它；jsdom 自带实现优先，缺了才补最小桩。
  globalThis.CSSStyleSheet = (typeof window.CSSStyleSheet !== 'undefined')
    ? window.CSSStyleSheet
    : class {
        constructor() { this.cssRules = []; }
        insertRule() { return 0; }
        replaceSync() {}
        replace() {}
      };
}
if (typeof globalThis.DOMParser === 'undefined' && typeof window.DOMParser !== 'undefined') {
  // mermaid 解析内联 SVG 时会构造 DOMParser；缺了报 DOMPurify.sanitize is not a function。
  globalThis.DOMParser = window.DOMParser;
}
// 测量方法必须返回**非零**尺寸：全零会让带标签的边算不出落点，render 抛
// "Could not find a suitable point for the given distance"（与图本身无关）。
// 数值取一个固定的小尺寸即可——布局期校验关心的是"能不能算出来"与拓扑语义
// （如子图成环），不关心像素级排版。
const MEASURED_TEXT_WIDTH = 48;
const MEASURED_TEXT_HEIGHT = 18;
for (const C of [globalThis.SVGElement, globalThis.SVGGraphicsElement, globalThis.Element]) {
  if (!C) continue;
  C.prototype.getBBox ??= function () {
    return { x: 0, y: 0, width: MEASURED_TEXT_WIDTH, height: MEASURED_TEXT_HEIGHT };
  };
  C.prototype.getComputedTextLength ??= function () { return MEASURED_TEXT_WIDTH; };
  C.prototype.getTotalLength ??= function () { return MEASURED_TEXT_WIDTH + MEASURED_TEXT_HEIGHT; };
}

// —— <br> 规范性 / 合法性 lint ——
// 目标：让长标签在预览下不挤成一长行（靠 <br> 在语义点断行），并统一换行写法。
// 判定为提示级 [MERMAID-WARN]，不计入失败 (exitCode)，避免误伤合法的图。
// 规范写法：换行一律用 `<br>`（无斜杠）——mermaid 官方文档与标准 HTML void element 的主流写法；
//   `<br/>` / `<br />` / `</br>` 虽也能解析渲染，但非主流，提示统一为 `<br>`。
// 规则：
//   ① 写法统一：检测 `<br/>` / `<br />` / `</br>` 等非规范形式，提示统一为 `<br>`。
//   ② 合法性：`<br>` 只应出现在引号包裹的节点标签内；edge/message 等裸文本行中的
//      `<br>` 不会被当作标签内换行处理，渲染行为不可预期，予以提示。
//   ③ 长标签拥挤预警：标签被 `<br>` 切开后，单段仍超过 40 字符（或整段无换行、
//      超过 40 字符）则提示在语义断点再补 `<br>`，以改善预览可读性。
function lintBr(block) {
  const warns = [];
  const lines = (block.text || '').split('\n');
  const gStart = block.globalStartLine;
  const push = (lineNo, msg) => {
    warns.push(`  → [MERMAID-WARN] 第 ${lineNo} 行（global ${gStart + lineNo - 1}）：${msg}`);
  };
  for (let i = 0; i < lines.length; i++) {
    const ln = lines[i];
    const brMatches = ln.match(/\s*<\/?\s*br(?:\s*\/?\s*)?>/gi);
    const hasLabelQuote = /"/.test(ln);
    // ① 写法统一 + ② 合法性：仅当本行确有 <br> 时才检查写法与合法位置
    if (brMatches) {
      // 非规范形式：带前导或尾随斜杠的 </br>、<br/>、<br />（含大小写变体）
      const nonstandard = ln.match(/(?:<\s*\/\s*br>|<\s*br\s*\/>)/gi);
      if (nonstandard) {
        push(i + 1, `检测到非规范写法 ${nonstandard.map((s) => s.trim()).join('、')}，请统一为 <br>（mermaid 官方文档与 HTML 主流写法，带斜杠形式虽可渲染但非主流）。`);
      }
      if (!hasLabelQuote) {
        push(i + 1, `${brMatches.join('、')} 出现在疑似非标签位置（该行无引号包裹的节点标签）。请只在引号包裹的节点标签内使用 <br>。`);
      }
    }
    // ③ 长标签拥挤预警：含 "<br>" 或未断行的长标签，按 <br> 切开后仍超过 40 字符，
    //   或整行标签未用 <br> 断行且过长 —— 均在语义断点提示再补 <br>
    const segments = ln
      .replace(/<\s*br(?:\s*\/?\s*)?>/gi, '\u0000')
      .split('\u0000')
      .map((s) => s.replace(/^.*?"/, '').replace(/".*$/, ''))
      .map((s) => s.trim())
      .filter((s) => s.length > 40);
    for (const seg of segments) {
      push(i + 1, `标签文本段「${seg.slice(0, 40)}…」超过 40 字符，预览下可能过宽，建议在语义断点补 <br> 换行。`);
    }
  }
  return warns;
}

// —— 从多行文本提取 mermaid 块，返回 [{ globalStartLine, text, rawBlockLine }] ——
// 支持两种围栏形态：普通 ```mermaid，以及块引用缩进的 > ```mermaid（围栏与内容行
// 都可带 > 前缀），内容行会去掉前导的 "> " 前缀再交给 mermaid 解析。
function extractMermaidBlocks(text) {
  const blocks = [];
  // 围栏行：可带可选缩进 + 可选 ">" 块引用前缀；内容在开栏与关栏之间贪婪捕获
  const re =
    /^[ \t]*>?[ \t]*```mermaid[ \t]*\r?\n([\s\S]*?)\r?\n[ \t]*>?[ \t]*```[ \t]*$/gm;
  let m;
  while ((m = re.exec(text)) !== null) {
    const raw = m[0];
    const startOffset = m.index;
    const globalStartLine = text.slice(0, startOffset).split('\n').length;
    const content = m[1]
      .split('\n')
      .map((ln) => ln.replace(/^\s*>?\s*/, '')) // 统一去掉 "> " 块引用前缀
      .join('\n');
    blocks.push({
      globalStartLine,
      text: content.replace(/\r?\n$/, ''),
      rawLineCount: raw.split('\n').length,
    });
  }
  return blocks;
}

// —— 读取输入：优先命令行文件，否则 stdin ——
async function readSources(filePaths) {
  if (filePaths.length > 0) {
    const out = [];
    for (const p of filePaths) {
      const abs = resolve(p);
      let text;
      try {
        text = readFileSync(abs, 'utf8');
      } catch (err) {
        throw new Error(`无法读取文件 ${p}: ${err.message}`);
      }
      out.push({ name: abs, text });
    }
    return out;
  }
  const chunks = [];
  stdin.on('data', (c) => chunks.push(c));
  await new Promise((res) => stdin.once('end', res));
  return [{ name: '<stdin>', text: chunks.join('') }];
}

async function main() {
  const files = process.argv.slice(2).filter((a) => a !== '--');
  const sources = await readSources(files);

  let failCount = 0;
  let warnCount = 0;
  let blockIndex = 0;

  for (const src of sources) {
    const blocks = extractMermaidBlocks(src.text);
    if (blocks.length === 0) {
      console.log(`[${src.name}] 未发现 mermaid 代码块`);
      continue;
    }
    for (const b of blocks) {
      blockIndex += 1;
      const startGlobal = b.globalStartLine;
      const endGlobal = startGlobal + b.rawLineCount - 1;
      let type = '?';
      try {
        type = mermaid.detectType(b.text);
      } catch {
        type = '?';
      }
      try {
        await mermaid.parse(b.text);
        // render 阶段校验：flowchart/graph 可能含「子图父链成环」等只在布局期
        // 暴露的语义错误，parse 检测不到。sequenceDiagram/stateDiagram 等类型
        // 在纯 jsdom 下 render 会报 DOM 局限误错，故仅对 flowchart/graph 做 render。
        const isFlowchart = type === 'flowchart' || type === 'graph' || type === 'flowchart-v2';
        if (isFlowchart) {
          await mermaid.render(`chk-${blockIndex}`, b.text);
        }
        const modeLabel = isFlowchart ? 'parse+render' : 'parse';
        console.log(
          `OK  (${modeLabel})   [${src.name}:${startGlobal}-${endGlobal}] type=${type} #${blockIndex}`
        );
        // <br> 规范性 lint（提示级，不导致失败）
        const warns = lintBr(b);
        warnCount += warns.length;
        for (const w of warns) console.log(w);
      } catch (err) {
        failCount += 1;
        const msg = String((err && err.message) || err).trim();
        const envHint = /CSSStyleSheet|DOMPurify|Could not find a suitable point for the given distance/i.test(msg)
          ? '\n  → 提示：该报错通常意味着 render 所需 DOM 垫片缺失（测量为 0 / DOMParser / CSSStyleSheet），不是图本身语法错误；请检查本脚本垫片段落。'
          : '';
        // mermaid 错误信息里的内部行号通常是「相对该块第 1 行」，换算为全局行号
        const lineMatch = msg.match(/line\s*(\d+)/i);
        const inner = lineMatch ? parseInt(lineMatch[1], 10) : null;
        const globalErrLine = inner ? startGlobal + inner - 1 : startGlobal;
        console.log(
          `[MERMAID-ERROR] [${src.name}:${startGlobal}-${endGlobal}] type=${type} #${blockIndex}`
        );
        console.log(`  → 报错位置（全局第 ${globalErrLine} 行）：${msg}${envHint}`);
      }
    }
  }

  if (failCount > 0) {
    console.log(
      `\n校验结果：${failCount} 个 mermaid 块存在语法/渲染错误，请修复后重新运行；不保留渲染报错的图。${warnCount ? `（另有 ${warnCount} 条 [MERMAID-WARN] <br> 规范提示，见上）` : ''}`
    );
    process.exitCode = 1;
  } else {
    console.log(
      `\n校验结果：全部 mermaid 块语法/渲染通过。${warnCount ? `（含 ${warnCount} 条 [MERMAID-WARN] <br> 规范提示，见上）` : ''}`
    );
    process.exitCode = 0;
  }
  stdout.write('', () => process.exit());
}

main().catch((err) => {
  console.error(err.message);
  process.exit(2);
});
