# Rust（cargo）

> 编码：`rust`（`--only rust`）。cargo registry 缓存归这一个编码，可单独清理。

## 覆盖的路径（归 `rust`）

```text
~/.cargo/registry/cache
```

## 怎么清

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only rust
```

## 编码归属

- **现状/终局**：`rust` 是独立编码（第 2 期从旧 `toolcache` 拆出），`--only rust` 即只清 cargo registry 缓存。

## 注意事项

- cargo 编译产物（`target/`）不在此编码，属项目内构建产物，归 [project-artifacts.md](../project-artifacts.md)（`projects` 命中 `target`）。
- 删除后下次 `cargo build` 重新下载 crate。
