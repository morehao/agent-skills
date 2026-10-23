# 接入与生效语义

接入的**操作步骤**与排错在 [安装与维护](../installation.md)；这里只记 agent 改动前必须知道的语义与坑。

## 本仓是唯一真源

- **技能只有一个安装位**：`~/.agents/skills`（可用 `AGENTS_SKILLS_DIR` 覆盖）。`scripts/skills-link.sh` 把 `skills/<name>` 软链进去；第三方技能由 `skills` CLI 装成真实目录放在同一处，互不干扰。
- **opencode**：技能靠 config 的 `skills` 数组看见 `~/.agents/skills`（不加这行就看不到）；`commands-opencode/git`、`handoff.md`、`cleanup.md` 仍软链到 `~/.config/opencode/command/`（命令没法搬到 `~/.agents`）。等价手敲列表见 installation.md。
- **dsh**：默认扫描 `~/.agents/skills`，不需要再往 `$DSH_HOME/skills` 建第二份软链；插件用 `dsh plugin --profile <profile> add @morehao/dsh-commands` 装，本体在另一仓，调试用 `--plugin-link <插件仓路径>` 走 `link:`（显式传参，脚本不猜路径）。
- 因此**不要编辑软链副本**，也不要在插件仓改技能逻辑。dsh 里软链注册的技能带 `linked` 标记且**只读**（禁止编辑/删除），正合「本仓是唯一真源」。
- opencode v2.x 同时扫描配置目录下的 `command/` 与 `commands/`（源码 `scan("{command,commands}/**/*.md")`，命令名会剥掉这层前缀），本仓沿用 `command/`。

## profile 由脚本解析，不要写死

优先级：`--profile <name>` > `$DSH_PROFILE` > 「`$DSH_HOME/profiles` 下**唯一**存在的 profile」。查看实际有哪些 profile 用 `ls ~/.dsh/profiles/`（**桌面版是 `desktop`**）。多个/零个 profile 时脚本报错列出候选，**不会**替你新建——早期版本写死 `web`，正是会凭空造 profile 的坑。

`dsh` CLI 也不要求先在 PATH：脚本会回退到桌面版 app 包内的 `runtime/cli/bin/dsh`（`*/runtime/cli/bin/dsh` 分支会额外提示先退出客户端再登记，避免并发改写 profile 配置）。确实找不到才报错，此时技能软链那一步已经完成。

## 热加载与技能根

- **落点**：`~/.agents/skills`（本仓技能唯一的安装位，也是 `skills` CLI 与 dsh 的 canonical 技能根）。
- **仍被扫描但不再是落点**：`~/.dsh/skills`（用户级）、`<项目根>/.dsh/skills`（项目级）、`<项目根>/.agents/skills`（项目级第三方技能）。
- 新增/变更技能软链后**无需重启**：新会话与技能面板立即生效。只有改插件 `lib/index.js` 才需要重启 dsh。

## `skills/` 目录约定

`skills/` 下只允许放技能目录（如 `git-kit/`），禁止放置任何松散说明文件。因为 `ln -sfn skills/*` 会展开全部条目，新增的非目录文件会被一并软链过去（`scripts/skills-link.sh` 只遍历目录，已规避该问题，但约定仍然成立）。

## 没有 `/skill-init` 这类命令

dsh 侧需要 `/skill-init`，是因为「插件走 npm、技能另装、dsh 又不扫 `node_modules`」。本仓的技能与 opencode 命令都来自同一次 clone：`skills-link.sh` + `opencode-install.sh` 幂等软链，`git pull` 即更新；检查用各自的 `--check`（退出码 1 = 有问题），可本地可 CI。**不要在 opencode 侧为它造一条斜杠命令**：命令是提示词模板，没有确定性执行、没有确认卡，`!` 注入在展开阶段就跑，且拿不到自身仓库路径。

## 发布工具链在另一仓

本仓**不再有**任何 npm / pnpm / OIDC 构件：`package.json` / `pnpm-workspace.yaml` / `pnpm-lock.yaml` / `.github/workflows/release.yml` / `scripts/ci-publish.sh` / `PUBLISHING.md` 已随插件一起迁到 [morehao/dsh-commands](https://github.com/morehao/dsh-commands)。`git clone` 本仓后用技能不需要 node/pnpm（`skills/project-insight/scripts` 自己的一次性 `npm install` 除外）。
