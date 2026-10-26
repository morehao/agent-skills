# 库存校验方案

## 背景与目标

### 现状与问题

下单链路当前没有库存校验，超卖靠事后对账发现，现状有待优化 TBD（反模式清单见 references/quality-bar.md）。

### 目标与非目标

目标：提升下单体验，减少超卖。系统需要高性能、高可用。

## 方案与选型对比

### 备选方案

方案 A：在下单前加校验，多一次 RPC。
方案 B：在下单后异步校验，失败再补偿。

## 详细技术设计

### 缓存设计

N/A

### 数据模型

| 字段 | 类型 | 说明 |
|---|---|---|
| id | BIGSERIAL | 主键 |
| order_id | VARCHAR(32) | 订单号 |

## 性能与容量

| 项 | 数值 |
|---|---|
| 单节点承载 | 600 QPS |
| 扩容后总量 | 4800 QPS |

## 风险与应对

缓存击穿会导致数据库压力增大，需要加强监控。

## 附录

```sql
CREATE TABLE order_reserve_record (
  id BIGSERIAL PRIMARY KEY,
  order_id VARCHAR(32) NOT NULL,
  sku_id VARCHAR(32) NOT NULL
);
```
