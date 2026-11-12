# Python（uv / pip）与其它语言缓存

> 编码：`toolcache`（`--only toolcache`）。uv / pip 缓存都在 `toolcache` 白名单里。

## 覆盖的路径（归 `toolcache`）

```text
~/.cache/uv
~/Library/Caches/pip
```

## 怎么清

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only toolcache
```

## 编码归属：现状 → 终局

- **现状**：uv / pip 及几乎所有语言缓存共用 `toolcache`，无单语言开关。
- **只想清本工具**：`toolcache` 整组不勾，交用户终端跑单条命令；不要在任务里临时 `rm -rf`。
- **终局（第 2 期）**：拆出 `python` 编码。

## 注意事项

- `~/.m2/repository` 属 Maven/JVM，见 [jvm.md](jvm.md)；`~/.cargo/registry/cache` 见 [rust.md](rust.md)——它们都在 `toolcache`，此处仅交叉引用，不重复列。
- 虚拟环境（`.venv`）不在此编码，其项目内产物归 [project-artifacts.md](../project-artifacts.md)（`projects`）。
