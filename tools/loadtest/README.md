# 销售出库并发压测脚本（jshERP）

用于复现 / 验证「并发保存单据」场景下的库存一致性问题。

## 为什么自己写，而不是用 JMeter

1. jshERP 登录带图形验证码，JMeter 处理麻烦；本脚本直接从 Redis 读取验证码答案。
2. 需要给每个并发请求生成**唯一单号**，JMeter 配置成本高。
3. 需要在压测前后读库存做对比，脚本里一次搞定。

## 前置条件

- 后端已启动（默认 `http://127.0.0.1:9999/jshERP-boot`）
- Redis 可访问（脚本从 `captcha_codes:<uuid>` 读取验证码）
- 可选：本机有 `mysql.exe`，用来压测前后读库存

## 参数

脚本顶部是参数区，按自己环境改：

| 参数 | 说明 | 默认 |
|---|---|---|
| `$BaseUrl` | 后端地址 | `http://127.0.0.1:9999/jshERP-boot` |
| `$LoginName` | 登录账号（**不要用 admin**，admin 拿不到按钮权限） | `jsh` |
| `$PasswordMd5` | 密码的 MD5（前端就是 MD5 后明文上传） | `123456` 的 MD5 |
| `$BarCode` | 商品条码 | `1018` |
| `$DepotId` | 仓库 id | `14` |
| `$OrganId` | 客户 id | `58` |
| `$RedisCli` | redis-cli 路径 | `C:\redis\redis-cli.exe` |
| `$MysqlExe` | mysql.exe 路径，留空则不读库存 | 空 |

## 用法

```powershell
# 单发验证（先跑这个，确认请求体能被后端接受）
powershell -ExecutionPolicy Bypass -File .\saleout-test.ps1 -Count 1

# 50 并发
powershell -ExecutionPolicy Bypass -File .\saleout-test.ps1 -Count 50

# 只看当前库存
powershell -ExecutionPolicy Bypass -File .\saleout-test.ps1 -OnlyStock
```

## 踩过的坑（改脚本时注意）

1. **`rows` 必须是数组**：PowerShell 会把单元素数组在管道里拆包，
   `@($x) | ConvertTo-Json` 得到的是对象不是数组，后端 fastjson 直接报
   `syntax error, expect [, actual {`。要用 `ConvertTo-Json -InputObject @($x)`。
2. **body 必须按 UTF-8 字节发送**：`Invoke-RestMethod -Body $string` 默认按 ASCII
   编码，中文会变成 `?`，导致 `type` 字段落库为 `??`、库存不更新。
3. **每个请求要带唯一单号**：后端有 `用户_单号` 的 2 秒幂等校验，重复单号会被拒。
4. **header 要逐请求设置**：`HttpClient.DefaultRequestHeaders` 在部分环境下不生效，
   用 `HttpRequestMessage` 单独加 `X-Access-Token`。

## 认证机制（读源码得到）

- 登录：`POST /user/login`，body `{loginName, password(MD5), code, uuid}`
- 验证码：`GET /user/randomImage` 返回 `{uuid, base64}`，答案存在 Redis
  `captcha_codes:<uuid>`（2 分钟过期）
- 鉴权：请求头 `X-Access-Token`，服务端以该值为 key 查 Redis hash，取 `userId`
- 保存单据：`POST /depotHead/addDepotHeadAndDetail`，body `{info, rows}` 两个 JSON 字符串
