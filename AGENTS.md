# AGENTS.md

本仓库集中管理个人 AI 编码工具扩展：`commands-opencode/`（opencode 斜杠指令）+ `skills/`（技能，opencode / dsh 共用）。dsh 的斜杠命令插件在独立仓 [morehao/dsh-commands](https://github.com/morehao/dsh-commands)（npm 安装；本仓只提供它依赖的技能）。所有说明用**简体中文**。

## 硬约束（改动前先过一遍）

1. **两层：本仓是编辑源，`~/.agents/skills` 是运行时本源**。技能内容改动**不自动生效**：先 push，再由维护者**手动**把 `skills/<name>/` 同步到本源 `~/.agents/skills/<name>/`；各 agent 目录只放指向本源（`AGENTS_SKILLS_DIR` 可覆盖）的软链，由 `./scripts/skills-fanout.sh` 维护。opencode 的**命令**没法搬，仍从本仓软链到其配置目录——命令改本仓即时生效，技能不然。不要编辑软链副本。接入语义见 [接入与生效语义](docs/agents/deployment.md)。
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
| 软链 / profile / 热加载 / 工具链归属 | [接入与生效语义](docs/agents/deployment.md) |
| 发版纪律与 `/git/release` 边界 | [发版纪律](docs/agents/release-discipline.md) |
| 跑校验、门禁与退出码 | [校验与运行](docs/agents/verification.md) |
| 写作、命名、Git、脚本约定 | [写作与仓库约定](docs/agents/conventions.md) |
| git-kit 完整工作流 | [git-kit 工作流](docs/git-kit.md) |

## 目录速览

- `commands-opencode/` — git 斜杠指令 + `handoff.md` + `cleanup.md`，都是**委托壳**：只加载对应技能并按意图执行，不含逻辑。
- `scripts/` — `skills-install.sh`（发布到本源 `~/.agents/skills`）、`skills-fanout.sh`（本源 → 各 agent 软链）、`opencode-install.sh` / `dsh-install.sh`（各工具接入）、`check-opencode-commands.mjs`（命令契约校验）。
- `skills/` — git-kit、handoff、project-insight、project-wiki、tech-design、svg-maker、disk-cleanup，逐个详见 [技能内部规则](docs/agents/skill-internals.md)。
- `docs/` — 给人看的解释性文档；`docs/agents/` 是 agent 的按需加载细则。

## 常用命令

```bash
./scripts/skills-install.sh --check        # 本源（~/.agents/skills）与本仓是否一致
./scripts/skills-fanout.sh --check         # 各 agent 目录的软链是否都指向本源
./scripts/opencode-install.sh --check      # opencode 侧（技能软链 + 命令软链）
./scripts/dsh-install.sh --skills-only     # dsh 只建技能软链（零副作用）
node scripts/check-opencode-commands.mjs   # 命令契约校验
node scripts/check-disk-cleanup-codes.mjs  # disk-cleanup 编码与三处文档是否一致
```

**改了 `skills/` 里的内容**：push 后由维护者手动同步本源（`~/.agents/skills/`），否则各 agent 读到的还是旧内容。**不要替用户执行发布**：`scripts/skills-install.sh` 仍保留，但发布动作由人决定、由人操作。

参数、退出码与全部门禁清单见 [校验与运行](docs/agents/verification.md)。
