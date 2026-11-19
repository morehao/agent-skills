# Changelog

本仓是技能与 opencode 指令的真源，**自 #42（2026-10）起不再发布 npm 包**：dsh 插件与发布工具链已迁到 [morehao/dsh-commands](https://github.com/morehao/dsh-commands)（npm 包 `@morehao/dsh-commands`，其发布记录见该仓 `CHANGELOG.md`）。

本文件只记**本仓**变更，跟随里程碑 tag（`vX.Y.Z`，无 npm 制品）；未打 tag 的改动直接看 `git log`。

## [v0.6.1] - 2026-11-19

### Changed

- **tech-design**: 「配图下限」补回逐节义务的指向说明——SKILL 正文只剩张数下限后，明确「标准档有数据模型章节须给简版 ER 图、跨方交互须给时序图；完整档系统上下文须有图」按 `references/templates.md` 各档骨架与 `references/quality-bar.md` 表一 #13/#14 执行。只加指向不搬条文，避免与 templates/quality-bar 形成重复真源；不改门禁

## [Unreleased]

### Breaking

- **tech-design**: 门禁 `TD-TRACE-CHALLENGE` 为 **error**：标准档及以上的追溯表必须含「挑战点」列，且「挑战点」一节必须用 C1…Cn 编号。**存量标准/完整档文档（含 tech-design-research 的产出）在补列与编号前会失败**。迁移四步：① 在「验收标准」后加「挑战点与取舍」节（1–3 条、编号 C1…Cn）；② 追溯表「决策」后加「挑战点」列；③ 每行填 C 编号或「标准做法」，每个编号至少被一行承接；④ `node skills/tech-design/scripts/check-design-doc.mjs <文档> --tier <档> --strict` 复跑到 0 error / 0 warn。轻量档只需一句话难点，不编号

### Added

- **resume-interview**: 新增技能——面试官视角的简历分析：把简历里的工作技能与项目经验拆成 facts 表，按项目出深挖问题，每题带题源引用、四级「要听的点」（★ 及格线）、口语化示范答案、危险信号与追问时机，最后给维度评分、判定规则与面评草稿。**无源不出题、答案不编事实**（缺口写 `〔待补充：…〕`）；结构门禁 `check-interview-doc.mjs`（30 条规则、52 条断言，`--strict` / `--list-rules`），CI `contract` job 跑回归
- **tech-design-research**: 新增技能——调研驱动的技术设计文档（`tech-design` 的编排增强）。**调研前置**：先读 README 出「业界 vs 本方案」横向表、再 `git clone --depth 1` 读源码取证，横向表作为第一版的输入（不是写完再补）。再补三段：**按终局做取舍**（不可逆结构决定如唯一键 `domain_id` 即使当期不用也定死）；**输出落点与命名规则**（先探测环境、给选项让用户选一次，Obsidian 优先且库内具体路径写进选项；命名 `<主题>-<类型>.md`）；**评审门禁闭环到 0 error/0 warn**（lens 以 tech-design 的 review-gate 为真源）。含 `references/oss-research.md`、`review-loop.md`、`delivery.md`
- **tech-design-research / tech-design**: 明确两者触发边界（窄触发）——本技能是 tech-design 的超集，入口收窄为**仅当用户明确表达调研/参考开源/对标业界/符合主流时才触发**，否则走 tech-design；tech-design 的 description 加反向指路，避免「设计XX系统」这类说法把不需要调研的普通方案误拉进 research
- **tech-design-research**: 新增「开工确认」段——基调（**默认终局**）、档位（**默认完整**）、评审深度、交付动作、取舍拍板权，**每项都给推荐**（首项标「（推荐）」），用选项一次问清、不答按默认值并写进报告。**调研是默认行为**（默认选主流代表），用户点名某开源项目则额外追加调研（不替代默认）。明确**本技能不做 git 操作、不做技能发布**。评审段另加「评审做到哪一档」选项（完整/标准/只跑机械门禁），亦带推荐
- **disk-cleanup**: `browserold` 的扫描面扩到 app bundle 的 `*.framework/Versions`——Chrome/Edge/Brave 升级会把旧框架留在 `/Applications` 里（本机 Chrome 767 MB + Edge 561 MB），原来只扫 `~/Library` 下的两个根，永远看不到；保留 `Current` 指向与运行中版本
- **disk-cleanup**: `updaters` 新增 `Upgrade/` 下的历史更新包（含沙箱 App 的 `Containers/<id>/Data/Library/Application Support/Upgrade/`）——超 1 天未动的子项整删、保留目录本身（本机腾讯视频一个包 696 MB）
- **disk-cleanup**: `varfolders` 新增 `C/clang/ModuleCache`（超 1 天整棵删，编译缓存可再生，本机 165 MB）
- **disk-cleanup**: 预览产出**候选清单**（manifest）——`--clean --dry-run` 时删除漏斗进入 plan 模式（只做路径断言与保护判定，不删、不跑 lsof），把每条候选（编码 / 判定 / 类型 / 路径 / 保护原因 / sudo）写成 TSV；`--json` 新增 `manifest` 块（`path`/`count`/`by_decision`/`by_kind`/`truncated`/`write_failed`），`--manifest <路径>` 可指定落点（默认跟台账同目录，只读沙箱退到 `$TMPDIR`）。清单与真实执行同源，`sample_paths` 退为摘要。代价是预览要完整枚举候选（`caches` 约 2s → 4s，候选上万条的编码可到几十秒）
- **disk-cleanup**: JSON 契约升到 **schema 3**（`DC_SCHEMA_VERSION` 一处定义，主 JSON、`--list --json`、`--history --json` 同步）；`check-disk-cleanup-codes.mjs` 改为从常量读版本，不再硬编码
- **scripts**: 新增差分 oracle（`scripts/dev/mole-oracle.sh` + `mole-oracle.awk`）——把 Mole 的 `clean-list.txt` 与 disk-cleanup 的候选清单按路径 join，产出缺口 / 冲突 / 多出三份待审清单；只读、不调用 `mo`、不进技能包；配套夹具回归 `scripts/dev/tests/mole-oracle-test.sh`（22 条断言，不需要装 Mole）
- **disk-cleanup**: 安全门禁新增第 ⑥ 条——禁止把删除委托给外部清理工具（`mo`/`mole` 的 `clean`/`uninstall`/`purge`/`optimize`），删除只能出自本仓库的漏斗
- **docs**: 新增[决策记录](docs/agents/decisions.md)；首条记录「不把 Mole CLI 接成 disk-cleanup 的运行时依赖」、被判掉的备选与后续改造顺序

### Changed

- **resume-interview**: 首轮真实使用后的门禁加固（依据 4 份独立评审）——① 解析前标记代码围栏，围栏内的 `##` / `### Q` 不再截断段落或冒充题目；② 新增「时间表逐题分钟 vs 题目时长、合计 vs `minutes`」对账（`RI-BUDGET`）；③ ★ 改为按 `meta.level` 校验档位（初级/中级须标 3，高级/架构须标 4，标错或重复报 `RI-STAR`）；④ 锚点必须按行写 `- N：`，单行写「4:3、3:1」不算四档；⑤ 题源接受「」与“”，ASCII 引号判失败；⑥ 覆盖表按表头定位目标列，允许多余列；⑦ H1 从元数据块之后开始找；⑧ 文件读不到时先打印已得结论再 `exit 2`。回归测试 30 → 52 条断言，补上 11 条此前无断言规则的正负例与围栏、顶格锚点、三列覆盖表等合规变体
- **tech-design**: 新增**挑战点**为第一条硬要求与独立工作流步骤（1–3 个 + 四信号：约束冲突 / 数量级跨越 / 所有权不清 / 失败不可逆），由它决定这一版做什么、取证看什么，其余章节标「标准做法」不展开；叙事链 9 问 → 10 问，三档骨架都加「挑战点与取舍」节，档位表加时间盒（30 分钟 / 半天到两天 / 一周以上）与小需求停止规则
- **tech-design**: 追溯表新增**强制列「挑战点」**（C1…Cn）：门禁 `TD-TRACE-CHALLENGE` 拦四类断链——缺列、某行为空或写自由文本（「无/不适用」视为标准做法）、引用了未声明编号、有挑战点没有任何决策承接（孤儿挑战点）。所有追溯表都查（不只第一张），跨表合并承接；全角 `Ｃ１` 经 NFKC 归一；fence 与正文里提到的 `C4` 不算声明。三档骨架、追溯表列、`good-full.md` 示例全部同步
- **tech-design**: 门禁新增 `TD-CHALLENGE`（缺挑战点章节 / 超过 3 条 / 标准档及以上未编号，均可写 `挑战点豁免：<具体理由>` 收口；按 C 编号或顶格条目计数，不再把嵌套子项与「其余按标准做法」清单算成挑战点）；把此前泛化的「显式豁免 + 理由」落地为可机检的 `章节豁免：<理由>`（覆盖 `TD-TIER-STRUCTURE` / `TD-SILENT-LIST` / `TD-KNOWN-GAP`；类目只认括号前的部分，理由需写实，`无/略` 不算）；回归测试 42 → 59 条断言，新增豁免闭环、嵌套计数、多表追溯、编号边界、豁免范围夹具
- **tech-design**: 评审 gate 第 2 段先做挑战点复核（缺失或超 3 个直接记 high finding）；反合理化补 3 条红牌、3 条借口与第 4 条硬闸（动笔前能说出 1–3 个挑战点）；行为 baseline 加 B6「范围压力」场景
- **docs**: 新增三条决策记录（追溯表「挑战点」列为何是 error、门禁规则准入与冻结、方法真源分层）+ `verification.md` 规则准入五条；`tech-design/SKILL.md` 去重至 259 行（配图下限压成摘要、注意事项合并、红牌以 SKILL 为唯一真源），行为不变
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

- **disk-cleanup**: 批量删除失败时**逐条记台账**（`action=failed`，含路径与原因）；以前只汇总一个 `failed` 计数，事后查不到是哪几个路径
- **disk-cleanup**: `/var/folders` 的空目录清理单独计数——「已删 N」只算候选，「清空目录 M」与「跳过 K」分开写，回执终于能和候选清单对上；删不动的是系统进程沙箱目录（owner 是当前用户但被 TCC 护着），记为 `skipped-empty` 而不是失败，避免每次清理都 `exit 1`
### Fixed

- **disk-cleanup**: `/var/folders` 老化清理不再碰 `AppTranslocation`——那是 macOS 给「从下载目录直接运行」的 App 做的隔离副本，里面是**正在运行的 app 本体**（本机 Obsidian 就在里面，`du` 还会报 `Result too large`）。删了会让运行中的 app 当场崩；`dc_delete_aged` 与同口径的 `subset_kb` 都加了 prune，并补了回归断言
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
