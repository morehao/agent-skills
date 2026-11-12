# Rust（cargo）

> 编码：`toolcache`（`--only toolcache`）。cargo 的 registry 缓存在 `toolcache` 白名单里。

## 覆盖的路径（归 `toolcache`）

```text
~/.cargo/registry/cache
```

## 怎么清

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only toolcache
```

## 编码归属：现状 → 终局

- **现状**：cargo 缓存与其它语言共享 `toolcache`，无单独开关。
- **只想清本工具**：`toolcache` 整组不勾，交用户终端跑单条命令。
- **终局（第 2 期）**：拆出 `rust` 编码。

## 注意事项

- cargo 编译产物（`target/`）不在此编码，属项目内构建产物，归 [project-artifacts.md](../project-artifacts.md)（`projects` 命中 `target`）。
- 删除后下次 `cargo build` 重新下载 crate。
