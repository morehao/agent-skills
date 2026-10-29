# 订单金额方案

> 状态：草案待评 ｜ 作者：@a ｜ 评审人：@b ｜ 拍板人：@c ｜ 最后更新：2026-10-29

## 数据模型

| 字段 | 类型 | 可空 | 说明 |
|---|---|---|---|
| id | BIGINT | 否 | 主键 |
| amount | DECIMAL(10,2) | 否 | 金额 |

## 备选与取舍

方案 A：不做；方案 B：加金额字段。

## 附录

### 数据模型 DDL

```sql
CREATE TABLE t_order (
  id BIGINT PRIMARY KEY,
  amount BIGINT NOT NULL
);
```
