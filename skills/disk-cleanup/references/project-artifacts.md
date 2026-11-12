# 项目层产物（projects / dshtmp / projectcache）

> 覆盖编码：`projects`、`dshtmp`、`projectcache`。三者共用扫描根（`--projects-roots`，默认 `~/Documents`，可冒号分隔多个）与排除名单（`--projects-keep`），都是 `-maxdepth` + `-prune`，只处理可再生数据。这三项**跨工具**（Go/pnpm/前端构建产物都会命中），所以不拆进单个工具文档。

## 编码与策略

| 编码 | 覆盖对象 | 策略 / 阈值 | sudo | 删除后代价 |
|---|---|---|---|---|
| `projects` | `--projects-roots`（默认 `~/Documents`）下的 `node_modules`、`dist`、`build`、`.next`、`.turbo`、`.venv`、`target`、`Pods` 等 | 只处理 ≥ `--projects-age-days`（默认 30 天）未改动的目录，<50 MB 不入清单；**树内**（`tree_active`）有近期文件则跳过；`dist`/`build` 里还有 git 跟踪的文件则跳过；嵌套仓库跳过 | 否 | 需重新 install/build |
| `dshtmp` | 项目内 `**/.dsh/tmp` 过程产物（只在 `--projects-roots` 下扫） | 只清空内容、**保留 `.dsh/tmp` 目录本身**；`--dshtmp-age-days`（默认 0 天 = 全部可删）；<10 MB 不入清单；`docs/` 不动 | 否 | 过程产物消失，需要时重新生成 |
| `projectcache` | 项目内编译缓存：`.gocache`、`.tmp-gocache`、`.dsh/gocache`、`.pnpm-store`、`.corepack` | 整目录删；`--projectcache-age-days`（默认 3 天）；<50 MB 不入清单 | 否 | 下次构建/install 重跑 |

## 编码归属：现状 → 终局

- **现状**：按「产物类型」划分（构建产物 / 过程产物 / 编译缓存），而非按工具。这是刻意的——同一项目里 Go/pnpm/前端的产物混在一起，按工具拆反而无法一次清干净。
- **只想清某工具的项目内产物**：目前做不到细分（如只清 Go 的 `.gocache` 不清 `.pnpm-store`），只能整编码勾选。
- **终局（第 2 期不涉及）**：保持按产物类型划分，不按工具拆。

## `projects`：项目层清理的边界

- 只在 `--projects-roots`（默认 `~/Documents`，可用冒号分隔多个）下扫描，**不进 git 仓库外的任意路径**；
- `-maxdepth 6` + `-prune`，命中 `node_modules` 后不再往里钻；
- 按**树内活跃度**判新旧（见下节）：目录自身 mtime 与树内近期文件任一活跃就跳过——只看目录 mtime 会把「长期在改、产物目录一直没重写」的项目误判成可删；
- 删 `dist/`、`build/` 前查 git：仓库里还有被跟踪文件就跳过并注明（避免删掉被提交过的构建目录）；
- 待删目录**自身含 `.git`** → 跳过（嵌套仓库 / submodule / worktree，删了会把别人的仓库连根带走）；
- 用户要保住某个项目：`--projects-keep <绝对路径>`（可重复传）；
- 报告要给「路径 + 大小 + 多少天未改动 + 被哪条守卫跳过」，用户据此勾选；删除后需要重新 install/build，必须写进回执；
- `dist`/`build` 这类名字在非项目目录也可能出现，所以阈值与根目录限制不能放宽成「全盘扫」。

## 三条新守卫（v2）

三个守卫都在「目录 mtime 已经够旧」之后才跑；任何一条命中就跳过该目录，并把 `items[].reason` 记为 `user-kept`（报告里注明是哪一条）。

**一、树内活跃度 `tree_active <目录> <天数>`**：跑 `find <目录> -type f -mmin -<天数×1440> -print -quit`——找到第一个近期文件就退出，代价接近 O(1)。任一近期文件即视为活跃，整个产物目录跳过；探测超时按**活跃**处理（保守方向），不按可删。天数与 `--projects-age-days` 同值；`dshtmp`、`projectcache` 各用各的阈值。

只判目录自身 mtime 的问题：产物目录的 mtime 停在「上次构建」，一个每天都在改源码、但半年没重新构建的项目会被判成可删；反过来刚 `touch` 过目录、里面全是旧文件的项目又会被判成活跃。所以两个条件都要看。

**二、git 追踪保护**：先确认目录在 git 工作树里，再列该目录下的被跟踪文件：

```bash
git -C <待删目录> rev-parse --is-inside-work-tree   # 失败/超时 → 不做这条判断
git -C <待删目录> ls-files                          # 非空 = 目录里有被提交过的文件
```

`ls-files` **非空就跳过**——删掉 `dist/`、`build/` 里被跟踪的文件等于丢工作区内容。`git` 不可用、`rev-parse`/`ls-files` 超时或报错时，按保守方向**跳过**，报告写明「git 探测不可用/超时」。

**三、嵌套仓库跳过**：待删目录自身含 `.git`（仓库根、submodule 的 `.git` 文件、worktree 都算）→ 跳过。删它会连带删掉另一个仓库的工作区，判不准就跳。

三条守卫都只体现为「跳过 + 原因」（`reason=user-kept`、报告里注明），不会让整个编码失败；退出码不受影响。

## `dshtmp` / `projectcache`：项目内的过程产物与编译缓存

两者与 `projects` 共用扫描根（`--projects-roots`，默认 `~/Documents`，可冒号分隔多个）与排除名单（`--projects-keep`），
都是 `-maxdepth 7` + `-prune`，都只处理可再生数据：

- **`dshtmp`**：只命中 `*/.dsh/tmp`，**只清空内容、保留 `.dsh/tmp` 目录本身**；同级的 `~/Documents/**/.dsh/docs`
  是用户文档，**不动**。删除前先 `chmod -R u+w`（Go 模块缓存等只读条目），删后回读确认目录仍在且为空。
  `<10 MB` 不进清单；`--dshtmp-age-days`（默认 0 天）为 0 表示全部可删，`N>0` 时只删 ≥ N 天未改动的，其余标「N 天内有改动，跳过」。
- **`projectcache`**：命中 `.gocache`、`.tmp-gocache`、`.dsh/gocache`、`.pnpm-store`、`.corepack`，整目录删
  （`node_modules/.pnpm-store` 也会被 `-name .pnpm-store` 命中，属预期）。`<50 MB` 不进清单；
  `--projectcache-age-days`（默认 3 天）才判定年龄，删除同样先 `chmod -R u+w`。
- 删除代价：过程产物消失后需要时重新生成；编译缓存没了下次构建/install 重跑，可再重建，不影响源码。

## 注意事项

- 不在 `--projects-roots` 下的项目不会被扫到；全盘扫 `node_modules`、`.dsh/tmp` 既慢又容易误伤，刻意不做。
- `dshtmp` 只清 `*/.dsh/tmp` 内容，`.dsh/docs` 等用户文档目录不动；`projectcache` 只认上述几个名字，其它编译缓存（`node_modules/.cache`、`target` 等）归 `projects` 或不在覆盖范围。
- 工具视角：Go 的 `.gocache`/`.pnpm-store` 见 [tools/go.md](tools/go.md)、[tools/node.md](tools/node.md)。
