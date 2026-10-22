#!/usr/bin/env node
// opencode 命令契约校验：把「命令 → 技能分支」这条隐式字符串耦合变成可执行的失败。
//
// 参照 dsh-commands 的 scripts/check-skill-contract.mjs：opencode 侧的命令是 Markdown
// 委托壳，branch 只写在正文的自然语言里；技能改分支名、README 加删命令而壳没跟，
// 命令照样能点、结果不对。这里在提交前把它们逐条对出来。
//
// 检查项：
//   1. frontmatter 合法（仅官方字段、description 单行非空且长度合理）
//   2. 正文声明了 skill 与 branch，且 skills/<skill>/references/<branch>.md 存在
//      （单文件技能只校验 SKILL.md 存在，handoff 的 print 是装饰性分支）
//   3. $ARGUMENTS 独立成行；无参数命令必须显式写「本命令无参数」
//   4. commands-opencode/README.md 与根 README.md 的表格和命令文件一一对应
//   5. 可选 --dsh <插件仓路径>：比对另一仓 COMMANDS 表的 branch/skill（描述差异只提示）
//
// 用法：
//   node scripts/check-opencode-commands.mjs [--dsh <dsh-commands 仓路径>] [--help]
//
// 退出码：0 通过（仅 note）/ 1 有 error / 2 用法错误。
import { readFile, readdir, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const COMMANDS_DIR = join(ROOT, "commands-opencode");
const SKILLS_DIR = join(ROOT, "skills");
const COMMANDS_README = join(COMMANDS_DIR, "README.md");
const ROOT_README = join(ROOT, "README.md");

// opencode 的 ConfigCommandV1.Info：本仓只允许这些键（多写的键官方会忽略，但别写）。
const ALLOWED_FRONTMATTER = new Set(["description", "agent", "model", "variant", "subtask"]);
const DESCRIPTION_WARN = 200;

const errors = [];
const notes = [];

const fail = (message) => errors.push(message);
const note = (message) => notes.push(message);

async function isFile(path) {
	try {
		return (await stat(path)).isFile();
	} catch {
		return false;
	}
}

async function isDir(path) {
	try {
		return (await stat(path)).isDirectory();
	} catch {
		return false;
	}
}

/** 收集 commands-opencode 下的命令文件（README 不是命令）。 */
async function collectCommandFiles(dir) {
	const out = [];
	for (const entry of await readdir(dir, { withFileTypes: true })) {
		const path = join(dir, entry.name);
		if (entry.isDirectory()) out.push(...(await collectCommandFiles(path)));
		else if (entry.isFile() && entry.name.endsWith(".md") && entry.name !== "README.md") out.push(path);
	}
	return out.sort();
}

function unquote(value) {
	const trimmed = value.trim();
	if (trimmed.length >= 2) {
		const first = trimmed[0];
		const last = trimmed[trimmed.length - 1];
		if ((first === '"' && last === '"') || (first === "'" && last === "'")) return trimmed.slice(1, -1);
	}
	return trimmed;
}

function parseFrontmatter(text, rel) {
	const match = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?/);
	if (match === null) return undefined;
	const data = new Map();
	for (const line of match[1].split(/\r?\n/)) {
		if (line.trim() === "" || line.trim().startsWith("#")) continue;
		const pair = line.match(/^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$/);
		if (pair === null) {
			fail(`${rel}：frontmatter 无法解析的行「${line}」`);
			continue;
		}
		data.set(pair[1], unquote(pair[2]));
	}
	return { data, body: text.slice(match[0].length) };
}

/** 从 Markdown 表格行里抽取被反引号包起来的命令引用。 */
async function tableRefs(readme, pattern) {
	const text = await readFile(readme, "utf8");
	const refs = new Set();
	for (const line of text.split(/\r?\n/)) {
		if (!line.trim().startsWith("|")) continue;
		for (const span of line.matchAll(/`([^`]+)`/g)) {
			const hit = span[1].trim().match(pattern);
			if (hit !== null) refs.add(hit[1]);
		}
	}
	return refs;
}

/** 解析「指令 | 委托的 skill 分支」表：`| \`git/x\` | \`git-kit\` branch |`。 */
async function parseMappingTable(readme) {
	const text = await readFile(readme, "utf8");
	const mappings = new Map();
	for (const line of text.split(/\r?\n/)) {
		const hit = line.match(/^\|\s*`(git\/[a-z0-9-]+)`\s*\|\s*`([a-z0-9-]+)`\s+([a-z0-9-]+)\s*\|/);
		if (hit !== null) mappings.set(hit[1], { skill: hit[2], branch: hit[3] });
	}
	return mappings;
}

const COMMAND_NAME = String.raw`(git/[a-z0-9-]+|handoff)`;
const LOCAL_README_PATTERN = new RegExp(`^(?:commands-opencode/)?${COMMAND_NAME}$`);
// 根 README 的命令表用真实斜杠写法（`/git/message <描述>`），也兼容旧的 commands-opencode/... 写法。
// 必须带 `/` 或 `commands-opencode/` 前缀，避免把技能表里的裸 `handoff` 当成命令。
const ROOT_README_PATTERN = new RegExp(`^(?:/|commands-opencode/)${COMMAND_NAME}(?=[\\s<]|$)`);

const commands = new Map();
// 文件存在但声明不完整时也记下来，避免 README「引用了不存在的命令」的级联误报。
const knownNames = new Set();

async function checkCommand(file) {
	const rel = file.slice(COMMANDS_DIR.length + 1).replaceAll("\\", "/");
	const name = rel.replace(/\.md$/, "");
	knownNames.add(name);
	const text = await readFile(file, "utf8");
	const parsed = parseFrontmatter(text, rel);

	if (parsed === undefined) {
		fail(`${rel}：缺少 frontmatter（--- ... ---）`);
		return;
	}

	for (const key of parsed.data.keys()) {
		if (!ALLOWED_FRONTMATTER.has(key)) {
			fail(`${rel}：frontmatter 出现非官方字段 \`${key}\`（只允许 ${[...ALLOWED_FRONTMATTER].join(" / ")}）`);
		}
	}

	const description = parsed.data.get("description");
	if (description === undefined || description === "") {
		fail(`${rel}：frontmatter 缺少 description（斜杠菜单会显示为空）`);
	} else if ([...description].length > DESCRIPTION_WARN) {
		note(`${rel}：description 有 ${[...description].length} 字，斜杠菜单里偏长（建议 ≤${DESCRIPTION_WARN}）`);
	}

	const declaration = parsed.body.match(/本命令由 `([a-z0-9-]+)` skill 的 \*\*([a-z0-9-]+) 分支\*\*实现/);
	if (declaration === null) {
		fail(`${rel}：正文缺少「本命令由 \`<skill>\` skill 的 **<branch> 分支**实现」声明`);
		return;
	}
	const [, skill, branch] = declaration;
	if (!parsed.body.includes(`用 \`skill\` 工具加载 \`${skill}\``)) {
		fail(`${rel}：正文没有要求用 skill 工具加载 \`${skill}\``);
	}

	const argLines = parsed.body.split(/\r?\n/).filter((line) => line.includes("$ARGUMENTS"));
	if (argLines.length > 0) {
		for (const line of argLines) {
			if (line.trim() !== "$ARGUMENTS") {
				fail(`${rel}：$ARGUMENTS 必须独立成行裸写（当前行为「${line.trim()}」）`);
			}
		}
	} else if (!parsed.body.includes("本命令无参数")) {
		fail(`${rel}：没有 $ARGUMENTS，也没有显式写「本命令无参数」`);
	}

	const skillDir = join(SKILLS_DIR, skill);
	const skillMd = join(skillDir, "SKILL.md");
	if (!(await isFile(skillMd))) {
		fail(`${rel}：找不到技能 ${skill}（${skillMd}）`);
	} else if (await isDir(join(skillDir, "references"))) {
		const reference = join(skillDir, "references", `${branch}.md`);
		if (!(await isFile(reference))) {
			fail(`${rel}：/${name} → ${skill}#${branch} 缺少 ${reference.slice(ROOT.length + 1)}`);
		}
	} else {
		const skillText = await readFile(skillMd, "utf8");
		if (!skillText.includes(branch)) {
			note(`${rel}：单文件技能 ${skill}，只校验 SKILL.md 存在（branch「${branch}」是装饰性的）`);
		}
	}

	commands.set(name, {
		file,
		rel,
		skill,
		branch,
		description: description ?? "",
		required: parsed.body.includes("必填"),
	});
}

function parseArgs(argv) {
	let dshPath;
	for (let index = 0; index < argv.length; index++) {
		const arg = argv[index];
		if (arg === "-h" || arg === "--help") return { help: true };
		if (arg === "--dsh") {
			dshPath = argv[++index];
			if (dshPath === undefined) return { error: "--dsh 需要一个路径参数" };
			continue;
		}
		if (arg.startsWith("--dsh=")) {
			dshPath = arg.slice("--dsh=".length);
			if (dshPath === "") return { error: "--dsh 需要一个路径参数" };
			continue;
		}
		return { error: `未知参数：${arg}` };
	}
	return { dshPath };
}

function usage() {
	console.log(`用法: node scripts/check-opencode-commands.mjs [--dsh <dsh-commands 仓路径>]

  --dsh <path>  顺带比对另一仓 lib/index.js 的 COMMANDS 表（branch/skill 不一致判失败，
                描述差异只提示）。CI 不传；本机同时有两仓时用它抓跨仓漂移。
  -h, --help    显示本帮助。`);
}

async function compareDsh(dshPath, commands) {
	const entry = join(dshPath, "lib", "index.js");
	let module;
	try {
		module = await import(pathToFileURL(entry).href);
	} catch (error) {
		fail(`无法加载 dsh 插件 ${entry}：${error instanceof Error ? error.message : String(error)}`);
		return;
	}
	if (!Array.isArray(module.COMMANDS)) {
		fail(`${entry} 没有导出 COMMANDS 数组`);
		return;
	}

	const byName = new Map();
	for (const def of module.COMMANDS) {
		const name = def.name === "handoff" ? "handoff" : def.name.replace(/^git-/, "git/");
		byName.set(name, def);
	}

	for (const [name, info] of commands) {
		const dsh = byName.get(name);
		if (dsh === undefined) {
			note(`${name}：dsh 侧没有对应命令`);
			continue;
		}
		if (dsh.branch !== info.branch) {
			fail(`${name}：branch 不一致（opencode=${info.branch} / dsh=${dsh.branch}）`);
		}
		const dshSkill = dsh.skill ?? "git-kit";
		if (dshSkill !== info.skill) {
			fail(`${name}：skill 不一致（opencode=${info.skill} / dsh=${dshSkill}）`);
		}
		if (Boolean(dsh.required) !== info.required) {
			note(`${name}：必填语义可能不一致（opencode 正文${info.required ? "标了" : "没标"}「必填」/ dsh required=${Boolean(dsh.required)}）`);
		}
		if (dsh.description !== info.description) {
			note(`${name}：两个入口的 description 有差异（opencode / dsh 各自面向自己的菜单，允许；改语义时记得两边都改）`);
		}
	}

	// 反向：dsh 有委托命令、opencode 没有入口（本地执行型命令在 dsh 侧是 LOCAL_COMMANDS，不在 COMMANDS 里）。
	for (const [name] of byName) {
		if (!commands.has(name)) {
			note(`${name}：dsh 侧有委托命令，opencode 侧没有对应入口`);
		}
	}
}

const parsed = parseArgs(process.argv.slice(2));
if (parsed.help === true) {
	usage();
	process.exit(0);
}
if (parsed.error !== undefined) {
	console.error(`错误：${parsed.error}`);
	usage();
	process.exit(2);
}

const files = await collectCommandFiles(COMMANDS_DIR);
if (files.length === 0) {
	console.error(`错误：${COMMANDS_DIR} 下没有命令文件`);
	process.exit(2);
}

for (const file of files) await checkCommand(file);

// 命令集合与 README 表格必须一一对应：这次漏掉 /git/release 就是这里暴露的。
const localRefs = await tableRefs(COMMANDS_README, LOCAL_README_PATTERN);
const rootRefs = await tableRefs(ROOT_README, ROOT_README_PATTERN);
for (const name of knownNames) {
	if (!localRefs.has(name)) fail(`commands-opencode/README.md 的表格缺少 \`${name}\``);
	if (!rootRefs.has(name)) fail(`README.md 的表格缺少 \`commands-opencode/${name}\``);
}
for (const name of localRefs) {
	if (!knownNames.has(name)) fail(`commands-opencode/README.md 的表格引用了不存在的命令 \`${name}\``);
}
for (const name of rootRefs) {
	if (!knownNames.has(name)) fail(`README.md 的表格引用了不存在的命令 \`commands-opencode/${name}\``);
}

// 联动表里的 branch 也必须与正文声明一致：改分支名时最容易漏掉这一列。
const mappings = await parseMappingTable(COMMANDS_README);
for (const [name, info] of commands) {
	if (info.skill !== "git-kit") continue;
	const mapping = mappings.get(name);
	if (mapping === undefined) {
		fail(`commands-opencode/README.md 的联动表缺少 \`${name}\`（该表是命令 → skill 分支的文档契约）`);
		continue;
	}
	if (mapping.skill !== info.skill) {
		fail(`${name}：联动表写的 skill 是 ${mapping.skill}，正文声明的是 ${info.skill}`);
	}
	if (mapping.branch !== info.branch) {
		fail(`${name}：联动表写的 branch 是 ${mapping.branch}，正文声明的是 ${info.branch}`);
	}
}
for (const name of mappings.keys()) {
	if (!knownNames.has(name)) fail(`commands-opencode/README.md 的联动表引用了不存在的命令 \`${name}\``);
}

if (parsed.dshPath !== undefined) await compareDsh(parsed.dshPath, commands);

for (const message of notes) console.log(`· ${message}`);
for (const message of errors) console.error(`✗ ${message}`);

const noteSuffix = notes.length > 0 ? `，${notes.length} 条提示` : "";
console.log(
	errors.length > 0
		? `opencode 命令校验失败：${errors.length} 项${noteSuffix}`
		: `opencode 命令校验通过：${commands.size} 条命令${noteSuffix}`,
);
process.exit(errors.length > 0 ? 1 : 0);
