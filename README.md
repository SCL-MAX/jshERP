# jshERP 二次开发：库存链路并发治理

基于开源 ERP [jishenghua/jshERP](https://github.com/jishenghua/jshERP)（进销存 + 财务）的二次开发实践。
原项目说明见 [README.upstream.md](README.upstream.md)。

本仓库记录的是我在**库存链路**上做的一次并发问题治理：从压测复现，到读源码定位，
到改造与验证的完整过程。

---

## 一、做了什么

### 起因

对「保存销售出库单」接口做压测，50 并发、库存 10，结果：

```
成功 1 / 失败 49 / 耗时 0.6s / 库存 10 -> 8
日志：48 次 MySQL Deadlock
```

不是账错了，是**并发下单时 96% 的订单直接失败**。低频时完全正常，所以很难发现。

### 五处改造

| # | 问题 | 改造 |
|---|---|---|
| 1 | 库存校验是「先查后比较」，并发下存在 check-then-act 窗口 | 改为单条条件更新 `... AND current_number >= n`，影响行数为 0 即库存不足 |
| 2 | 每保存一行明细都做一次全表聚合重算 + SELECT/UPDATE，写放大严重 | 改为增量扣减 / 累加，聚合逻辑从写路径移出 |
| 3 | 先插明细再更新库存，两事务加锁顺序相反，形成 ABBA 死锁 | 出库单**先扣库存、再写明细**，统一锁顺序 |
| 4 | RR 隔离级别下 UPDATE/INSERT 加间隙锁，高并发互相等待成环 | 事务隔离级别改为 `READ_COMMITTED` |
| 5 | `LogService` 的防刷逻辑：同一用户同 IP 同一秒内第二次操作就删除会话强制下线，误伤正常并发 | 改为只跳过重复日志，不再动会话；重复提交交给按单号的 2 秒幂等 |

### 改造前后

| 指标 | 改造前 | 改造后 |
|---|---|---|
| 50 并发成功数 | 1 | **9**（库存 9，卖光即止） |
| 库存结果 | 10 → 8 | **10 → 0**（精确扣减，无负数） |
| MySQL 死锁 | **48** | **0** |
| 用户被强制下线 | 12 次 | **0** |
| 空指针异常 | 36 次 | **0** |
| 失败原因 | 系统错误 | 全部为业务拒绝（库存不足 / 重复提交） |

### 改动文件

```
jshERP-boot/src/main/java/com/jsh/erp/service/DepotItemService.java          # 条件扣减、锁顺序
jshERP-boot/src/main/java/com/jsh/erp/service/DepotHeadService.java          # 事务隔离级别
jshERP-boot/src/main/java/com/jsh/erp/service/LogService.java                # 防刷误伤
jshERP-boot/src/main/java/com/jsh/erp/service/RedisService.java              # 会话缺失诊断日志
jshERP-boot/src/main/java/com/jsh/erp/datasource/mappers/DepotItemMapperEx.java
jshERP-boot/src/main/resources/mapper_xml/DepotItemMapperEx.xml              # 条件更新 SQL
jshERP-boot/src/main/resources/application.yml                               # Redis 连接池、相对路径
```

---

## 二、技术栈

- 后端：Spring Boot 2.0.0 / MyBatis-Plus 3.0.7 / MySQL 8 / Redis
- 前端：Vue 2.7 + Ant Design Vue 1.5 + vue-cli 3（webpack 4）
- JDK：**必须 1.8**（Spring Boot 2.0 依赖的 Spring 5.0 与 JDK 17+ 不兼容）

---

## 三、本地运行

### 依赖

| 组件 | 版本 | 说明 |
|---|---|---|
| JDK | 1.8 | 不能更高 |
| MySQL | 8.0 | 导入 `jshERP-boot/docs/jsh_erp.sql` |
| Redis | 5.x/6.x | 必须设置密码，配置里是 `1234abcd` |
| Node | **16** | 前端 vue-cli 3 不兼容 Node 17+ |

### 初始化数据库

```bash
mysql -uroot -p -e "CREATE DATABASE jsh_erp DEFAULT CHARSET utf8mb4;"
# Windows 下用 cmd 重定向，PowerShell 管道会破坏中文编码
cmd /c "mysql -uroot -p*** jsh_erp < jshERP-boot\docs\jsh_erp.sql"
```

首次安装只用 `jsh_erp.sql`，同目录下的「数据库更新记录」是升级脚本，不要导。

### 启动

```bash
# 后端（端口 9999，上下文路径 /jshERP-boot）
cd jshERP-boot
mvn -DskipTests clean package
java -jar target/jshERP.jar

# 前端（端口 3000）
cd jshERP-web
npm install --legacy-peer-deps
npm run serve
```

访问 `http://localhost:3000`，默认账号 **jsh / 123456**（租户管理员）。

> 注意：不要用 `admin` 登录。该账号被后端硬编码排除在按钮权限之外，
> 所有编辑弹窗会变成只读（见 `UserController#getUserBtnByCurrentUser`）。

### 常见问题

| 现象 | 原因 |
|---|---|
| 启动报 `Unable to create tempDir` | 系统临时目录不可写，启动时加 `-Djava.io.tmpdir=<可写目录>` |
| 启动报 `Cannot create parent directory ... target` | 项目放在受保护目录（如 `Documents`），换到普通目录 |
| `AccessDeniedException: ...\.m2\repository` | 安全软件拦截，用 `-Dmaven.repo.local=<可写目录>` |
| 前端 `ERR_OSSL_EVP_UNSUPPORTED` | Node 版本过高，降到 16 |
| 单据保存后库存不变 | `type` 字段中文被破坏（多半是客户端编码问题），检查是否落成 `??` |

---

## 四、压测

脚本在 [tools/loadtest](tools/loadtest)，含参数说明和踩坑记录。

```powershell
# 单发验证
powershell -ExecutionPolicy Bypass -File .\tools\loadtest\saleout-test.ps1 -Count 1
# 50 并发
powershell -ExecutionPolicy Bypass -File .\tools\loadtest\saleout-test.ps1 -Count 50
```

---

## 五、已知问题

- `admin` 账号拿不到按钮权限是硬编码实现的，更合理的做法是由角色配置决定。
- `deleteObjectByUserAndIp` / `deleteObjectByUser` 内部使用 `keys(*)` 全库扫描，
  会话多时是性能隐患，应改为按 userId 维护索引集合。
- 库存的「余额表」与「流水表」目前靠应用层保证一致，缺少定期对账任务。
  注意：不能简单按流水求和实现对账，还需把 `jsh_material_initial_stock`（期初库存）
  和调拨/组装等单据类型一并纳入，否则会误报。
- 库存重算逻辑仍在部分路径（调拨单）保留，未完全改为增量。

---

## 六、协议

原项目为 Apache-2.0，本仓库的修改同样遵循该协议。
