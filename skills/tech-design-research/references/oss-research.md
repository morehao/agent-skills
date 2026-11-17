# 开源对标取证（oss-research）

本技能的核心工序，**在写第一版之前做**：先把业界成熟实现摸清，横向表作为第一版的输入，而不是写完再回头补。目标不是「列一堆开源项目」，而是**用业界成熟实现校准本方案的设计**。分两级，能到第二级就到第二级。

## 一、怎么做

### 1. 选题：找同类、热门、看得到源码的

- 用 `web_search` 找「<系统类型> open source github」、awesome 列表、Hacker News 讨论；优先 **star 高 + 有真实文档 + 近期活跃**。
- 每个系统类型通常有「分派」：短链在 PHP/Node/TS 有生产级高星（Shlink/Kutt/Dub/YOURLS），Go/Rust 往往只有百来星的教学仓。**如实写对标对象是谁**，不要为了「Go 友好」硬凑一个低星玩具当标杆。
- 选 3–5 个覆盖不同技术路线（随机 vs 自增、同步 vs 异步统计、单体 vs SaaS 化），差异比数量重要。

### 2. 初筛：读 README / docs / CHANGELOG

对每个项目记一张小卡：技术栈、ID/短码生成方式、跳转语义（301/302/可配）、缓存、统计实现、过期/删除语义、安全做法、多租户。

然后做一张**「业界 vs 本方案」横向表**：

| 维度 | 业界主流 | 本方案当前 | 判断 |
| --- | --- | --- | --- |
| 短码生成 | 随机码 + DB 唯一约束（Shlink/Kutt/Dub） | 随机码 | 一致，无需改 |
| 唯一键 | `(short_code, domain_id)`（Shlink） | 单列短码 | **缺口：本期单域名，但终局应按复合键** |

表里每个「缺口」都是下一级的取证目标。

### 3. 读源码：只对「会改变设计」的关键论断

**不要通读全部源码**。只挑初筛表里标记为「缺口 / 有争议 / 不确定」的论断，逐条去源码里证实。常用手法：

```bash
# 浅克隆到临时目录（depth=1 省时省空间）
mkdir -p /tmp/oss-refs && cd /tmp/oss-refs
git clone --depth 1 -q https://github.com/<owner>/<repo> <name>

# 找关键实现：唯一键、生成器、跳转状态、统计、去重
grep -rn "uniqueIndex\|addUniqueIndex" <name>/    # 唯一键
grep -rn "nanoid\|random\|ShortCode" <name>/      # 短码生成
grep -rn "301\|302\|REDIRECT_STATUS" <name>/      # 跳转语义
grep -rn "geoip\|GeoIP\|identity_hash" <name>/    # 统计/地理
# 读迁移文件确认真实 schema：
find <name> -path "*migrations*" | head
```

**用完清理**：`rm -rf /tmp/oss-refs`。临时目录不入库。

### 4. 作为第一版的输入

调研发生在写作之前；每条取证结论都要落成「**补进哪一节 / 哪个决策 + 采纳与否 + 理由**」，例如：

> Shlink 用 `(short_code, domain_id)` 复合唯一索引（`Core/migrations/Version20241125213106.php`）。本文本期单域名，但唯一键改一次要停机迁全表，故按终局前置 `domain_id`（D12）。

文档里的「参考资料」或「技术选型」节应有一张对照表，带**源码文件路径**当证据锚点（可点开复核），而不是只有项目名和一句「参考了 XX」。

## 二、读源码时值得盯的高价值点

这些是 README 常漏、但对设计影响最大的地方：

| 关注点 | 为什么重要 | 怎么找 |
| --- | --- | --- |
| **唯一键 / 主键的真实定义** | 决定能不能多域名、要不要分片、改不改表 | 迁移文件里的 `addUniqueIndex` / `CREATE UNIQUE INDEX` |
| **ID/短码生成算法** | 随机 vs 自增 vs Hashids，决定碰撞、可枚举性 | 搜 `nanoid` / `randomInt` / `base62` / 生成器类 |
| **跳转状态码与缓存头** | 302 可统计、301 可缓存但不可撤回 | 搜 `REDIRECT_STATUS_CODE` / `Cache-Control` / 中间件 |
| **统计是同步还是异步** | 决定跳转主链路会不会被统计拖慢 | 搜队列（bull/kafka）、后台 job、写库位置 |
| **去重/幂等** | UV 与点击去重口径不同；重复点击会虚高 | 搜 `identity_hash`、`recordClick`、`dedup`、Redis key |
| **地理富化位置** | 写入侧（实时）vs 离线批处理（简单），影响报表延迟 | 搜 `geoip-lite` / `GeoLite2` / `LocateVisits` |
| **安全：开放重定向/SSRF** | 短链类系统的核心面，开源普遍弱 | 搜 `private\|loopback\|allowlist\|blocklist`、URL 校验 |

## 三、纪律清单

- **不抄代码**：AGPL/GPL 只作架构参考；本仓 MIT，不内联其代码与数据。
- **不硬凑**：找不到生产级高星 Go 实现就写实话，别拿教学仓当标杆。
- **不堆表**：对照表是手段，落到「本方案改什么」才是目的；只有「别家怎么做」没有「所以我们怎么做」视为未完成。
- **不采纳也要写理由**：业界做法与本文不同时，说明为什么不采纳（延迟要求、成本、范围），比假装业界也这么干强。
- **证据可点开**：给文件路径/行号，别只给「据某项目」。
- **记录台账**：取证过程落 `.dsh/docs/notes/<日期>-<主题>-oss-source-review.md`（clone 了什么、每条论断的证据路径、据此改了什么、没采纳什么）。
