# Node 生态（npm / yarn / bun / pnpm）

> 编码：`toolcache`（`--only toolcache`）。npm/yarn/bun/pnpm 的缓存都**共用 `toolcache` 这一个编码**，脚本层没有单工具开关。

## 覆盖的缓存/产物路径（归 `toolcache`）

```text
~/.npm/_npx
~/.npm/_cacache
~/.npm/_logs
~/.cache/yarn
~/.cache/bun
~/.cache/node
~/.bun/install/cache
~/Library/Caches/Yarn
~/Library/Caches/node-gyp
~/Library/Caches/electron
~/Library/pnpm/package-manager-store   （pnpm 工具版本仓库，store prune 不管它）
~/Library/pnpm/store                   （pnpm 包内容，store prune 回收未引用）
```

- `toolcache` 删除时对只读缓存先 `chmod -R u+w`；
- `~/Library/Caches/ms-playwright`、`Cypress`、`electron`、`puppeteer`、`codex-runtimes` 等**无头运行时/浏览器**缓存也在 `toolcache` 白名单里，但不专属某门语言——见 [macos-system.md](../macos-system.md)「其他可再生缓存」。

## 怎么清

```bash
# pnpm store：只回收未被引用的包（不删实体目录）
corepack pnpm store prune
# 无 corepack 时回落：
pnpm store prune
```

`toolcache` 里 pnpm 走 corepack shim：裸 `pnpm` 在部分环境里可能触发「Corepack is about to download…」交互弹窗。脚本在 `corepack` 存在时用
`COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack pnpm store prune` 复用已有版本；`corepack` 缺失时回落到裸 `pnpm store prune`（并说明走了回落）。只有 `pnpm` 存在时才执行这一步。

pnpm 有**两套存储**：`~/Library/pnpm/store`（包内容，`store prune` 回收未引用）与
`~/Library/pnpm/package-manager-store`（pnpm 自己的工具版本，实测可到 GB 级，`store prune` 不管）。
后者由 `toolcache` 整目录删除，删后按需重新下载。

## 编码归属：现状 → 终局

- **现状**：npm / yarn / bun / pnpm 全部落在 `toolcache`，用户说「只清 npm」时脚本无对应开关；要么整组 `toolcache` 一起清，要么不清。
- **只想清本工具**：`toolcache` 整组不勾，改由用户在终端跑单条 `rm -rf` / `pnpm store prune`；**不要**在任务里临时 `rm -rf` 无人了解的路径。
- **终局（第 2 期）**：从 `toolcache` 拆出 `node`（或 `npm` / `pnpm` 细分）编码，实现按工具粒度清理。

## 注意事项

- 删除后需重新下载/编译；`node_modules` 项目内产物不在此编码，归 [project-artifacts.md](../project-artifacts.md)。
- 新增 Node 缓存目录必须改脚本的 `SAFE_CACHE_DIRS`（`package-manager-store` 由 `PNPM_PMS` 单独处理），别在任务里自行 `rm -rf` 白名单外路径。
