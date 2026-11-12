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

## 想回收卷（交用户，按项目更可控）

卷里可能有用户数据，本技能不代删。用户想回收时，按项目边界回收比全局扫更安全：

- **优先** `docker compose down -v`：只删当前 compose 项目声明创建的卷，范围被项目锁死；或 `docker volume rm <卷名>` 逐卷点名。
- **不要** `docker volume prune -a`：全局扫「无容器引用」的卷，别的项目临时停着容器时其卷会变成「无引用」而被误清。
- 注意：`compose down -v` 只对 compose 起的项目有效；手工 `docker run -v` 起的容器、命名卷/绑定挂载混用的情况它不管，需要用户自行判断。

复核用**只读**命令：`docker system df -v`（各镜像/容器/卷/构建缓存明细）或 `docker system df`（汇总）——它们只做统计、不回收空间。回收仍在虚拟磁盘内部，宿主 `df` 未必变小（见上「期望管理」）。
