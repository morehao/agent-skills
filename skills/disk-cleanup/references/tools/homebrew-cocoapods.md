# Homebrew / CocoaPods

> 编码：Homebrew 与 CocoaPods 已拆成**两个独立编码** `homebrew`、`cocoapods`，可分别清理。

## 覆盖对象

| 编码 | 清理方式 |
|---|---|
| `homebrew` | `brew cleanup --prune=all` + `brew autoremove`（含旧版本 Cellar） |
| `cocoapods` | 删 CocoaPods 缓存目录 |

## 怎么清

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only homebrew
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only cocoapods
```

## 编码归属

- **现状/终局**：第 2 期从旧聚合编码 `bigbuild` 拆出 `homebrew` 与 `cocoapods` 两个独立编码，可分别勾选清理。

## 注意事项

- Homebrew 清理后**旧版本不能回滚**；`autoremove` 会移除无依赖的包；
- CocoaPods 缓存删除后下次 `pod install` 重新下载。
