# Python（uv / pip）

> 编码：`python`（`--only python`）。uv / pip 缓存归这一个编码，可单独清理。

## 覆盖的路径（归 `python`）

```text
~/.cache/uv
~/Library/Caches/pip
```

## 怎么清

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only python
```

## 编码归属

- **现状/终局**：`python` 是独立编码（第 2 期从旧 `toolcache` 拆出），`--only python` 即只清 Python 缓存。

## 注意事项

- `~/.m2/repository` 属 JVM，见 [jvm.md](jvm.md)；`~/.cargo/registry/cache` 见 [rust.md](rust.md)——各有独立编码，此处仅交叉引用。
- 虚拟环境（`.venv`）不在此编码，其项目内产物归 [project-artifacts.md](../project-artifacts.md)（`projects`）。
- 删除后下次 `uv`/`pip` 安装重新下载。
