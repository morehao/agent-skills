# AGENTS.md

本仓库集中管理个人 AI 编码工具扩展：`commands-opencode/`（opencode 斜杠指令）+ `skills/`（技能，opencode / dsh 共用）。dsh 的斜杠命令插件在独立仓 [morehao/dsh-commands](https://github.com/morehao/dsh-commands)（npm 安装；本仓只提供它依赖的技能）。所有说明用**简体中文**。

## 决策原则：按终局设计，不做「最小改动」

假设今天写下的东西会被维护三年。先想清楚**终局里它该长什么样**，再一次性做到位；为此**允许破坏兼容、允许大改、允许花成本**，不因为「改起来多」而降级方案，也不拿「最小改动」当默认答案。

判断方案按顺序过五条，任一不过就否决：

1. **归属**：终局里这段逻辑该由我们拥有吗？不该拥有的别写，删掉或交出去。
2. **许可证**：搬进来的东西我们能长期承担吗？（本仓 MIT，GPL 代码与数据不可内联）
3. **依赖**：三年后上游改契约、停维护、涨价，我们能不能自己修？
4. **分发**：用户装得上吗？技能是文件，不能要求编译，也不能要求先装第三方 CLI。
5. **可观测**：坏了能不能从输出定位，而不是靠猜。

同时禁止这些「省钱」动作：

- 加开关或兼容层，把没想清楚的设计盖住；
- 为一个 2× 的性能或一个边角场景，引入不可控的运行时依赖；
- 保留明知是错的抽象，只因为改起来麻烦；
- 把「最小改动」写进方案——要么一次做到位，要么写明只做这一步的理由和下一步的时间点。

破坏性变更必须配迁移路径与用户影响说明。会被反复讨论的问题（「为什么不直接调用 X」这类）把理由落进 `docs/`，见[决策记录](docs/agents/decisions.md)。

## 硬约束（改动前先过一遍）

1. **两层：本仓是编辑源，`~/.agents/skills` 是运行时本源**。技能内容改动需用 `skills` CLI 发布到本源后生效（`npx -y skills add morehao/agent-skills --skill <name> ... -g -a universal -y`，见 [安装与维护](docs/installation.md)）；各 agent 目录只放指向本源（`AGENTS_SKILLS_DIR` 可覆盖）的软链，由 `./scripts/skills-fanout.sh` 维护。opencode 的**命令**没法搬，仍从本仓软链到其配置目录——命令改本仓即时生效，技能不然。不要编辑软链副本。接入语义见 [接入与生效语义](docs/agents/deployment.md)。
2. **`skills/` 下只允许技能目录**，禁止松散说明文件（`ln -sfn skills/*` 会展开全部条目）。
3. **升版本不得直接提交稳定分支**（`main` 也不接受直推，发版不构成例外）：改 version → 分支 → PR → 合并 → 打 tag。细则见 [发版纪律](docs/agents/release-discipline.md)。
4. **过程性文档落 `.dsh/docs/`**，该目录整体被 gitignore、只留本地；需要入库的方案/设计放仓库 `docs/` 或技能目录。
5. **改脚本按 bash 3.2 写**：不用 `mapfile` / 关联数组 / `${var,,}`；变量后紧跟中文必须写 `${var}`（否则 `unbound variable`）。

## 文档地图（按需加载，别一次全读）

| 要做什么 | 读哪份 |
|---|---|
| 接入 opencode / dsh、命令契约、新增命令 | [安装与维护](docs/installation.md) |
| 技能定位与分工（给人看） | [技能说明](docs/skills.md) |
| 目录、脚本与三个入口 | [仓库地图](docs/agents/repository-map.md) |
| 各技能的硬规则与内部结构 | [技能内部规则](docs/agents/skill-internals.md) |
| 某能力为何不引入外部依赖、历史取舍 | [决策记录](docs/agents/decisions.md) |
| 软链 / profile / 热加载 / 工具链归属 | [接入与生效语义](docs/agents/deployment.md) |
| 发版纪律与 `/git/release` 边界 | [发版纪律](docs/agents/release-discipline.md) |
| 跑校验、门禁与退出码 | [校验与运行](docs/agents/verification.md) |
| 写作、命名、Git、脚本约定 | [写作与仓库约定](docs/agents/conventions.md) |
| git-kit 完整工作流 | [git-kit 工作流](docs/git-kit.md) |

## 目录速览

- `commands-opencode/` — git 斜杠指令 + `handoff.md` + `cleanup.md`，都是**委托壳**：只加载对应技能并按意图执行，不含逻辑。
- `scripts/` — `skills-fanout.sh`（本源 → 各 agent 软链）、`opencode-install.sh` / `dsh-install.sh`（各工具接入）、`check-opencode-commands.mjs`（命令契约校验）。技能发布用 `skills` CLI（本仓不再提供 `skills-install.sh`）。
- `skills/` — git-kit、handoff、project-insight、project-wiki、tech-design、disk-cleanup，逐个详见 [技能内部规则](docs/agents/skill-internals.md)。配图技能 `diagram-design` 是**外部依赖**（上游 cathrynlavery/diagram-design，本仓不 vendor、不改），按上游方式自装。
- `docs/` — 给人看的解释性文档；`docs/agents/` 是 agent 的按需加载细则。

## 常用命令

```bash
./scripts/skills-fanout.sh --check         # 各 agent 目录的软链是否都指向本源
./scripts/opencode-install.sh --check      # opencode 侧（技能软链 + 命令软链）
./scripts/dsh-install.sh --skills-only     # dsh 只建技能软链（零副作用）
node scripts/check-opencode-commands.mjs   # 命令契约校验
node scripts/check-disk-cleanup-codes.mjs  # disk-cleanup 编码与三处文档是否一致
```

**改了 `skills/` 里的内容**：push 后用 `skills` CLI 发布到本源（`~/.agents/skills/`），否则各 agent 读到的还是旧内容；命令见 [安装与维护](docs/installation.md)「发布」。

参数、退出码与全部门禁清单见 [校验与运行](docs/agents/verification.md)。
