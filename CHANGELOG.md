# Changelog

本仓是技能与 opencode 指令的真源，**自 #42（2026-10）起不再发布 npm 包**：dsh 插件与发布工具链已迁到 [morehao/dsh-commands](https://github.com/morehao/dsh-commands)（npm 包 `@morehao/dsh-commands`，其发布记录见该仓 `CHANGELOG.md`）。

本文件只记**本仓**变更，跟随里程碑 tag（`vX.Y.Z`，无 npm 制品）；未打 tag 的改动直接看 `git log`。

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
