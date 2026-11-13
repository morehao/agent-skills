# 决策记录

长期生效的技术取舍，逐条追加。每条写清：结论、背景、被判掉的备选、按 [AGENTS.md](../../AGENTS.md)「五条判据」的理由、留下来的终局改造清单，以及重新评估的触发条件。

作用：防止同一个问题被反复讨论。动到相关代码前先读这里；要推翻一条，先写清新证据。

## 2026-11-13 · 不把 Mole CLI 接成 disk-cleanup 的运行时依赖

**结论**：`disk-cleanup` 不调用 `mole` / `mo` 的任何子命令，也不内联其代码或清单。Mole 只在**研发期当差分 oracle**（拿它的 dry-run 候选路径当对照组，找我们自己的覆盖缺口）。两者是同一台机器上两个受众的工具：Mole 服务终端里的人，本技能服务 agent。

**背景**：本机装了 Mole 1.71.0（Homebrew），源码在本地。它 `clean` 的 14 个分区覆盖了本技能 29 个编码里的大部分，并有 Go 写的分析器（同一棵 36 GB 的树 **7.1s**，`du` 同目录 **16.1s**）与四个文档化的 JSON 读接口：`analyze --json`、`status --json`、`history --json`、`uninstall --list`。看起来「有东西可以复用」。

**被判掉的备选**：

| 备选 | 不过的判据 | 具体原因 |
|---|---|---|
| 用 `mo analyze --json` 加速 `--top` | 依赖、分发 | JSON 面**没有版本号**（无 schema 字段）；`--select/--categories/--exclude` 已在 1.71 被删除、传入即 `exit 1`，说明契约会破坏性变更；沙箱行为与本技能**相反**——`mo clean --dry-run` 必须写 `~/.config/mole/clean-list.txt`，在 `workspace-write` 里直接 `exit 1`，而本技能的 dry-run 同环境正常出 JSON（当时 2.3s，现随候选清单枚举升到 4s 量级）。为 2.3× 的读性能，把「沙箱内可预览」这个优势换掉，不划算 |
| 把删除委托给 `mo clean` / `mo uninstall` / `mo purge --yes` | 归属、可观测 | 无子集选择（只能整机清或先改白名单）、无 JSON、无退出码语义；会绕过唯一删除漏斗、保护清单、`lsof` 在用检测与自家台账，审计分裂成两本，而 mole 的日志还会被它自己 `history_reset_*` 清掉 |
| vendor 或 fork Mole | 许可证、依赖 | GPL-3.0 对 MIT 本仓；58k 行 bash + 一个 Go 分析器，等于接手一个我们修不动也不该修的上游 |
| 抄它的应用保护清单与 app 级缓存知识 | 许可证 | 同上。且本技能的判据是「删了会破坏系统功能，或删的是用户数据」，不是「Mole 这么说」——照抄会把别人的产品判断变成我们的安全底线 |

**留下来的收益（也是本技能目前真正的短板）**：Mole 比我们强的地方不是速度，是**完整候选路径清单**——`mo clean --dry-run` 把每个候选路径写进 `clean-list.txt`，人可以逐条核对。而本技能 `--json` 的 `items[].sample_paths` 各 target 一律 `head -5`，dry-run 阶段看不到「到底会删哪些路径」。这件事自己补，不靠 Mole。

**终局改造清单**（按顺序做，允许破坏 schema 兼容）：

1. **候选清单成为一等输出**：除汇总 JSON 外提供完整候选清单（路径 + 编码 + 判定 + 原因 + 是否受保护），dry-run 就能逐条核对。这也是和任何外部工具做对照的前提。现有 `sample_paths` 保留，作为摘要不被误当全集。**（2026-11-13 已落地：schema 3 + `manifest` 块 + `--manifest <路径>` + 漏斗 plan 模式；契约见 `references/cleanup.md`，门禁见 `check-disk-cleanup-safety.mjs` 第 ⑥ 条。）**
2. **差分 oracle**：研发期脚本按路径 join「Mole 的候选清单」与「我们的候选清单」，产出三份待审清单——缺口（Mole 会清、我们完全不碰）、冲突（我们标 protected、Mole 会清）、多出（我们计划删、Mole 不碰）。只在维护者机器上跑，**不进技能分发包、不作为安装依赖**。**（2026-11-13 已落地：`scripts/dev/mole-oracle.sh` + `mole-oracle.awk` + 夹具回归 `scripts/dev/tests/mole-oracle-test.sh`；前置是用户在自己终端跑 `mo clean --dry-run`，因为 Mole 必须写 `~/.config/mole`。）**
3. **漏斗补强**：把 Mole 已验的三类「在用」判定内建进来——活用户缓存、SQLite 库被占用、编译模型缓存。判据由我们自己的测试锁住，不引用其实现。
4. **边界写死**：`SKILL.md` 与[技能说明](../skills.md) 标明两个工具的受众，以及**台账与白名单互不相认**，避免同一台机器上被当成一套。

**首轮差分结论（2026-11-13，本机）**：Mole 739 条 / 6.9 GB 候选，去掉沙箱看不见的 TCC 目录后真实可审约 249 条 / 2.07 GB，**冲突 0 条**。落到三处真缺口并已补：app bundle 里的旧浏览器框架（A，1.3 GB）、`Upgrade/` 下的历史更新包（B，696 MB）、`C/clang/ModuleCache`（C，165 MB）；其余是阈值差（我们按 mtime 老化、Mole 整目录删），不是盲区。沙箱外仍看不到 `~/.Trash` 与 `~/Library/Mail`（TCC），两端同样看不到，所以不产生假缺口。

**重新评估的触发条件**（满足才重开讨论）：

- Mole 给出**带版本号**、只测量/只判定的库级接口（不是 CLI 文本），且许可证与本仓兼容；
- 或本技能的候选清单需要跨机器长期比对，而 Mole 的 JSON 已成为事实标准。

**写路径永不外接**：无论上游怎么变，删除只走 `lib/safety.sh` 的 `dc_funnel_rm` / `dc_batch_flush` 一个漏斗。安全模型不可分割，这条不受「终局优先」例外——它是终局本身。
