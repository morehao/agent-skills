# Changelog

本仓是技能与 opencode 指令的真源，**自 #42（2026-10）起不再发布 npm 包**：dsh 插件与发布工具链已迁到 [morehao/dsh-commands](https://github.com/morehao/dsh-commands)（npm 包 `@morehao/dsh-commands`，其发布记录见该仓 `CHANGELOG.md`）。

本文件只记**本仓**变更，跟随里程碑 tag（`vX.Y.Z`，无 npm 制品）；未打 tag 的改动直接看 `git log`。

## [Unreleased]

### Added

- **disk-cleanup**: 预览产出**候选清单**（manifest）——`--clean --dry-run` 时删除漏斗进入 plan 模式（只做路径断言与保护判定，不删、不跑 lsof），把每条候选（编码 / 判定 / 类型 / 路径 / 保护原因 / sudo）写成 TSV；`--json` 新增 `manifest` 块（`path`/`count`/`by_decision`/`by_kind`/`truncated`/`write_failed`），`--manifest <路径>` 可指定落点（默认跟台账同目录，只读沙箱退到 `$TMPDIR`）。清单与真实执行同源，`sample_paths` 退为摘要。代价是预览要完整枚举候选（`caches` 约 2s → 4s，候选上万条的编码可到几十秒）
- **disk-cleanup**: JSON 契约升到 **schema 3**（`DC_SCHEMA_VERSION` 一处定义，主 JSON、`--list --json`、`--history --json` 同步）；`check-disk-cleanup-codes.mjs` 改为从常量读版本，不再硬编码
- **disk-cleanup**: 安全门禁新增第 ⑥ 条——禁止把删除委托给外部清理工具（`mo`/`mole` 的 `clean`/`uninstall`/`purge`/`optimize`），删除只能出自本仓库的漏斗
- **docs**: 新增[决策记录](docs/agents/decisions.md)；首条记录「不把 Mole CLI 接成 disk-cleanup 的运行时依赖」、被判掉的备选与后续改造顺序

### Changed

- **docs**: `AGENTS.md` 新增「按终局设计，不做最小改动」的决策原则（归属 / 许可证 / 依赖 / 分发 / 可观测 五条判据），要求破坏性变更配迁移路径、会被反复讨论的理由落进 `docs/`
- **scripts/docs**: 移除 `scripts/skills-install.sh`，技能发布不再由本仓脚本代跑；文档与安装脚本提示统一改为直接给 `skills` CLI 命令（`npx -y skills add ...`），agent 只告知用户可用 `skills` CLI 自行维护本地技能
- **docs**: 移除「技能改动必须由维护者手动同步、agent 不得发布」的约定；保留「编辑源 → 本源 → 软链」的两层链路与 `skills-install.sh`，发布动作不再由仓库约定限制
- **tech-design**: 配图从「有就好」升级为**配图下限**——轻量档有结构类章节即须有图、标准 ≥2、完整 ≥3；工作流改为「先填视图清单、先出骨架图再写正文」，交付报告带图清单
- **tech-design**: 门禁 `TD-NO-DIAGRAM` 改为**按章节**检查（一张图不再放行全篇），新增 `TD-DIAGRAM-MIN`（档位最小图集）；轻量档不再跳过；`图豁免：<理由>` 可显式收口
- **tech-design**: 评审 gate 新增「图与论证」lens；`good-full.md` 补齐 Mermaid 上下文/ER 与同目录 `architecture.svg` 范例
- **tech-design**: 评审 gate 的必跑条件写进自检与红牌：标准档在跨团队 / SLA / 动契约或表结构时必跑，无 subagent 就顺序执行，**缺 `VERDICT` 即未完成**
- **project-insight**: 代码引用从"每个论断强制"改为**按需证据**——正文以叙述为主，只有反直觉结论 / 数字 / 安全边界 / 用户指定核验才给一处出处，整篇零引用合法；新增「四给四不给」判据，不设引用配额
- **project-insight**: `verify-references.mjs` 支持零引用文档直接通过（打印「无引用（允许）」），新增 `--stats` 密度自查（只报告不阻断）；新增 `tests/references-smoke.sh` 回归
- **project-insight**: 同步 SKILL.md、11 个 references / 8 个类型规格与仓库文档（`docs/skills.md`、`docs/agents/*`），清除 #57 回退遗留的 `check-doc.mjs`、决策卡等失效描述

### Fixed

- **disk-cleanup**: 删除改为**批量出口**——`dc_batch_add` 逐条过同一套闸（断言 / 保护清单 / 在用）后攒批，`dc_batch_flush` 每满 `DC_RM_BATCH_MAX`（默认 256）一次 `rm -rf -- p1 p2 …`；清 `~/Library/Caches` 这类几千个路径的场景不再按路径各起 3~4 个进程，避免顶满 macOS 默认 `kern.maxprocperuid=4000` 后 `fork: Resource temporarily unavailable`、脚本半路 `exit 128`
- **disk-cleanup**: 超时看门狗从「`sleep <secs>` 一觉睡到底」改为轮询 + 退避（1/2/4/…/30s），被监控进程一结束就退出，不再每次调用遗留一个孤儿 `sleep` 进程
- **disk-cleanup**: `check-disk-cleanup-safety.mjs` 的「单漏斗」规则同步放行 `dc_batch_flush`（仍然只允许 `lib/safety.sh` 内的这两个函数出现 `rm`），新增批量删除回归用例（40 条路径只触发 1 次 `rm`）

## [v0.2.0] - 2026-10-23

### Features

- **git-kit**: 发布说明加中文摘要层，tag 注记与 Release body 共用同一份变更说明（#46）
- **disk-cleanup**: 新增磁盘清理技能：先测量 → 用户勾选 → 只清所选，用户数据只报告不代删（#45）
- **opencode**: 新增接入脚本与命令契约校验，重组文档（#44）
- **git-kit**: 版本源改为读仓库判定，发布后效按仓库探测（#43）
- **git-kit**: 新增发布后校验 `release-verify`（#41）

### Chores

- 移除 npm 发布链与 dsh 插件（迁至 morehao/dsh-commands）（#42）

## [v0.1.7] - 2026-10-22

### Features

- **git-kit**: release 流程默认创建 GitHub/GitLab Release（#39）

### Fixes

- **release**: npm 发布遇 registry 抖动时重试，并保留 tag 注记标题（#38）

### Chores

- **commands-dsh**: 版本升至 0.1.7（#40）

## [v0.1.6] - 2026-10-22

> npm 发布时代（`ai-kit` 仓）由发布工具自动生成的记录，保留原文，链接未改（GitHub 会重定向）。

### Features

- **git-kit**: ask with options at every release decision point (#35)
- **git-kit**: add release branch for post-merge tag and publish verification (#34)

**Full Changelog**: https://github.com/morehao/ai-kit/compare/v0.1.5...v0.1.6
