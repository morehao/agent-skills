# JVM（Maven / Gradle）

> 编码：`~/.m2/repository` 归 `toolcache`；`~/.gradle/caches` 归 `bigbuild`。**同属 JVM 却跨两个编码**，脚本层没有 `--only jvm`。

## 覆盖的路径（分属编码）

| 路径 | 所属编码 |
|---|---|
| `~/.m2/repository` | `toolcache` |
| `~/.gradle/caches` | `bigbuild` |

## 怎么清

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only toolcache   # .m2/repository
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only bigbuild    # .gradle/caches（与 brew/pod/iOS 同编码）
```

## 编码归属：现状 → 终局

- **现状**：Maven 仓库在 `toolcache`，Gradle 缓存在 `bigbuild`；`bigbuild` 里还挤着 Homebrew / CocoaPods / iOS DeviceSupport / 模拟器，粒度极粗。
- **只想清本工具**：无法只清 `.gradle/caches`——要么整组 `bigbuild`（会连带清 brew/pod/iOS），要么交用户终端跑单条。
- **终局（第 2 期）**：拆出 `jvm`（或 `maven` / `gradle`）编码，把散落两处的 JVM 缓存收拢。

## 注意事项

- `bigbuild` 删除后 Homebrew 旧版本不能回滚，需重新下载/构建。
