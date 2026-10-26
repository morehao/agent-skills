#!/usr/bin/env node
// select-baseline.mjs —— 解读版本基线的程序化选择（防"基线靠印象"）。
//
// 用法：
//   node select-baseline.mjs <本地路径|远端URL> [--ref <ref>] [--package <名>] [--json]
//                            [--stale-commits N] [--stale-days N]
//
// 行为：
//   按 skill 约定优先级选定"这次解读基于哪个版本"：
//     稳定 tag > 稳定分支 > 默认分支（main/master/远端 HEAD）> 无 main/master 兜底矩阵。
//   只读：**不 clone、不 checkout、不改动任何仓库**；只给出选定结果 + 落地建议命令，
//   落地动作（clone / checkout / worktree）由 skill 流程按 references/version-baseline.md 执行。
//
// 输出状态（[BASELINE-AMBIGUOUS] / [BASELINE-STALE] 参与退出码）：
//   [BASELINE-TAG]        选定稳定 tag（正式版，排除预发布与移动 tag）
//   [BASELINE-BRANCH]     选定稳定分支（release*/stable*/maintenance*/1.x）
//   [BASELINE-DEFAULT]    回落到默认分支（main → master → 远端 HEAD 符号引用）
//   [BASELINE-FALLBACK]   无 main/master，兜底矩阵命中（远端 HEAD/主干名/最新非特性分支/最新 tag）
//   [BASELINE-USER]       用户 --ref 显式指定，覆盖优先级
//   [BASELINE-STALE]      选定 tag 落后默认分支超阈值 → 需用户确认后使用
//   [BASELINE-AMBIGUOUS]  多包 tag 无法唯一定位 / 并列最高版本 / 无任何可依基线 → 交用户选择
// 退出码：0 = 已选定；2 = 需用户确认或选择（配合 skill 的"用户选择"分支）。
//
// 与 check-mermaid.mjs / verify-references.mjs 同理：本脚本是判定工具，只读不改。

import { execFileSync } from 'node:child_process';

const VERSION_RE = /^[vV]?(\d+(?:\.\d+)*)(?:[-+_](.*))?$/;
const PRE_WORDS = /(alpha|beta|rc|pre|preview|dev|snapshot|canary|nightly|test)/i;
// 移动 tag：名字不表达版本，指向会变，不能当快照锚点
const MOVING_TAG_RE = /^(latest|stable|release|releases|current|edge|nightly|snapshot|head|tip|final)$/i;
// 特性/临时分支：永远不当稳定基线
const FEATURE_BRANCH_RE = /^(feat|feature|fix|bugfix|hotfix|refactor|chore|docs|test|tests|experiment|exp|poc|wip|tmp|temp|dependabot|renovate)([/-]|$)/i;
const STABLE_BRANCH_RE = /^(release|releases|stable|lts|maintenance|maint|support)([/-]|$)/i;
const VERSION_BRANCH_RE = /^[vV]?\d+(\.\d+)*(\.[xX*])?$/;
const MAINLINE_ORDER = ['trunk', 'develop', 'development', 'default', 'next', 'head'];

function git(args, opts = {}) {
  try {
    const out = execFileSync('git', args, {
      cwd: opts.cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: opts.timeout ?? 60000,
      maxBuffer: 64 * 1024 * 1024,
    });
    return { ok: true, out: out.trim() };
  } catch (e) {
    return { ok: false, out: (e.stdout ?? '').toString().trim(), err: (e.stderr ?? '').toString().trim() };
  }
}

function parseArgs(argv) {
  const o = { target: null, ref: null, pkg: null, json: false, staleCommits: 500, staleDays: 730 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--ref') o.ref = argv[++i];
    else if (a === '--package') o.pkg = argv[++i];
    else if (a === '--json') o.json = true;
    else if (a === '--stale-commits') o.staleCommits = Number(argv[++i]);
    else if (a === '--stale-days') o.staleDays = Number(argv[++i]);
    else if (a === '-h' || a === '--help') o.help = true;
    else if (!a.startsWith('--') && o.target === null) o.target = a;
  }
  return o;
}

const isRemote = (s) => /^(https?:\/\/|git@|ssh:\/\/|git:\/\/|file:\/\/)/.test(s);

/** tag 名 → { name, prefix, version, pre, moving, kind } */
function parseTag(name) {
  if (MOVING_TAG_RE.test(name)) return { name, prefix: null, version: null, pre: false, moving: true, kind: 'moving' };
  // 单仓多包 tag：pkg@1.2.3 / pkg/v1.2.3
  const pm = /^([A-Za-z0-9._-]+)[@/](.+)$/.exec(name);
  const prefix = pm ? pm[1] : null;
  const rest = pm ? pm[2] : name;
  const vm = VERSION_RE.exec(rest);
  if (!vm) return { name, prefix, version: null, pre: false, moving: false, kind: 'other' };
  const nums = vm[1].split('.').map(Number);
  const suffix = vm[2] ?? '';
  const pre = (suffix !== '' && PRE_WORDS.test(suffix)) || PRE_WORDS.test(name);
  return { name, prefix, version: nums, pre, moving: false, kind: 'version' };
}

function cmpVersion(a, b) {
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const d = (a[i] ?? 0) - (b[i] ?? 0);
    if (d !== 0) return d;
  }
  return 0;
}

function branchVersion(name) {
  const m = /(\d+(?:[.\d]*))/.exec(name);
  if (!m) return null;
  return m[1].split('.').map((s) => (s === 'x' || s === 'X' || s === '*' ? 0 : Number(s)));
}

function classifyBranch(name, defaultBranch) {
  if (name === defaultBranch) return 'default';
  if (FEATURE_BRANCH_RE.test(name)) return 'feature';
  if (STABLE_BRANCH_RE.test(name) || VERSION_BRANCH_RE.test(name)) return 'stable';
  if (MAINLINE_ORDER.includes(name)) return 'mainline';
  return 'other';
}

function collectLocal(dir, staleCommits, staleDays) {
  const g = (args) => git(['-C', dir, ...args]);
  if (!g(['rev-parse', '--git-dir']).ok) return { error: `不是 git 仓库：${dir}` };

  const tags = [];
  const tagLines = g(['for-each-ref', '--format=%(refname:short)%09%(creatordate:iso-strict)', 'refs/tags']).out;
  for (const line of tagLines.split('\n').filter(Boolean)) {
    const [name, date] = line.split('\t');
    tags.push({ ...parseTag(name), date: date ?? null });
  }

  const branches = [];
  const brLines = g(['for-each-ref', '--format=%(refname:short)%09%(creatordate:iso-strict)', 'refs/heads']).out;
  for (const line of brLines.split('\n').filter(Boolean)) {
    const [name, date] = line.split('\t');
    branches.push({ name, date: date ?? null });
  }
  const branchNames = branches.map((b) => b.name);

  const headRef = g(['symbolic-ref', '-q', '--short', 'HEAD']).out || null;
  const headSha = g(['rev-parse', '--short', 'HEAD']).out || null;
  const dirty = g(['status', '--porcelain']).out.length > 0;

  // 默认分支：main → master → 远端 HEAD 符号引用 → 当前分支（兜底矩阵再加权）
  const originHead = (g(['symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD']).out || '').replace(/^origin\//, '');
  let defaultBranch = null;
  let defaultSource = null;
  if (branchNames.includes('main')) [defaultBranch, defaultSource] = ['main', 'refs/heads/main'];
  else if (branchNames.includes('master')) [defaultBranch, defaultSource] = ['master', 'refs/heads/master'];
  else if (originHead && branchNames.includes(originHead)) [defaultBranch, defaultSource] = [originHead, 'refs/remotes/origin/HEAD'];
  else {
    // 尽力而为：远端 HEAD 符号引用（网络失败不阻塞，交给兜底矩阵）
    const remoteUrl = g(['remote', 'get-url', 'origin']).out;
    if (remoteUrl) {
      const sym = git(['ls-remote', '--symref', remoteUrl, 'HEAD'], { timeout: 20000 });
      const m = sym.ok ? /ref:\s+refs\/heads\/(\S+)\s+HEAD/.exec(sym.out) : null;
      if (m && branchNames.includes(m[1])) [defaultBranch, defaultSource] = [m[1], '远端 HEAD 符号引用'];
    }
    if (!defaultBranch) {
      // 当前分支只有在不是特性/临时分支时才能当主干兜底，否则宁可交给兜底矩阵
      const cur = headRef && branchNames.includes(headRef) && !FEATURE_BRANCH_RE.test(headRef) ? headRef : null;
      if (cur) [defaultBranch, defaultSource] = [cur, '当前 HEAD 所在分支'];
    }
  }

  // 每个 tag 的短 SHA + 陈旧度
  const defaultRef = defaultBranch ? (defaultSource === 'refs/remotes/origin/HEAD' ? `origin/${defaultBranch}` : defaultBranch) : null;
  for (const t of tags) {
    if (!t.version) continue;
    t.sha = g(['rev-parse', '--short', `${t.name}^{commit}`]).out || null;
    if (defaultRef) {
      const c = g(['rev-list', '--count', `${t.name}..${defaultRef}`]);
      t.behindDefault = c.ok ? Number(c.out) : null;
    }
    if (t.date) {
      const days = (Date.now() - Date.parse(t.date)) / 86400000;
      t.ageDays = Number.isFinite(days) ? Math.round(days) : null;
    }
    t.stale =
      (t.behindDefault !== null && t.behindDefault > staleCommits) ||
      (t.ageDays !== null && t.ageDays > staleDays);
  }

  return { mode: 'local', dir, tags, branches, headRef, headSha, dirty, defaultBranch, defaultSource };
}

function collectRemote(url) {
  const tags = [];
  const tagOut = git(['ls-remote', '--tags', url], { timeout: 60000 });
  if (!tagOut.ok) return { error: `无法访问远端：${url}${tagOut.err ? `（${tagOut.err}）` : ''}` };
  const shas = new Map();
  for (const line of tagOut.out.split('\n').filter(Boolean)) {
    const [sha, ref] = line.split('\t');
    if (!ref?.startsWith('refs/tags/')) continue;
    const peeled = ref.endsWith('^{}');
    const name = ref.replace(/^refs\/tags\//, '').replace(/\^\{\}$/, '');
    // 优先取 peeled（指向 commit）的 SHA
    if (!shas.has(name) || peeled) shas.set(name, sha);
  }
  for (const [name, sha] of shas) tags.push({ ...parseTag(name), sha: sha.slice(0, 12) });

  const branches = [];
  const brOut = git(['ls-remote', '--heads', url], { timeout: 60000 });
  for (const line of brOut.out.split('\n').filter(Boolean)) {
    const [sha, ref] = line.split('\t');
    if (ref?.startsWith('refs/heads/')) branches.push({ name: ref.replace(/^refs\/heads\//, ''), sha: sha.slice(0, 12), date: null });
  }

  let defaultBranch = null;
  let defaultSource = null;
  const sym = git(['ls-remote', '--symref', url, 'HEAD'], { timeout: 60000 });
  const m = sym.ok ? /ref:\s+refs\/heads\/(\S+)\s+HEAD/.exec(sym.out) : null;
  if (m) [defaultBranch, defaultSource] = [m[1], '远端 HEAD 符号引用'];
  const branchNames = branches.map((b) => b.name);
  if (!defaultBranch && branchNames.includes('main')) [defaultBranch, defaultSource] = ['main', 'refs/heads/main'];
  if (!defaultBranch && branchNames.includes('master')) [defaultBranch, defaultSource] = ['master', 'refs/heads/master'];

  return { mode: 'remote', url, tags, branches, defaultBranch, defaultSource, dirty: false, remote: true };
}

function pick(info, pkg) {
  const warnings = [];
  const tagCandidates = info.tags.filter((t) => t.kind === 'version');
  const stableTags = tagCandidates.filter((t) => !t.pre);

  // 单仓多包 tag：出现多个包前缀时无法唯一确定"项目版本"
  const prefixes = [...new Set(stableTags.map((t) => t.prefix).filter(Boolean))];
  let pool = stableTags;
  if (prefixes.length > 1) {
    if (pkg && prefixes.includes(pkg)) pool = stableTags.filter((t) => t.prefix === pkg);
    else
      return {
        ambiguous: true,
        reason: `检测到单仓多包 tag（包前缀：${prefixes.join(', ')}），无法唯一确定项目版本；用 --package <名> 指定，或让用户选择`,
        candidates: prefixes,
      };
  }

  pool = [...pool].sort((a, b) => cmpVersion(b.version, a.version) || (b.name.startsWith('v') ? 1 : 0) - (a.name.startsWith('v') ? 1 : 0));
  if (pool.length >= 2 && cmpVersion(pool[0].version, pool[1].version) === 0) {
    return {
      ambiguous: true,
      reason: `最高版本并列：${pool[0].name} 与 ${pool[1].name}，无法唯一确定基线`,
      candidates: [pool[0].name, pool[1].name],
    };
  }
  if (pool.length > 0) {
    const t = pool[0];
    if (t.stale) {
      warnings.push(
        `[BASELINE-STALE] 选定 tag ${t.name} 可能已过时：落后默认分支 ${t.behindDefault ?? '?'} commits、距今 ${t.ageDays ?? '?'} 天（阈值 ${info.staleCommits ?? 500} commits / ${info.staleDays ?? 730} 天）→ 需用户确认后再用`,
      );
      return { ref: t.name, kind: 'tag', sha: t.sha, reason: `稳定 tag 中 semver 最高（但陈旧，需确认）`, stale: true, warnings, candidates: pool.slice(1, 6).map((x) => x.name) };
    }
    return { ref: t.name, kind: 'tag', sha: t.sha, reason: '稳定 tag 中 semver 最高（排除预发布与移动 tag）', warnings, candidates: pool.slice(1, 6).map((x) => x.name) };
  }

  // 稳定分支
  const stableBranches = info.branches
    .filter((b) => classifyBranch(b.name, info.defaultBranch) === 'stable')
    .map((b) => ({ ...b, v: branchVersion(b.name) }));
  stableBranches.sort((a, b) => {
    if (a.v && b.v) return cmpVersion(b.v, a.v);
    if (a.v && !b.v) return -1;
    if (!a.v && b.v) return 1;
    return (b.date ?? '').localeCompare(a.date ?? '') || a.name.localeCompare(b.name);
  });
  if (stableBranches.length > 0) {
    const b = stableBranches[0];
    return { ref: b.name, kind: 'branch', sha: b.sha ?? null, reason: '无稳定 tag，取版本最高的发行/维护分支', warnings, candidates: stableBranches.slice(1, 6).map((x) => x.name) };
  }

  // 默认分支
  if (info.defaultBranch) {
    return {
      ref: info.defaultBranch,
      kind: info.defaultBranch === 'main' || info.defaultBranch === 'master' ? 'default' : 'fallback',
      sha: info.branches.find((b) => b.name === info.defaultBranch)?.sha ?? info.headSha ?? null,
      reason:
        info.defaultBranch === 'main' || info.defaultBranch === 'master'
          ? `无稳定 tag/分支，回落默认分支（${info.defaultSource}）`
          : `仓库无 main/master，按兜底矩阵取默认分支 ${info.defaultBranch}（${info.defaultSource}）`,
      warnings,
      candidates: [],
    };
  }

  // 兜底矩阵：常见主干名 → 最新非特性分支
  const mainline = info.branches.filter((b) => MAINLINE_ORDER.includes(b.name));
  if (mainline.length > 0) {
    const b = MAINLINE_ORDER.map((n) => mainline.find((x) => x.name === n)).find(Boolean);
    return { ref: b.name, kind: 'fallback', sha: b.sha ?? null, reason: '仓库无 main/master，兜底矩阵命中常见主干名', warnings, candidates: mainline.filter((x) => x.name !== b.name).map((x) => x.name) };
  }
  const nonFeature = info.branches.filter((b) => classifyBranch(b.name, info.defaultBranch) === 'other');
  if (nonFeature.length > 0) {
    nonFeature.sort((a, b) => (b.date ?? '').localeCompare(a.date ?? '') || a.name.localeCompare(b.name));
    const b = nonFeature[0];
    warnings.push('仓库无 main/master 亦无常见主干名，按"最近提交的非特性分支"兜底，请在产物中声明');
    return { ref: b.name, kind: 'fallback', sha: b.sha ?? null, reason: '兜底矩阵末级：最近的非特性分支', warnings, candidates: nonFeature.slice(1, 6).map((x) => x.name) };
  }
  const loose = [...info.tags].filter((t) => t.version).sort((a, b) => cmpVersion(b.version, a.version));
  if (loose.length > 0) {
    warnings.push('仓库仅剩 tag（无分支）可依，含预发布 tag；请在产物中声明"无稳定基线"');
    return { ref: loose[0].name, kind: 'fallback', sha: loose[0].sha ?? null, reason: '兜底矩阵末级：最新 tag（含预发布）', warnings, candidates: loose.slice(1, 6).map((x) => x.name) };
  }
  return { ambiguous: true, reason: '无 tag、无分支、无默认分支可依，请用户直接给出 ref', candidates: [] };
}

function landing(info, sel, a) {
  const remoteCmd = `git clone --branch ${sel.ref} --depth=1 ${info.url ?? '<url>'} <dest>`;
  const needHistory = info.mode === 'remote' ? `\n  # 需要 git diff 历史时（增量模式）改用：git clone --filter=blob:none --branch ${sel.ref} ${info.url} <dest>` : '';
  if (info.mode === 'remote') {
    return {
      clone: remoteCmd + needHistory,
      verifyRoot: '<dest>（realpath 后即 source_repo 与引用校验根）',
      restore: '无需恢复（新建克隆）',
    };
  }
  const orig = info.headRef ? info.headRef : info.headSha;
  if (info.dirty) {
    return {
      checkout: `# 工作树脏（有未提交改动）→ 不静默覆盖，二选一：\n  git -C ${info.dir} worktree add <tmp> ${sel.ref}   # 推荐：非破坏性\n  # 或经用户确认后：git -C ${info.dir} stash && git -C ${info.dir} checkout ${sel.ref}`,
      verifyRoot: `<tmp> 或 ${info.dir}（realpath 后即 source_repo 与引用校验根）`,
      restore: `git -C ${info.dir} worktree remove <tmp>；stash 方案则 git -C ${info.dir} stash pop`,
    };
  }
  return {
    checkout: `git -C ${info.dir} checkout ${sel.ref}`,
    verifyRoot: `${info.dir}（realpath 后即 source_repo 与引用校验根）`,
    restore: `git -C ${info.dir} checkout ${orig}`,
  };
}

function report(info, sel, a) {
  const lines = [];
  const where = info.mode === 'remote' ? info.url : info.dir;
  lines.push(`输入：${where}（${info.mode === 'remote' ? '远端' : '本地 git 仓库'}）`);
  if (info.headSha) lines.push(`当前 HEAD：${info.headRef ?? '(detached)'} @ ${info.headSha}${info.dirty ? '  ⚠ 工作树脏（有未提交改动）' : '  工作树干净'}`);
  lines.push(`默认分支：${info.defaultBranch ?? '(未解析出)'}${info.defaultSource ? `  ← ${info.defaultSource}` : ''}`);

  const vtags = info.tags.filter((t) => t.kind === 'version');
  if (vtags.length) {
    const top = [...vtags].sort((x, y) => cmpVersion(y.version, x.version)).slice(0, 6);
    lines.push(`版本 tag（前 ${top.length}/${vtags.length}，降序）：${top.map((t) => `${t.name}${t.pre ? '(预发布)' : ''}${t.date ? `@${t.date.slice(0, 10)}` : ''}${t.stale ? '⚠陈旧' : ''}`).join('  ')}`);
  } else lines.push('版本 tag：无');
  const moving = info.tags.filter((t) => t.moving).map((t) => t.name);
  if (moving.length) lines.push(`移动 tag（排除）：${moving.join(' ')}`);
  const preOnly = info.tags.filter((t) => t.kind === 'version' && t.pre).map((t) => t.name);
  if (preOnly.length && !info.tags.some((t) => t.kind === 'version' && !t.pre)) lines.push(`预发布 tag（无正式版时才考虑）：${preOnly.join(' ')}`);

  const stable = info.branches.filter((b) => classifyBranch(b.name, info.defaultBranch) === 'stable').map((b) => b.name);
  lines.push(`稳定分支：${stable.length ? stable.join(' ') : '无'}`);

  if (sel.ambiguous) {
    lines.push('');
    lines.push(`[BASELINE-AMBIGUOUS] ${sel.reason}`);
    if (sel.candidates?.length) lines.push(`候选：${sel.candidates.join(' | ')}`);
    lines.push('→ 走"用户选择"分支（结构化二选一 + 各自代价），不要默认挑一个继续。');
    return lines;
  }

  const state = sel.stale ? '[BASELINE-STALE]' : `[BASELINE-${sel.kind.toUpperCase()}]`;
  lines.push('');
  lines.push(`▶ 选定基线：${sel.ref}${sel.sha ? ` @ ${sel.sha}` : ''}  ${state}`);
  lines.push(`  理由：${sel.reason}`);
  if (sel.candidates?.length) lines.push(`  次选（供用户改选）：${sel.candidates.join(' ')}`);

  const l = landing(info, sel, a);
  lines.push('');
  lines.push('落地建议：');
  if (l.clone) lines.push(`  ${l.clone}`);
  if (l.checkout) lines.push(`  ${l.checkout}`);
  lines.push(`  验证根（source_repo）：${l.verifyRoot}`);
  lines.push(`  收尾恢复：${l.restore}`);
  lines.push('');
  lines.push('写入产物（不写 frontmatter）：');
  lines.push(`  README 概览一行：解读基线：\`${sel.ref}\`${sel.sha ? `（\`${sel.sha}\`）` : ''}`);
  lines.push(`  CHANGELOG.md 顶部条目首行：依据：${sel.ref}${sel.sha ? `@${sel.sha}` : ''}`);
  if (sel.stale) lines.push('  ⚠ 陈旧基线：先请用户确认，确认后在产物中注明"按 {ref} 解读，已确认接受其陈旧度"。');
  for (const w of sel.warnings) lines.push(`  ⚠ ${w}`);
  return lines;
}

function main() {
  const a = parseArgs(process.argv.slice(2));
  if (a.help || !a.target) {
    console.log(
      [
        '用法：node select-baseline.mjs <本地路径|远端URL> [--ref <ref>] [--package <名>] [--json] [--stale-commits N] [--stale-days N]',
        '',
        '按 skill 约定优先级选定解读基线：稳定 tag > 稳定分支 > 默认分支(main/master/远端HEAD) > 无 main/master 兜底矩阵。',
        '只读：不 clone、不 checkout、不改动仓库；输出选定结果与落地建议命令。',
        '退出码：0 = 已选定；2 = 需用户确认或选择。',
      ].join('\n'),
    );
    process.exit(a.target ? 0 : 2);
  }

  const info = isRemote(a.target) ? collectRemote(a.target) : collectLocal(a.target, a.staleCommits, a.staleDays);
  if (info.error) {
    console.error(`[BASELINE-UNVERIFIED] ${info.error}`);
    process.exit(2);
  }
  info.staleCommits = a.staleCommits;
  info.staleDays = a.staleDays;

  let sel;
  if (a.ref) {
    // 用户显式指定：覆盖优先级，但仍须校验 ref 真实存在，否则不静默继续
    const listed = info.tags.some((t) => t.name === a.ref) || info.branches.some((b) => b.name === a.ref);
    const isSha = /^[0-9a-f]{7,40}$/i.test(a.ref);
    let verified = listed;
    if (!verified && info.mode === 'local') verified = git(['-C', info.dir, 'rev-parse', '--verify', '--quiet', `${a.ref}^{commit}`]).ok;
    let shaNote = null;
    if (!verified && info.mode === 'remote' && isSha) {
      verified = true;
      shaNote = '远端任意 SHA 无法在 ls-remote 候选中校验，落地 clone 时请自行确认该 commit 可获取';
    }
    const sha =
      info.tags.find((t) => t.name === a.ref)?.sha ??
      info.branches.find((b) => b.name === a.ref)?.sha ??
      (info.mode === 'local' && verified ? git(['-C', info.dir, 'rev-parse', '--short', a.ref]).out : null) ??
      (isSha ? a.ref : null);
    if (!verified) {
      sel = {
        ref: a.ref,
        kind: 'user',
        sha,
        ambiguous: true,
        reason: `[BASELINE-UNVERIFIED] 指定 ref 在${info.mode === 'local' ? '本地仓库' : '远端候选中'}找不到：${a.ref}（未 fetch 的分支/任意 SHA 都不会被静默采用）`,
      };
    } else {
      sel = {
        ref: a.ref,
        kind: 'user',
        sha,
        reason: '用户 --ref 显式指定，覆盖优先级（属非稳定基线，产物需声明）',
        warnings: shaNote ? [shaNote] : [],
      };
    }
  } else {
    sel = pick(info, a.pkg);
  }

  if (a.json) {
    console.log(JSON.stringify({ input: a.target, ...info, selected: sel, exitCode: sel.ambiguous || sel.stale ? 2 : 0 }, null, 2));
  } else {
    for (const line of report(info, sel, a)) console.log(line);
  }
  process.exit(sel.ambiguous || sel.stale ? 2 : 0);
}

main();
