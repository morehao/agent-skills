# Xcode / iOS 开发

> 编码：`xcode`（DerivedData）+ `xcode-ios`（iOS DeviceSupport / CoreSimulator / 不可用模拟器 / ipsw）。两者独立，可分别清理。

## 覆盖的路径（分属编码）

| 路径 | 所属编码 | 策略 |
|---|---|---|
| `~/Library/Developer/Xcode/DerivedData` | `xcode` | 整个删掉 |
| `~/Library/Developer/Xcode/iOS DeviceSupport` | `xcode-ios` | 删目录（旧版本符号文件） |
| `~/Library/Developer/CoreSimulator/Caches` | `xcode-ios` | 删目录 |
| 不可用的旧 iOS 模拟器 | `xcode-ios` | `xcrun simctl delete unavailable` |
| 旧 iOS 固件（ipsw） | `xcode-ios` | 删目录 |

## 怎么清

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only xcode      # 只清 DerivedData
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only xcode-ios  # iOS DeviceSupport / 模拟器 / ipsw
```

## 编码归属

- **现状/终局**：第 2 期把 iOS 大件从旧 `bigbuild` 拆出独立成 `xcode-ios` 编码；`xcode`（DerivedData）保持独立。二者可分别勾选，不再与 brew/pod 捆绑。

## 注意事项

- DerivedData 删除后下次构建**全量重编**，耗时明显；
- DeviceSupport 删除后接设备调试时重新生成；
- 模拟器为 `xcrun simctl delete unavailable`，只删系统判定不可用的。
