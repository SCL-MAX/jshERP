# 并发压测证据

同一脚本、同一参数（50 并发，库存 10），改造前后的真实输出。

- 脚本：[tools/loadtest/saleout-test.ps1](../../tools/loadtest/saleout-test.ps1)
- 环境：Windows 11 / JDK 1.8 / MySQL 8.0.46 / Redis 5.0.14 / 单机
- 接口：`POST /jshERP-boot/depotHead/addDepotHeadAndDetail`（销售出库）

---

## 改造前

> 原始终端输出已随调试窗口关闭，以下为当时记录值；死锁堆栈摘自后端日志。

```
success      = 1
failed       = 49
elapsed      = 0.6 s
stock        = 8 -> 7        (只扣了 1)
```

后端日志（48 条，节选）：

```
### Error updating database.
### Cause: MySQLTransactionRollbackException:
###   Deadlock found when trying to get lock; try restarting transaction
### The error may involve DepotItemMapperEx.batchInsert-Inline
### SQL: INSERT INTO jsh_depot_item (...) VALUES (...)
at com.jsh.erp.service.DepotItemService.saveDetials(DepotItemService.java:685)
```

失败构成：48 次死锁 + 1 次"请不要频繁提交单据"。

第一次改造（只调整锁顺序、未改隔离级别）后，死锁消失，但暴露出第二个问题：

```
### Global Exception Occured ... msg : null
java.lang.NullPointerException
at com.jsh.erp.service.UserService.getCurrentUser(UserService.java:507)
at com.jsh.erp.service.DepotService.findDepotByCurrentUser(DepotService.java:318)
```

即并发下一次操作把用户会话删掉了（详见 README 改造点 5）。

---

## 改造后

原始输出见 [after-50-concurrency.txt](after-50-concurrency.txt)：

```
stock before = 10
single shot  = code=200 msg=
stock after  = 9
concurrent   = 50
elapsed      = 0.97 s
success      = 9
failed       = 41
fail msgs    = 商品:测试商品1-1018库存不足 x31 | 商品:测试商品1库存不足 x9 | 抱歉，请不要频繁提交单据 x1
stock after  = 0
```

### 怎么读这份结果

| 指标 | 含义 |
|---|---|
| `success = 9` | 库存剩 9，正好卖出 9 单，卖光即止 |
| `库存不足 x40` | 业务拒绝（预期行为），不是系统错误 |
| `频繁提交 x1` | 单号与单发请求撞了，被 2 秒幂等拦住，属预期 |
| `stock after = 0` | 库存精确归零，**没有负数** |
| 没有 `未知异常` | 死锁与空指针都消失了 |

判定标准：**失败的 41 单全部是业务拒绝，没有一条是 5xx 系统异常**。

---

## 如何复现

```powershell
# 1. 把测试商品的库存重置为 10
mysql -uroot -p -e "USE jsh_erp; UPDATE jsh_material_current_stock SET current_number=10 WHERE material_id=620 AND depot_id=14;"

# 2. 跑 50 并发
powershell -ExecutionPolicy Bypass -File .\tools\loadtest\saleout-test.ps1 -Count 50

# 3. 看库存
mysql -uroot -p -e "USE jsh_erp; SELECT material_id, depot_id, current_number FROM jsh_material_current_stock WHERE material_id=620;"
```

预期：`success` 等于开始时的库存数，`stock after` 为 0，失败原因全部是「库存不足」。

> 注意：`single shot` 会先消耗 1 个库存，所以起始 10 时并发阶段只剩 9 个可卖。
