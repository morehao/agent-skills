# opencode 扩展工具集 (ai-kit)

本项目集中管理我要用的 opencode 自定义扩展：一部分是 `commands-opencode/`（斜杠指令），一部分是 `skills/`（技能）；同源逻辑还以 `commands-dsh/` 插件形式接入 dsh（见 [dsh 接入](#dsh-接入可选)）。

## 目录结构

```
ai-kit/
├── README.md                  # 本说明
├── LICENSE
├── PUBLISHING.md              # npm 发包流程与踩坑说明（@morehao/dsh-commands / OIDC）
├── commands-opencode/          # opencode 斜杠指令
│   ├── README.md              # 指令功能与用法说明
│   ├── handoff.md             # 跨会话交接指令（/handoff，只打印）
│   └── git/                   # Git 相关指令
│       ├── branch.md
│       ├── message.md
│       ├── pr-create.md
│       ├── pr-merge.md
│       ├── tag.md
│       ├── commit-push.md
│       ├── slim.md
│       └── star-classify.md
├── commands-dsh/              # dsh 插件：git-kit / handoff 的 dsh 原生斜杠命令入口（命令=意图表，与 opencode 入口共享 skill）
│   ├── package.json
│   ├── cordis.patch.yml
│   ├── lib/index.js
│   └── README.md
├── docs/                      # 说明文档：git-kit 工作流解释（含 Mermaid / SVG 图）
│   ├── git-kit.md             #   入口与路由、提交→PR→合并、发版（tag / release）
│   └── assets/                #   图（SVG）
├── scripts/
│   └── dsh-install.sh         # dsh 一键接入：软链 skills + 注册 commands-dsh 插件
└── skills/                    # 技能（opencode 与 dsh 共用）
    ├── git-kit/               # Git 工作流辅助（message/commit-push/branch/pr-create/pr-merge/tag/release/slim/star）
    │   ├── references/        # 拆分的辅助逻辑
    │   └── scripts/           # 附带脚本
    ├── handoff/               # 跨会话交接：把当前会话压成可粘贴的续跑提示（只打印）
    │   └── references/
    ├── project-insight/       # 开源项目深度解读
    │   ├── references/        # 拆分的辅助逻辑
    │   └── scripts/           # 附带脚本
    ├── project-wiki/          # 面向广泛读者的项目 Wiki 文档（散文+图+表，代码密度极低）
    │   ├── references/        # 页面规划/页面骨架/写作风格/图表/轻量真源
    │   └── scripts/           # 文档门禁（自研）+ 基线/图校验薄壳（复用 project-insight 引擎）
    ├── tech-design/           # 技术方案/技术设计文档生成（原 tech-design-proposal / design-doc）
    │   ├── references/        # 叙事链与三档骨架/落点与场景义务/专题加固/量化估算/质量红线
    │   └── scripts/           # 图校验薄壳：Mermaid 解析 + SVG 边拓扑审计/预览（复用 project-insight 引擎）
    └── svg-maker/             # 自包含纯 SVG 图表生成
        └── references/
```

## skills —— 技能

| 路径 | 功能 |
|------|------|
| `skills/git-kit` | Git 工作流辅助工具包，按意图路由到生成 commit message、提交推送、创建/切换分支、创建/更新 PR/MR、按编号合并 PR/MR 并回主干更新、给分支打版本标签并推送、仓库瘦身、分类 star。 |
| `skills/handoff` | 跨会话交接：把当前会话的任务状态压缩成一段可直接粘贴的续跑提示（只打印、不落盘），新会话粘贴即可继续；命令入口为 `/handoff`。 |
| `skills/project-insight` | 开源项目深度解读，产出每个论断都带可点开验证的真实源码引用（文件:行号），避免幻觉。 |
| `skills/project-wiki` | 面向**不读源码的读者**生成项目 Wiki 文档（Markdown）：散文为主 + 架构图 + 表格，**代码密度极低**。立场是"读者不打开源码也能读懂"，所以表达手段按**读者成本**排序（散文 → 图 → 表 → 代码），出处**收进章末一行 `> 依据：…`** 而不是逐句内联；真实性由**作者侧程序校验**保证（路径存在、行号未越界、Mermaid 真渲染），正文**不留任何校验痕迹**（禁锚点指纹与 `Sources:`）。图默认用 **Mermaid**，仅结构/分层、左右对比、回边状态机、节点 ≥12 四类升级 SVG（`svg-maker` 产出，放 `assets/`）。**与 project-insight 分工**：要逐条可点开核验、要深挖设计权衡走 project-insight；要给团队一份能读的文档走本技能。门禁 `scripts/check-all.mjs` 为**唯一入口**，检查代码预算（每页 ≤3 块 / 单块 ≤15 行 / 单页 ≤40 行，可写 `<!-- code-budget: 理由 -->` 显式豁免）、依据行真实性、首页索引一致性、图表复杂度与参与者声明等 19 个输出码，并有回归测试 `scripts/tests/gates-regression.sh`（23 条断言）。**零额外依赖**：Mermaid 校验与基线选择是薄壳，复用 project-insight 引擎（单一真源），无需另行 `npm install`。 |
| `skills/tech-design`（原 `tech-design-proposal`，曾用名 `design-doc`） | 编写技术方案/技术设计文档：三轴决策——**档位**（轻量/标准/完整）定篇幅、**场景**（新建/增量改造/结构重构/替换与迁移/下线与废弃/专项优化，单选）定过程义务（影响面与兼容、行为基线与等价性验证、对账与回退窗口、消费者盘点与下线判据）、**专题**（架构/API/数据模型/性能与容量/安全/迁移手法，可多选）定技术加固点；场景判定前先答**落点**第 0 问（新系统 / 既有系统的新模块 / 既有系统的既有模块），决定取证对象与义务增量（宿主约束、对宿主的影响、必须谁签）；先按**叙事链** 9 问推理（为什么现在做 → 有什么实体 → 什么问题 → 约束 → 整体 → 拆分 → 流转 → 怎么证明 → 理由与落地）再成文，**取证先于动笔**；四条硬要求——**事实有据**（既有系统的现状/影响面/调用方/容量水位须带 `路径:行号`、监控口径或工单号，取不到标 `[待核实]`）、**量化义务**（性能/容量/可用性/成本/收益须给数字 + 口径 + 假设，量级表见 `quantification.md`）、**取舍对偶**（每个选型写代价与不该选的场景，并回指目标）、**宁轻勿重**；配图 **Mermaid 与 SVG 均为一等公民**（结构/拓扑/分层/对比/回边状态机走 SVG，经 `svg-maker` 产出；时序与线性小图用 Mermaid；节点 ≥12 或含分层/泳道即改用 SVG），同一张图不做双份，图有程序校验（Mermaid 解析 / SVG 边拓扑审计与预览），产出可评审、可执行的 Markdown 文档。 |
| `skills/svg-maker` | 生成自包含、纯 SVG 的架构图、流程图与概念图，可离线打开。 |

每个 skill 目录下是一个 `SKILL.md`（含 frontmatter 定义触发条件），复杂逻辑可拆到 `references/` 子目录。`skills/` 下只放各技能的目录，不放置说明性文件（见下方"用法说明"）。

> **联动**：`skills/git-kit` 是 Git 工作流逻辑与意图路由的唯一真源；`commands-opencode/git/*`（opencode 斜杠）与 `commands-dsh/`（dsh 斜杠）只是**命令入口**，声明「命令 → git-kit 分支」映射并交给 git-kit 执行，互为多条入口（opencode 斜杠指令 / dsh 斜杠命令 / 自然语言触发）。`skills/handoff` 同理：`commands-opencode/handoff.md` 与 dsh `/handoff` 只声明「命令 → handoff print 分支」，只打印交接文本、不落盘。

## commands —— 斜杠指令

`commands-opencode/` 下是 Git 工作流与跨会话交接的自定义指令：

| 路径 | 功能 |
|------|------|
| `commands-opencode/git/branch` | 基于中文描述生成候选分支名，选择后从基准分支创建并切换 |
| `commands-opencode/git/message` | 将中文描述转换为 Conventional Commits 格式的 commit message（纯生成，不提交） |
| `commands-opencode/git/pr-create` | 基于代码差异向目标仓库创建或更新 PR/MR（自动识别 gh/glab） |
| `commands-opencode/git/pr-merge` | 按编号合并 PR/MR，删除原分支（head 为稳定分支时保留），切回主干并更新代码（自动识别 gh/glab） |
| `commands-opencode/git/tag` | 查看最新 tag 与来源分支，选择要打 tag 的分支与版本号，构建注记 tag 并推送 |
| `commands-opencode/git/release` | pr-merge 之后的发布段：打 tag → 默认创建 GitHub/GitLab Release → 跟踪其他后效并逐项校验 |
| `commands-opencode/git/commit-push` | 基于代码变更自动生成 commit message 并执行提交推送 |
| `commands-opencode/git/slim` | 将当前 git 仓库瘦身为浅克隆，默认保留 30 天历史 |
| `commands-opencode/git/star-classify` | 拉取并分类自己的 GitHub star 仓库，输出中文分组清单 |
| `commands-opencode/handoff` | 把当前会话的任务状态压缩成一段可粘贴的续跑提示，供新会话继续执行（只打印，不落盘） |

详见 [commands-opencode/README.md](commands-opencode/README.md)。

## dsh 接入（可选）

`commands-dsh/` 以 **dsh 原生命令**形式暴露 git-kit 工作流与跨会话交接：`/git-message`、`/git-commit-push`、`/git-branch`、`/git-pr-create`、`/git-pr-merge`、`/git-release`、`/git-tag`、`/git-slim`、`/git-star-classify`、`/handoff`。插件是**自包含意图表**（一行声明 = 命令名 + 对应 skill 分支 key，`skill` 省略时默认 git-kit），命令执行时向当前 agent 注入一条加载对应 skill（git-kit / handoff）并按其分支执行的指令——与 opencode 入口共用同一 skill、单一真源，编辑 `skills/git-kit/` 或 `skills/handoff/` 即同步生效（改插件 `lib/index.js` 需重启 dsh）。

一键接入（幂等，可重复执行）：

```bash
./scripts/dsh-install.sh --skills-only     # 只挂技能：零副作用、不需要 dsh CLI —— 最常用的安全子集
./scripts/dsh-install.sh                    # 全量接入：技能 + 插件注册（profile 自动解析）
./scripts/dsh-install.sh --profile desktop   # 显式指定 profile（等价 DSH_PROFILE=desktop）
DSH_USE_NPM=1 ./scripts/dsh-install.sh       # 插件改走 npm 已发布包，而非本地 link:
# 插件变更后重启 dsh；技能是热加载的，不用重启
```

脚本做两件事：① 软链 `skills/*` 到 `$DSH_HOME/skills`（默认 `~/.dsh/skills`，**全局生效**）；② `dsh plugin --profile <profile> add link:<本仓库>/commands-dsh`（`link:` 为真软链，源码改动即生效；自动追加进 profile 的 bundles）。传 `--skills-only` 则只做第 ① 步。

> **profile 不再硬编码**（早期版本写死 `web`，与实际安装不符时会凭空造出一个 profile，命令却不出现在你正在用的客户端里）。现在的优先级是：`--profile <name>` > `$DSH_PROFILE` > 「`$DSH_HOME/profiles` 下**唯一**存在的 profile」。多个或零个 profile 时会报错并列出候选，绝不会替你新建。
>
> `dsh` CLI 也**不要求先在 PATH 上**：脚本找不到时会回退到 macOS 桌面版 app 包内的 `<DeepSeek Harness.app>/Contents/Resources/runtime/cli/bin/dsh`，并提示先退出客户端再执行插件步骤（避免两边并发改写 profile 配置）；确实找不到才报错，且第 ① 步的技能软链此时已经完成。

**想手动做第 ① 步**（等效 `--skills-only`，不跑脚本）：

```bash
mkdir -p "$DSH_HOME/skills"     # 默认 ~/.dsh/skills；这是 dsh 的**用户级**技能根
for name in git-kit handoff project-insight project-wiki svg-maker tech-design; do
  ln -sfn "<本仓库>/skills/$name" "$DSH_HOME/skills/$name"
done
ls -la "$DSH_HOME/skills"       # 验证：6 条软链均无悬空
```

dsh 侧技能目录约定（`skills/` 是**全局**的，软链后所有项目可用）：
- 用户级 `<dshHome>/skills` = `~/.dsh/skills` ← 本仓库软链目标
- 项目级 `<项目根>/.dsh/skills`（项目根 = 最近的含 `.git` 祖先目录）
- 另扫描 `~/.agents/skills` 与 `<项目根>/.agents/skills`

经软链注册的技能在 dsh 技能面板中带 `linked` 标记、为**只读**（禁用编辑/删除），正好避免误改真源。**技能是热加载的**：新增软链后无需重启，新会话与技能面板立即能看到；只有插件 `lib/index.js` 的改动才需要重启。

> 插件已发布到 npm（`@morehao/dsh-commands`），也可只装命令插件本体：`dsh plugin --profile <profile> add @morehao/dsh-commands`（`<profile>` 同样以实际为准）。注意 skills **仍需来自本仓库**（dsh 不从 node_modules 扫描 skill），所以用 npm 方式时请另行软链 `skills/*` 或执行上面的 skills 步骤。发包/更新到 npm 的完整流程见 [PUBLISHING.md](PUBLISHING.md)。

卸载：`dsh plugin --profile <profile> remove @morehao/dsh-commands`，再删除对应的 skill 软链（`rm ~/.dsh/skills/<name>`）即可。（旧版曾以 `dsh-git-commands` 或 `@morehao/dsh-git-commands` 安装过：对应 `dsh plugin --profile <profile> remove dsh-git-commands` / `dsh plugin --profile <profile> remove @morehao/dsh-git-commands`。）

详见 [commands-dsh/README.md](commands-dsh/README.md)。

## 文档

工作流的解释性文档：[`docs/git-kit.md`](docs/git-kit.md)——三条入口与一个实现、意图路由、九个分支、稳定分支的唯一定义、`commit-push` → `pr-create` → `pr-merge`（含 head 去留）、发版段（状态机 / 发布时序 / 后效探测 / 变更说明）。

> `skills/git-kit/SKILL.md` 是给模型看的操作指令，`docs/` 是给人看的说明，两者不互相替代。

## 用法说明

这些命令与技能通过**软链接**注册到本机 opencode 配置目录来启用，不改动本仓库内的文件，便于后续 `git pull` 同步更新。配置目录默认为 `~/.config/opencode/`。

将本仓库路径替换到下方命令中的 `/path/to/ai-kit` 后执行：

```bash
# 软链 skills 到 opencode 的 skills 目录
ln -sfn /path/to/ai-kit/skills/* ~/.config/opencode/skills/

# 软链 commands 到 opencode 的 command 目录
ln -sfn /path/to/ai-kit/commands-opencode/git ~/.config/opencode/command/git
ln -sfn /path/to/ai-kit/commands-opencode/handoff.md ~/.config/opencode/command/handoff.md
```

> **约定**：`skills/` 下只放各技能的目录（如 `git-kit/`），不放置说明性文件。`skills/*` 会展开全部条目，若未来在 `skills/` 新增非目录文件，会一并被软链到 skills 目录，故请保持该约定。
>
> 提示：若不希望跟随本仓库更新，也可改用复制方式（`cp -r`）；若本机已在对应位置存在**同名真实目录**，需先手动移走再由命令建立软链。

安装/卸载逻辑均只涉及本机配置目录（`~/.config/opencode/`）。`commands-opencode/README.md` 仅说明功能与用法，不重复安装步骤；本仓库的功能一览见本文档，各 skill 与指令的命名与目录结构见上文目录树。
