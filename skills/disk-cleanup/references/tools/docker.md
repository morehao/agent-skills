# Docker

> 编码：`docker`（`--only docker`）。Docker 与其它清理对象解耦，1:1 独立编码。

## 覆盖对象

未使用的镜像、停止的容器、构建缓存、未被使用的网络：

```bash
docker system prune -a --force
```

| 项 | 值 |
|---|---|
| 编码 | `docker` |
| sudo | 否 |
| 删除后代价 | 镜像要重新 `pull`；**Docker.raw 不缩小** |

## 编码归属：现状 → 终局

- **现状**：`docker` 已是独立编码，`--only docker` 就是「只清 Docker」，粒度和读者认知已对齐。
- **终局（第 2 期不涉及）**：无需拆分。

## 注意事项（期望管理）

`docker system prune -a` 回收的是虚拟磁盘**内部**的空间；Docker Desktop / OrbStack 的稀疏镜像（`Docker.raw` 等）不会因此变小，宿主 `df` 很可能纹丝不动。回执必须说清：

- 容器内空间已回收，但宿主可用空间不变属正常；
- 想真正还盘：OrbStack 用其 `orb` 的清理入口，Docker Desktop 需手动压缩/重置虚拟磁盘；
- 另外：`docker system prune` 默认**不删卷**（`--volumes` 才删，可能有用户数据），本技能刻意不开这个开关。
