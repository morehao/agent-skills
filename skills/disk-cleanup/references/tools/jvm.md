# JVM（Maven / Gradle）

> 编码：`jvm`（`--only jvm`）。Maven `.m2` 与 Gradle `.gradle/caches` 合并为这一个编码，可单独清理。

## 覆盖的路径（归 `jvm`）

| 路径 | 说明 |
|---|---|
| `~/.m2/repository` | Maven 本地仓库（第 9 节清理） |
| `~/.gradle/caches` | Gradle 缓存（第 8 节清理） |

两处都在 `jvm` 编码下，`--only jvm` 会同时清理；`--list`/`--json` 里它们各出现一条，按编码聚合用 `codes[]`。

## 怎么清

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only jvm
```

## 编码归属

- **现状/终局**：第 2 期把原本散在 `toolcache`（`.m2`）和 `bigbuild`（`.gradle`）的 JVM 缓存**合并成 `jvm` 一个编码**，消灭了「同属 JVM 却跨两个编码」的落差。

## 注意事项

- 删除后 Maven/Gradle 下次构建重新下载依赖；
- `~/.gradle/caches` 由第 8 节的 gradle 步骤删除、`~/.m2/repository` 由第 9 节删除，二者同归 `jvm` 编码，不会重复删同一路径。
