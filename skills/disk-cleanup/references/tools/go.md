# Go

> 编码：`go`（全局模块/构建缓存，`--only go`）+ `projectcache`（项目内 `.gocache`）+ `varfolders`（`/var/folders` 的 `T/go-build*`）。

## 覆盖的路径（分属编码）

| 路径 | 所属编码 |
|---|---|
| `~/go/pkg/mod/cache/download` | `go` |
| `~/Library/Caches/go-build` | `go` |
| `~/Library/Caches/goimports` | `go` |
| `~/Library/Caches/gopls` | `go` |
| `~/Library/Caches/golangci-lint` | `go` |
| 项目内 `.gocache` / `.tmp-gocache` / `.dsh/gocache` | `projectcache` |
| `/var/folders/<user>/T/go-build*`（1 天前的顶层目录） | `varfolders` |

## 怎么清

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only go            # 全局模块/构建缓存
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only projectcache  # 项目内 .gocache
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only varfolders    # /var/folders 的 go-build
```

`/var/folders` 的清理细节见 [macos-system.md](../macos-system.md)「`/var/folders` 为什么不能一把梭」；`projectcache` 的扫描根与年龄阈值见 [project-artifacts.md](../project-artifacts.md)。

## 编码归属

- **现状/终局**：全局 Go 缓存已独立为 `go` 编码（第 2 期从旧 `toolcache` 拆出），`--only go` 可单独清。
- 项目内 `.gocache` 仍归 `projectcache`、`/var/folders` 的 go-build 仍归 `varfolders`——这两处按「产物/系统位置」划分，不并入 `go`。

## 注意事项

- `rm_tree` 对 Go 只读模块缓存会先 `chmod -R u+w` 再删；
- 删除后下次构建/`go mod download` 重新拉取。
