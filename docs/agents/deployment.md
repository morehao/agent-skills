# 接入与生效语义

接入的**操作步骤**与排错在 [安装与维护](../installation.md)；这里只记 agent 改动前必须知道的语义与坑。

## 两层：编辑源 vs 运行时真源

```
本仓（编辑源，git 版本化）--skills-install.sh（skills CLI）--> ~/.agents/skills（本源，真实内容）
                                                                  --软链--> 各 agent 技能目录（skills-fanout.sh）
```

- **本仓不是运行时真源**：改 `skills/` 后**不会**自动生效，必须 `git push` + `./scripts/skills-install.sh` 才发布到本源。
- **本源是 `~/.agents/skills`**（`AGENTS_SKILLS_DIR` 可覆盖）：真实内容都在这，第三方技能（`officecli`、`weather-query` 等）也装在同一处。
- **各 agent 目录只有软链**：`scripts/skills-fanout.sh` 建 `~/.config/opencode/skills/<name>`、`~/.dsh/skills/<name>`（可选 `~/.claude/skills/<name>`）指向本源。所以其它 agent 看到的永远是**已发布**内容，不会被某个工作区的半成品影响。
- **命令没法搬到本源**：opencode 只认配置目录下的 `command/`，那部分仍由 `opencode-install.sh` 从本仓软链（命令是委托壳，改本仓即时生效——这点和技能不同）。
- **不要编辑软链副本**，也不要在插件仓改技能逻辑。dsh 里软链注册的技能带 `linked` 标记且**只读**（禁止编辑/删除）。
- opencode v2.x 同时扫描配置目录下的 `command/` 与 `commands/`（源码 `scan("{command,commands}/**/*.md")`，命令名会剥掉这层前缀），本仓沿用 `command/`。

## 发布与分发的分工

| 动作 | 脚本 | 方向 | 何时跑 |
|---|---|---|---|
| 发布内容 | `skills-install.sh` | 本仓 → 本源（skills CLI） | 首次；本仓技能有更新且已 push 之后 |
| 分发软链 | `skills-fanout.sh` | 本源 → 各 agent 目录 | 首次；本源新增/删除技能之后 |
| 只读自查 | 两者 `--check` | — | 怀疑「命令能点但 skill 加载失败」时 |

`skills-install.sh` 装的是**远端**内容：脚本会提示「工作区脏 / 本地领先 `origin/main`」，此时装到的是旧版本。`skills update` 不要用（它内部 spawn 的 `add` 不带 `-a universal`，会往上百个 agent 目录撒链）。

## profile 由脚本解析，不要写死

优先级：`--profile <name>` > `$DSH_PROFILE` > 「`$DSH_HOME/profiles` 下**唯一**存在的 profile」。查看实际有哪些 profile 用 `ls ~/.dsh/profiles/`（**桌面版是 `desktop`**）。多个/零个 profile 时脚本报错列出候选，**不会**替你新建——早期版本写死 `web`，正是会凭空造 profile 的坑。

`dsh` CLI 也不要求先在 PATH：脚本会回退到桌面版 app 包内的 `runtime/cli/bin/dsh`（`*/runtime/cli/bin/dsh` 分支会额外提示先退出客户端再登记，避免并发改写 profile 配置）。确实找不到才报错，此时技能软链那一步已经完成。

## 热加载与技能根

- **本源**：`~/.agents/skills`（dsh 直接扫描，也是 `skills` CLI 的 canonical 目录）。
- **软链层**：`~/.dsh/skills`（由 fanout 维护）；项目级 `<项目根>/.dsh/skills`、`<项目根>/.agents/skills` 也会被扫描。
- 新增/变更**软链**后无需重启（新会话与技能面板立即生效）；只有插件 `lib/index.js` 改动才需要重启 dsh。
- 改了**技能内容**：发布到本源（`skills-install.sh`）后即生效，不需要重启。

## `skills/` 目录约定

`skills/` 下只允许放技能目录（如 `git-kit/`），禁止放置任何松散说明文件。因为 `ln -sfn skills/*` 会展开全部条目，新增的非目录文件会被一并软链过去（`skills-install.sh` 只遍历目录，已规避该问题，但约定仍然成立）。

## 没有 `/skill-init` 这类 opencode 命令

dsh 侧需要 `/skill-init`，是因为「插件走 npm、技能另装、dsh 又不扫 `node_modules`」。本仓的发布链路已经由 `skills-install.sh`（skills CLI）+ `skills-fanout.sh` 覆盖，两者幂等且都有 `--check`，可本地可 CI。**不要在 opencode 侧为它造一条斜杠命令**：命令是提示词模板，没有确定性执行、没有确认卡，`!` 注入在展开阶段就跑，且拿不到自身仓库路径。

## 发布工具链在另一仓

本仓**不再有**任何 npm / pnpm / OIDC 构件：`package.json` / `pnpm-workspace.yaml` / `pnpm-lock.yaml` / `.github/workflows/release.yml` / `scripts/ci-publish.sh` / `PUBLISHING.md` 已随插件一起迁到 [morehao/dsh-commands](https://github.com/morehao/dsh-commands)。`git clone` 本仓后用技能不需要 node/pnpm（`skills/project-insight/scripts` 自己的一次性 `npm install` 除外）。
