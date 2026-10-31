# ============================================================
#  jshERP 销售出库并发压测脚本
#  用法: powershell -ExecutionPolicy Bypass -File .\saleout-test.ps1 -Count 50
#  说明见同目录 README.md
# ============================================================
param(
    [int]$Count = 1,
    [switch]$OnlyStock
)

# ---------------- 参数区（按自己环境修改） ----------------
$BaseUrl     = 'http://127.0.0.1:9999/jshERP-boot'
$LoginName   = 'jsh'
$PasswordMd5 = 'e10adc3949ba59abbe56e057f20f883e'   # md5('123456')
$BarCode     = '1018'
$DepotId     = 14
$OrganId     = 58
$AccountId   = 1
$RedisCli    = 'C:\redis\redis-cli.exe'
$RedisPass   = '1234abcd'
$MysqlExe    = ''                                    # 例如 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe'
$MysqlDb     = 'jsh_erp'
$MysqlUser   = 'root'
$MysqlPass   = '123456'
# ---------------------------------------------------------

$ErrorActionPreference = 'Stop'

# 中文用码点表示，保证脚本本体是纯 ASCII，避免 PowerShell 5.1 按 GBK 读 UTF-8 文件出错
$C_TYPE_OUT = [string][char]0x51FA + [char]0x5E93     # chu ku
$C_SUB_SALE = [string][char]0x9500 + [char]0x552E     # xiao shou
$C_UNIT_PCS = [string][char]0x4E2A                    # ge

function Get-Stock {
    if (-not $MysqlExe) { return $null }
    $env:MYSQL_PWD = $MysqlPass
    $out = & $MysqlExe "-u$MysqlUser" -N -B -e `
        "USE $MysqlDb; SELECT current_number FROM jsh_material_current_stock WHERE material_id=(SELECT material_id FROM jsh_material_extend WHERE bar_code='$BarCode' LIMIT 1) AND depot_id=$DepotId;"
    return [double]($out | Select-Object -First 1)
}

if ($OnlyStock) {
    $s = Get-Stock
    if ($null -eq $s) { "MysqlExe not configured" } else { "stock = $s" }
    return
}

# ---------- 1. 取验证码（直接从 Redis 读答案） ----------
$img  = Invoke-RestMethod -Uri "$BaseUrl/user/randomImage" -Method Get
$uuid = $img.data.uuid
$code = (& $RedisCli -a $RedisPass --no-auth-warning GET "captcha_codes:$uuid" 2>$null) | Select-Object -First 1
if (-not $code) { throw "captcha read failed, uuid=$uuid" }

# ---------- 2. 登录 ----------
$loginBody = @{ loginName = $LoginName; password = $PasswordMd5; code = $code; uuid = $uuid } | ConvertTo-Json
$login = Invoke-RestMethod -Uri "$BaseUrl/user/login" -Method Post -Body $loginBody -ContentType 'application/json'
$token = $login.data.token
if (-not $token) { $login | ConvertTo-Json -Depth 5; throw 'login failed' }
$headers = @{ 'X-Access-Token' = $token }

$now   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$stamp = Get-Date -Format 'yyMMddHHmmss'

function New-SaleOutBody([string]$number) {
    $info = [ordered]@{
        type = $C_TYPE_OUT; subType = $C_SUB_SALE; depotId = $DepotId; organId = $OrganId
        number = $number; operTime = $now; status = 0
        discount = 0; discountMoney = 0; discountLastMoney = 0; totalPrice = 0
        accountId = $AccountId; remark = 'loadtest'; fileName = ''
        accountIdList = ''; accountMoneyList = ''; salesMan = ''
        changeAmount = 0; debt = 0; deposit = 0; payType = ''
    } | ConvertTo-Json -Compress

    $rowObj = @{
        barCode = $BarCode; unit = $C_UNIT_PCS; operNumber = 1; unitPrice = 0; allPrice = 0
        taxRate = 0; taxMoney = 0; taxLastMoney = 0; depotId = $DepotId; remark = ''
    }
    # PS5.1 会把单元素数组在管道里拆包，必须用 -InputObject 保持数组形态
    $rows = ConvertTo-Json -InputObject @($rowObj) -Compress

    return @{ info = $info; rows = $rows } | ConvertTo-Json -Compress
}

$url = "$BaseUrl/depotHead/addDepotHeadAndDetail"
"stock before = " + (Get-Stock)

# ---------- 3. 单发 ----------
try {
    # 必须按 UTF-8 字节发送，否则中文变成 '?'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((New-SaleOutBody("XSCK$stamp" + "999")))
    $resp = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $bytes -ContentType 'application/json; charset=utf-8'
    "single shot  = code=$($resp.code) msg=$($resp.data)"
} catch {
    "single shot  = EXCEPTION: $($_.Exception.Message)"
}
"stock after  = " + (Get-Stock)

# ---------- 4. 并发 ----------
if ($Count -gt 1) {
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(60)

    $tasks = New-Object System.Collections.ArrayList
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Count; $i++) {
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post), $url
        $req.Headers.Add('X-Access-Token', $token)
        $req.Content = New-Object System.Net.Http.StringContent((New-SaleOutBody("XSCK$stamp" + $i.ToString('D3'))), [System.Text.Encoding]::UTF8, 'application/json')
        [void]$tasks.Add($client.SendAsync($req))
    }
    [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray())
    $sw.Stop()

    $ok = 0; $fail = 0; $msgs = @{}
    foreach ($t in $tasks) {
        $txt = $t.Result.Content.ReadAsStringAsync().Result
        if ($txt -match '"code"\s*:\s*200') { $ok++ }
        else {
            $fail++
            $m = if ($txt -match '"message"\s*:\s*"([^"]+)"') { $matches[1] } else { 'other' }
            $msgs[$m] = 1 + ($msgs[$m] -as [int])
        }
    }
    ""
    "concurrent   = $Count"
    "elapsed      = $([math]::Round($sw.Elapsed.TotalSeconds,2)) s"
    "success      = $ok"
    "failed       = $fail"
    if ($msgs.Count) { "fail msgs    = " + (($msgs.GetEnumerator() | ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ' | ') }
    "stock after  = " + (Get-Stock)
}
