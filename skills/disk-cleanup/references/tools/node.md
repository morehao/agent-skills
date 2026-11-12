# Node 生态（npm / yarn / bun / pnpm）

> 编码：`node`（`--only node`）。npm/yarn/bun/pnpm 及无头运行时缓存都归这一个编码，可单独清理。

## 覆盖的缓存/产物路径（归 `node`）

```text
~/.npm/_npx
~/.npm/_cacache
~/.npm/_logs
~/.cache/yarn
~/.cache/bun
~/.bun/install/cache
~/.cache/node
~/.cache/puppeteer
~/.cache/codex-runtimes
~/.cache/opencode
~/Library/Caches/Yarn
~/Library/Caches/node-gyp
~/Library/Caches/electron
~/Library/Caches/ms-playwright
~/Library/Caches/Cypress
~/Library/pnpm/package-manager-store   （pnpm 工具版本仓库，store prune 不管它）
~/Library/pnpm/store                   （pnpm 包内容，store prune 回收未引用）
```

- `node` 删除时对只读缓存先 `chmod -R u+w`；
- `ms-playwright`、`Cypress`、`electron`、`puppeteer`、`codex-runtimes` 是无头运行时/浏览器缓存，归本编码一并清理。

## 怎么清

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only node
# pnpm store：只回收未被引用的包（不删实体目录）
corepack pnpm store prune   # 无 corepack 时回落：pnpm store prune
```

`node` 里 pnpm 走 corepack shim：裸 `pnpm` 在部分环境里可能触发「Corepack is about to download…」交互弹窗。脚本在 `corepack` 存在时用
`COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack pnpm store prune` 复用已有版本；`corepack` 缺失时回落到裸 `pnpm store prune`。`--clean --only node` 时自动带上这一步。

pnpm 有**两套存储**：`~/Library/pnpm/store`（包内容，`store prune` 回收未引用）与
`~/Library/pnpm/package-manager-store`（pnpm 自己的工具版本，实测可到 GB 级，`store prune` 不管，由 `node` 整目录删除）。

## 编码归属

- **现状/终局**：`node` 是独立编码（第 2 期从旧 `toolcache` 拆出），`--only node` 即只清 Node 生态缓存。
- npm / yarn / bun / pnpm 合并为一个 `node` 编码（同一生态，用户常一起清）；不细分成 `npm`/`pnpm`。

## 注意事项

- 删除后需重新下载/编译；`node_modules` 项目内产物不在此编码，归 [project-artifacts.md](../project-artifacts.md)。
- 新增 Node 缓存目录必须改脚本的 `NODE_CACHE_DIRS`，别在任务里自行 `rm -rf` 白名单外路径。
