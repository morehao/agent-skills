# Homebrew / CocoaPods

> 编码：`bigbuild`（`--only bigbuild`）。Homebrew 与 CocoaPods 的缓存都**共用 `bigbuild` 这一个编码**。

## 覆盖的路径（归 `bigbuild`）

| 工具 | 清理方式 |
|---|---|
| Homebrew | `brew cleanup --prune=all` + `brew autoremove`（含旧版本 Cellar） |
| CocoaPods | 删 CocoaPods 缓存目录 |

`~/Library/Caches/Homebrew` 也在 `toolcache` 白名单里（与 `bigbuild` 的 brew cleanup 从不同角度处理缓存），两者并存不冲突。

## 怎么清

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only bigbuild
```

`bigbuild` 会一并处理 brew + pod + Gradle + iOS DeviceSupport + 模拟器 + ipsw——**无法只清 brew 或只清 pod**。

## 编码归属：现状 → 终局

- **现状**：Homebrew / CocoaPods / Gradle / iOS 大件全部共用一个 `bigbuild` 编码。
- **只想清本工具**：`bigbuild` 整组不勾，交用户终端跑 `brew cleanup --prune=all && brew autoremove` 等单条命令；不要在任务里临时 `rm -rf`。
- **终局（第 2 期）**：拆出 `homebrew` / `cocoapods` 编码。

## 注意事项

- Homebrew 清理后**旧版本不能回滚**；`autoremove` 会移除无依赖的包；
- CocoaPods 缓存删除后下次 `pod install` 重新下载。
