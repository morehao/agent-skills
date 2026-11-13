#!/usr/bin/env node
// disk-cleanup v2 安全门禁（对应设计规格 §5 的安全不变量与 §12.2）：
//
//   ① 单漏斗   ：rm / find -delete 只允许出现在 lib/safety.sh 的 dc_funnel_rm 函数体内。
//                其它文件、或 safety.sh 的其它函数/顶层出现即失败（报文件:行）。
//                （tests/** 是用例脚手架，需要清理 mktemp 目录，不在本项管辖内；仍受 ④ 管辖。）
//   ② 禁 bash4 ：mapfile、readarray、declare/local/typeset -A、${var,,}、${var^^}、<<<、&>>
//   ③ HOME 断言：mac_cleanup.sh 必须真的调用 dc_env_assert（只定义在 lib 里不算）
//   ④ 语法     ：skills/disk-cleanup/scripts/**/*.sh 全部过 `bash -n`（固定用 /bin/bash，
//                macOS 上是 3.2，能拦住只在 4.x 才合法的写法）
//   ⑤ 变量+中文：`$var` 后紧跟非 ASCII 字符（bash 3.2 会把它并进变量名 → unbound variable），
//                必须写成 `${var}中文`。这是仓库硬约束。
//
// 行级判断先去掉注释（引号内的 # 不切），避免文档性注释误报。
// 退出码：0 通过 / 1 有违规。
//
// 用法：node scripts/check-disk-cleanup-safety.mjs

import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SCRIPTS_DIR = join(repoRoot, "skills/disk-cleanup/scripts");
const ENTRY = join(SCRIPTS_DIR, "mac_cleanup.sh");
const FUNNEL_FILE = join(SCRIPTS_DIR, "lib/safety.sh");
// 删除只允许出自两个函数（同文件、同一套闸）：
//   dc_funnel_rm   单条入口（断言/保护/在用 → rm → 失败归类）
//   dc_batch_flush 批量入口（路径已逐条过完三道检查，一次 rm 删一批）
const FUNNEL_FNS = ["dc_funnel_rm", "dc_batch_flush"];
const FUNNEL_LABEL = "dc_funnel_rm() / dc_batch_flush()";
const BASH = "/bin/bash";

const problems = [];
const rel = (p) => relative(repoRoot, p);
const loc = (file, line) => `${rel(file)}:${line}`;

function fail(file, line, msg) {
  problems.push(`${loc(file, line)}  ${msg}`);
}

function walkSh(dir) {
  const out = [];
  for (const name of readdirSync(dir).sort()) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) out.push(...walkSh(p));
    else if (name.endsWith(".sh")) out.push(p);
  }
  return out;
}

// 去掉行尾注释：引号内不切；`#` 必须位于行首或空白之后（`${x#pat}`、`a#b` 不受影响）
function stripComment(line) {
  let quote = null;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quote) {
      if (quote === '"' && ch === "\\") {
        i += 1;
        continue;
      }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === "#" && (i === 0 || /\s/.test(line[i - 1]))) return line.slice(0, i);
  }
  return line;
}

// 统计一行里的花括号净增量：跳过 ${...}、引号内的内容，避免 JSON 模板/字符串把深度带偏
function braceDelta(line) {
  let delta = 0;
  let quote = null;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quote) {
      if (quote === '"' && ch === "\\") {
        i += 1;
        continue;
      }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "$" && line[i + 1] === "{") {
      let depth = 1;
      let j = i + 2;
      while (j < line.length && depth > 0) {
        if (line[j] === "{") depth += 1;
        else if (line[j] === "}") depth -= 1;
        j += 1;
      }
      i = j - 1;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === "{") delta += 1;
    else if (ch === "}") delta -= 1;
  }
  return delta;
}

const FUNC_HEADER_RE = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*\{/;
// 词边界：避免 DC_TIMEOUT_RM / rmmv / charm 之类的误报
const RM_RE = /(^|[^A-Za-z0-9_])rm([^A-Za-z0-9_]|$)/;
const FIND_DELETE_RE = /(^|\s)-delete(\s|$)/;

const BASH4_RULES = [
  { re: /\bmapfile\b/, name: "mapfile（bash 4 才有，改用 while read）" },
  { re: /\breadarray\b/, name: "readarray（bash 4 才有，改用 while read）" },
  { re: /\b(declare|local|typeset)\s+-A\b/, name: "declare -A 关联数组（bash 3.2 不支持）" },
  { re: /\$\{[A-Za-z_][A-Za-z0-9_]*,,/, name: "${var,,} 小写展开（bash 4 才有，改用 tr）" },
  { re: /\$\{[A-Za-z_][A-Za-z0-9_]*\^\^/, name: "${var^^} 大写展开（bash 4 才有，改用 tr）" },
  { re: /<<</, name: "<<< here-string（bash 3.2 不支持）" },
  { re: /&>>/, name: "&>> 追加重定向（bash 3.2 不支持，改用 >> file 2>&1）" },
];

const VAR_CJK_RE = /\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7F])/g;

// ---------- 读文件 ----------
let files;
try {
  files = walkSh(SCRIPTS_DIR);
} catch (err) {
  console.error(`[disk-cleanup-safety] 无法读取 ${rel(SCRIPTS_DIR)}：${err.message}`);
  process.exit(1);
}
if (files.length === 0) {
  console.error(`[disk-cleanup-safety] ${rel(SCRIPTS_DIR)} 下没有任何 .sh`);
  process.exit(1);
}
const runtimeFiles = files.filter((f) => !rel(f).includes("/tests/"));

// ---------- ① 单漏斗 / ② bash4 / ⑤ 变量+中文 ----------
let funnelHits = 0;
let bash4Checked = 0;
let cjkChecked = 0;

for (const file of files) {
  const lines = readFileSync(file, "utf8").split("\n");
  const isFunnelFile = file === FUNNEL_FILE;
  let curFn = null;
  let depth = 0;

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const code = stripComment(raw);
    const ln = i + 1;

    const header = code.match(FUNC_HEADER_RE);
    if (header) {
      curFn = header[1];
      depth = 0;
    }

    // ① rm / find -delete：只允许 safety.sh 的 dc_funnel_rm 内；tests/ 不参与本项
    if (!rel(file).includes("/tests/")) {
      const inFunnel = isFunnelFile && FUNNEL_FNS.includes(curFn);
      if (RM_RE.test(code)) {
        if (!inFunnel) {
          fail(
            file,
            ln,
            `出现 rm（只允许 ${rel(FUNNEL_FILE)} 的 ${FUNNEL_LABEL} 内；删除必须走漏斗）` +
              (curFn ? `｜当前在 ${curFn}()` : "｜当前不在任何函数内"),
          );
        } else {
          funnelHits += 1;
        }
      }
      if (FIND_DELETE_RE.test(code)) {
        fail(
          file,
          ln,
          `出现 find -delete（删除必须走 ${FUNNEL_LABEL}；find 只用来 -print/-print0 收集路径）` +
            (curFn ? `｜当前在 ${curFn}()` : ""),
        );
      }
    }

    // ② 禁 bash4 语法
    for (const rule of BASH4_RULES) {
      if (rule.re.test(code)) {
        bash4Checked += 1;
        fail(file, ln, `出现 bash4 语法 ${rule.name}（脚本必须按 bash 3.2 写）`);
      }
    }

    // ⑤ 变量后紧跟中文
    VAR_CJK_RE.lastIndex = 0;
    let m;
    while ((m = VAR_CJK_RE.exec(code)) !== null) {
      cjkChecked += 1;
      fail(
        file,
        ln,
        `\`$${m[1]}\` 后紧跟非 ASCII 字符「${m[2]}」（bash 3.2 会并进变量名导致 unbound variable），` +
          `请写成 \`\${${m[1]}}${m[2]}…\``,
      );
    }

    if (curFn) {
      depth += braceDelta(code);
      if (depth <= 0 && !header) curFn = null;
    }
  }
}

// ---------- ③ mac_cleanup.sh 必须调用 dc_env_assert ----------
try {
  const entryLines = readFileSync(ENTRY, "utf8").split("\n");
  const called = entryLines.some((line) => /^\s*dc_env_assert(\s|$)/.test(stripComment(line)));
  if (!called) {
    problems.push(
      `${rel(ENTRY)}  没有调用 dc_env_assert（HOME 为空时会整批塌缩成系统路径，必须启动即断言）`,
    );
  }
} catch (err) {
  problems.push(`${rel(ENTRY)}  读不到：${err.message}`);
}

// ---------- ④ bash -n ----------
for (const file of files) {
  const r = spawnSync(BASH, ["-n", file], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  if (r.error) {
    problems.push(`${rel(file)}  无法执行 ${BASH} -n：${r.error.message}`);
    continue;
  }
  if (r.status !== 0) {
    const detail = (r.stderr || "").trim().split("\n").slice(0, 2).join(" / ");
    const m = /line (\d+)/.exec(detail);
    problems.push(`${rel(file)}${m ? `:${m[1]}` : ""}  bash -n 失败：${detail}`);
  }
}

// ---------- 汇总 ----------
if (problems.length > 0) {
  for (const p of problems) console.error(`[disk-cleanup-safety] ${p}`);
  console.error(`\n[disk-cleanup-safety] 共 ${problems.length} 处违规`);
  console.error(
    "提示：删除只走 lib/safety.sh 的 dc_funnel_rm / dc_batch_flush；脚本按 bash 3.2 写；变量后紧跟中文要写 ${var}。",
  );
  process.exit(1);
}

console.log(
  `[disk-cleanup-safety] ok：${files.length} 个脚本过 ${BASH} -n（其中 ${runtimeFiles.length} 个运行期脚本）；` +
    `rm 仅出现在 ${FUNNEL_LABEL}（${funnelHits} 处）；` +
    `bash4 语法 ${bash4Checked} 处；HOME 断言已调用；变量+中文 ${cjkChecked} 处`,
);
