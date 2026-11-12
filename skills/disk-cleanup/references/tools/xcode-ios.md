# Xcode / iOS 开发

> 编码：`xcode`（DerivedData）+ `bigbuild`（iOS DeviceSupport / CoreSimulator / 不可用模拟器 / ipsw）。**Xcode 相关跨两个编码**，脚本层没有 `--only xcode` 覆盖全部。

## 覆盖的路径（分属编码）

| 路径 | 所属编码 | 策略 |
|---|---|---|
| `~/Library/Developer/Xcode/DerivedData` | `xcode` | 整个删掉 |
| `~/Library/Developer/Xcode/iOS DeviceSupport` | `bigbuild` | 删目录（旧版本符号文件） |
| `~/Library/Developer/CoreSimulator/Caches` | `bigbuild` | 删目录 |
| 不可用的旧 iOS 模拟器 | `bigbuild` | `xcrun simctl delete unavailable` |
| 旧 iOS 固件（ipsw） | `bigbuild` | 删目录 |

## 怎么清

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only xcode    # 只清 DerivedData
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only bigbuild # iOS DeviceSupport / 模拟器 / ipsw（与 brew/pod/gradle 同编码）
```

## 编码归属：现状 → 终局

- **现状**：DerivedData 在 `xcode`，其余 iOS 大件在 `bigbuild`，且 `bigbuild` 还挤着 Homebrew / CocoaPods / Gradle。
- **只想清本工具**：`--only xcode` 只清 DerivedData；清 iOS 大件必须整组 `bigbuild`（连带 brew/pod/gradle），或在终端跑单条 `xcrun simctl delete unavailable` / `rm -rf`。
- **终局（第 2 期）**：把 iOS 相关从 `bigbuild` 拆出，归入更细的 `xcode-ios` 编码，与 `xcode`（DerivedData）合并视角。

## 注意事项

- DerivedData 删除后下次构建**全量重编**，耗时明显；
- DeviceSupport 删除后接设备调试时重新生成；
- 模拟器为 `xcrun simctl delete unavailable`，只删系统判定不可用的。
