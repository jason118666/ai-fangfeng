#requires -Version 7.0
<#
  ai-fangfeng 检查器（只读）
  用法：
    pwsh ./scripts/check.ps1
    pwsh ./scripts/check.ps1 -Json
    pwsh ./scripts/check.ps1 -Port 7892
  原则：不修改任何配置；不输出密钥、订阅地址、节点密码。
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [int]$ApiPort = 0,
    [switch]$Json
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$cfgDir = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$vergePath = Join-Path $cfgDir 'verge.yaml'
$genPath = Join-Path $cfgDir 'clash-verge.yaml'
$basePath = Join-Path $cfgDir 'config.yaml'

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$item, [string]$verdict, [string]$evidence, [string]$advice) {
    $results.Add([pscustomobject]@{ 项目 = $item; 结论 = $verdict; 证据 = $evidence; 建议 = $advice })
}

function Read-Lines([string]$path) {
    if (Test-Path -LiteralPath $path) { return @(Get-Content -LiteralPath $path -Encoding UTF8) }
    return @()
}
function Yaml-Scalar($lines, [string]$key) {
    foreach ($l in $lines) {
        if ($l -match "^\s*$([regex]::Escape($key)):\s*(.*)$") { return $Matches[1].Trim().Trim("'", '"') }
    }
    return $null
}
function Yaml-List($lines, [string]$key) {
    $vals = @(); $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^\s*$([regex]::Escape($key)):\s*$") { $start = $i; break } }
    if ($start -lt 0) { return $vals }
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-\s*(.+)$') { $vals += $Matches[1].Trim().Trim("'", '"') }
        elseif ($lines[$i].Trim() -eq '') { continue }
        else { break }
    }
    return $vals
}
function Yaml-Section($lines, [string]$name) {
    $out = @{}; $in = $false
    foreach ($l in $lines) {
        if ($l -match "^$([regex]::Escape($name)):\s*$") { $in = $true; continue }
        if ($in) {
            if ($l -match '^\S') { break }
            if ($l -match '^\s{2}([A-Za-z0-9_\-]+):\s*(.*)$') { $out[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    return $out
}

$verge = Read-Lines $vergePath
$gen = Read-Lines $genPath
$base = Read-Lines $basePath
$conf = if ($gen.Count) { $gen } else { $base }

# ---------- 基础信息 ----------
$os = Get-CimInstance Win32_OperatingSystem
$osName = "$($os.Caption) $([Environment]::OSVersion.Version)"
$tz = Get-TimeZone
Add-Result 'Windows / 时区' '信息' "$osName | $($tz.Id) UTC$(if($tz.BaseUtcOffset.TotalMinutes -ge 0){'+'}else{'-'})$([Math]::Abs($tz.BaseUtcOffset.TotalHours).ToString('00')):00" '时区是否与出口一致见下方「时区一致性」'

# ---------- 端口 ----------
$mixedPort = [int](Yaml-Scalar $conf 'mixed-port')
if ($Port -gt 0) { $mixedPort = $Port }
if (-not $mixedPort) { $mixedPort = [int](Yaml-Scalar $verge 'verge_mixed_port') }

$mihomo = Get-Process verge-mihomo -ErrorAction SilentlyContinue
$listenPorts = @()
if ($mihomo) {
    $listenPorts = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -in @($mihomo.Id) -and $_.LocalPort -ge 1024 } | Select-Object -ExpandProperty LocalPort -Unique)
}
if (-not $mixedPort -and $listenPorts.Count) { $mixedPort = ($listenPorts | Where-Object { $_ -ge 7000 -and $_ -le 9999 } | Select-Object -First 1) }

if (-not $mihomo) {
    Add-Result 'Clash 内核' '不符合' 'verge-mihomo 未运行' '启动 Clash Verge Rev 并确认内核已运行'
}
elseif (-not ($listenPorts -contains $mixedPort)) {
    Add-Result 'Clash 端口' '不符合' "配置端口 $mixedPort，实际监听 [$($listenPorts -join ', ')]" '重启 Clash 或把客户端端口改成实际监听端口'
}
else {
    Add-Result 'Clash 端口' '符合' "混合端口 $mixedPort 正在监听（PID $($mihomo.Id)）" ''
}

# ---------- 外部控制 ----------
$apiHostUrl = $null
$secret = Yaml-Scalar $base 'secret'
$apiCfg = Yaml-Scalar $base 'external-controller'
if ($ApiPort -gt 0) { $apiHostUrl = "127.0.0.1:$ApiPort" }
elseif ($apiCfg -and $apiCfg -match '^[0-9a-fA-F\.]+:\d+$') { $apiHostUrl = $apiCfg }
else {
    foreach ($p in 9097, 9090) {
        if (Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue) { $apiHostUrl = "127.0.0.1:$p"; break }
    }
}

function Get-Api([string]$path) {
    if (-not $apiHostUrl) { return $null }
    try {
        $h = @{}
        if ($secret) { $h['Authorization'] = "Bearer $secret" }
        return Invoke-RestMethod -Uri "http://$apiHostUrl$path" -Headers $h -TimeoutSec 4
    }
    catch { return $null }
}

$apiConfigs = Get-Api '/configs'
$apiProxies = Get-Api '/proxies'

# ---------- 模式 / TUN ----------
$mode = if ($apiConfigs) { $apiConfigs.mode } else { Yaml-Scalar $conf 'mode' }
if ($mode -eq 'rule') { Add-Result '路由模式' '符合' 'rule（规则模式）' '' }
else { Add-Result '路由模式' '不符合' "当前 $mode" 'Clash 首页切换到「规则」模式' }

if ($apiConfigs) {
    $tun = $apiConfigs.tun
} else {
    $t = Yaml-Section $conf 'tun'
    $tun = [pscustomobject]@{
        enable = $t['enable']; stack = $t['stack']; mtu = $t['mtu']
        'strict-route' = $t['strict-route']; 'auto-route' = $t['auto-route']
        'auto-detect-interface' = $t['auto-detect-interface']
        'dns-hijack' = @(Yaml-List $conf 'dns-hijack')
    }
}
$tunEnabled = "$($tun.enable)" -eq 'True'
$tunParts = @()
$tunParts += if ($tunEnabled) { 'enable=true' } else { 'enable=false' }
$tunParts += "stack=$($tun.stack)"
$tunParts += "strict-route=$($tun.'strict-route')"
$tunParts += "auto-route=$($tun.'auto-route')"
$tunParts += "auto-detect-interface=$($tun.'auto-detect-interface')"
$tunParts += "mtu=$($tun.mtu)"
$tunParts += "dns-hijack=$(@($tun.'dns-hijack') -join ',')"
$tunOk = $tunEnabled -and "$($tun.'strict-route')" -eq 'True' -and "$($tun.'auto-route')" -eq 'True'
Add-Result 'TUN 与严格路由' $(if ($tunOk) { '符合' } else { '不符合' }) ($tunParts -join ' | ') $(if ($tunOk) { '' } else { '打开 TUN，并勾选严格路由/自动路由' })

# ---------- DNS ----------
$ns = @(); $direct = @(); $respect = $null; $dnsEnabled = $null
if ($apiConfigs -and $apiConfigs.dns) {
    $ns = @($apiConfigs.dns.nameserver)
    $direct = @($apiConfigs.dns.'direct-nameserver')
    $respect = "$($apiConfigs.dns.'respect-rules')"
    $dnsEnabled = "$($apiConfigs.dns.enable)"
}
else {
    $dnsSec = Yaml-Section $conf 'dns'
    $ns = @(Yaml-List $conf 'nameserver' | Where-Object { $_ -match '^[a-z]+://|^\d' })
    $direct = @(Yaml-List $conf 'direct-nameserver')
    $respect = $dnsSec['respect-rules']
    $dnsEnabled = $dnsSec['enable']
}
if ($dnsEnabled) {
    $dnsParts = "开=$dnsEnabled | 遵循路由=$respect | 域名服务器=$(if($ns.Count){$ns[0]}else{'空'}) | 直连=$(if($direct.Count){$direct[0]}else{'空'})"
    $dnsOk = ($dnsEnabled -eq 'true') -and ($respect -eq 'true') -and ($ns.Count -gt 0) -and ($direct.Count -gt 0)
    Add-Result 'DNS 分流' $(if ($dnsOk) { '符合' } else { '不符合' }) $dnsParts $(if ($dnsOk) { '' } else { 'Clash → 设置 → DNS 覆写：打开、勾选遵循路由规则、补「直连域名服务器」' })
}
else {
    Add-Result 'DNS 分流' '不符合' 'DNS 覆写未开启' 'Clash → 设置 → DNS 覆写：打开，并补「直连域名服务器」'
}

# ---------- 系统代理 / 环境变量端口一致性 ----------
$ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$sysOn = "$($ie.ProxyEnable)" -eq '1'
$sysServer = "$($ie.ProxyServer)"
$envProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')
$envPort = if ($envProxy -match ':(\d+)') { [int]$Matches[1] } else { 0 }
$sysPort = if ($sysServer -match ':(\d+)') { [int]$Matches[1] } else { 0 }

Add-Result '系统代理' $(if ($sysOn -and $sysPort -eq $mixedPort) { '符合' } elseif ($sysOn) { '不符合' } else { '提醒' }) "系统代理=$(if($sysOn){'开'}else{'关'})，指向 $(if($sysServer){$sysServer}else{'空'})" $(if ($sysOn -and $sysPort -eq $mixedPort) { '' } elseif ($sysOn) { "把系统代理的端口改成 Clash 的 $mixedPort" } else { "打开 Clash 首页的系统代理（指向 $mixedPort），Clash 退出时浏览器会断网而不是裸连" })

$portOk = ($envPort -eq 0 -or $envPort -eq $mixedPort) -and ($sysPort -eq 0 -or $sysPort -eq $mixedPort)
Add-Result '端口一致性' $(if ($portOk) { '符合' } else { '不符合' }) "Clash=$mixedPort | 环境变量=$envPort | 系统代理=$sysPort" $(if ($portOk) { '' } else { '把所有代理工具的端口统一成同一个值，并同步环境变量/系统代理' })

# ---------- 客户端代理变量 ----------
if ($envPort -eq 0) {
    Add-Result 'Claude Code / Codex 兜底' '提醒' '未设置用户级 HTTPS_PROXY' '设置 HTTPS_PROXY=http://127.0.0.1:<端口>，Clash 掉线时客户端会失败关闭而不是裸连'
}
elseif ($envPort -ne $mixedPort) {
    Add-Result 'Claude Code / Codex 兜底' '不符合' "HTTPS_PROXY 指向 $envPort，Clash 实际 $mixedPort" '改成与 Clash 端口一致'
}
else {
    Add-Result 'Claude Code / Codex 兜底' '符合' "HTTPS_PROXY=http://127.0.0.1:$envPort（新开终端才生效）" ''
}

$codexEnv = Join-Path $HOME '.codex\.env'
if (Test-Path -LiteralPath $codexEnv) {
    $line = (Get-Content -LiteralPath $codexEnv -Encoding UTF8 | Where-Object { $_ -match '^\s*HTTPS?_PROXY\s*=' } | Select-Object -First 1)
    $codexPort = if ($line -match ':(\d+)') { [int]$Matches[1] } else { 0 }
    if ($codexPort -and $codexPort -ne $mixedPort) {
        Add-Result 'Codex .env 代理' '不符合' "$codexEnv 指向 $codexPort，Clash 实际 $mixedPort" '改端口或删除这两行'
    }
    elseif ($codexPort) {
        Add-Result 'Codex .env 代理' '符合' "$codexEnv 指向 $codexPort" ''
    }
}

# ---------- 行为探测 ----------
function Invoke-Curl([string]$url) {
    if (-not $mixedPort) { return '' }
    return (& curl.exe -s --max-time 20 --proxy "http://127.0.0.1:$mixedPort" $url 2>$null | Out-String)
}
function Get-Connections {
    $c = Get-Api '/connections'
    if ($c) { return @($c.connections) }
    return @()
}
function Get-Chain([string]$url, [string]$pattern, [int]$seconds = 10) {
    if (-not $apiHostUrl) { return $null }
    $tmp = [IO.Path]::GetTempFileName()
    $proc = Start-Process -FilePath 'curl.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-s', '-o', $tmp, '--limit-rate', '2k', '--max-time', "$seconds",
        '--proxy', "http://127.0.0.1:$mixedPort", $url
    )
    $found = $null
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 350
        foreach ($cn in (Get-Connections)) {
            if ($cn.metadata.host -match $pattern) { $found = $cn; break }
        }
        if ($found) { break }
    }
    if ($proc -and -not $proc.HasExited) { $proc.Kill() }
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    return $found
}

$trace = Invoke-Curl 'https://claude.ai/cdn-cgi/trace'
$traceIp = if ($trace -match 'ip=([0-9\.]+)') { $Matches[1] } else { $null }
$traceLoc = if ($trace -match 'loc=([A-Z]+)') { $Matches[1] } else { $null }
$traceColo = if ($trace -match 'colo=([A-Z0-9]+)') { $Matches[1] } else { $null }

$info = $null
$infoRaw = Invoke-Curl 'https://ipinfo.io/json'
if ($infoRaw.Trim().StartsWith('{')) { $info = $infoRaw | ConvertFrom-Json }

if (-not $traceIp) {
    Add-Result 'Claude 链路' '不符合' '经代理访问 claude.ai 失败（连不上或端口未监听）' '确认 Clash 已运行且端口正确'
}
else {
    $chain = Get-Chain 'https://claude.ai/cdn-cgi/trace' 'claude\.ai'
    if ($chain) {
        $hops = @($chain.chains)
        $group = if ($hops.Count -ge 2) { $hops[1] } else { $null }
        $isDirect = ($hops -contains 'DIRECT')
        $ev = "规则=$($chain.rule)/$($chain.rulePayload) | 链路=$($hops -join ' <- ') | 出口=$traceIp $traceLoc/$traceColo"
        Add-Result 'Claude 链路' $(if ($isDirect) { '不符合' } else { '符合' }) $ev $(if ($isDirect) { '这条链路走了 DIRECT，必须改规则指向代理组' } else { '' })
        if ($group -and $apiProxies -and $apiProxies.proxies.$group) {
            $members = @($apiProxies.proxies.$group.all)
            $hasDirect = $members -contains 'DIRECT'
            Add-Result 'AI 组内是否含 DIRECT' $(if ($hasDirect) { '提醒' } else { '符合' }) "组「$group」成员 $($members.Count) 个，含 DIRECT=$hasDirect" $(if ($hasDirect) { '组里保留 DIRECT 时，误选会把 AI 流量直连，建议移除或不要选中' } else { '' })
        }
    }
    else {
        Add-Result 'Claude 链路' '无法判断' "只能确认出口 $traceIp $traceLoc，读不到链路（外部控制关闭或请求太快）" 'Clash 设置里打开外部控制（仅本机 127.0.0.1）后重跑'
    }
}

if ($info) {
    $cn = $info.country
    Add-Result '出口 IP 属性' $(if ($cn -eq 'CN') { '不符合' } else { '符合' }) "$($info.ip) | $($info.city)/$($info.country) | $($info.org) | tz=$($info.timezone)" $(if ($cn -eq 'CN') { '出口落在中国，等于没走代理' } else { '' })

    try {
        $ipTz = [TimeZoneInfo]::FindSystemTimeZoneById($info.timezone)
        $diff = [Math]::Abs(($ipTz.BaseUtcOffset - $tz.BaseUtcOffset).TotalHours)
        Add-Result '时区一致性' $(if ($diff -eq 0) { '符合' } else { '不符合' }) "本机 $($tz.Id) UTC$($tz.BaseUtcOffset.ToString('hh\:mm')) | 出口 $($info.timezone)" $(if ($diff -eq 0) { '' } else { '把 Windows 时区改成出口所在地' })
    }
    catch { Add-Result '时区一致性' '无法判断' "出口时区 $($info.timezone) 无法映射到本机时区库" '' }
}

$cnEcho = Invoke-Curl 'https://myip.ipip.net'
if ($cnEcho -match '中国') {
    Add-Result '国内网站直连' '符合' "经代理访问国内检测点返回：$($cnEcho.Trim() -replace '\s+', ' ')" ''
}
elseif ($cnEcho) {
    Add-Result '国内网站直连' '提醒' "国内检测点返回：$($cnEcho.Trim() -replace '\s+', ' ')" '若显示海外 IP，说明国内流量被代理了；检查 GEOSITE,cn / GEOIP,CN 兜底规则'
}
else {
    Add-Result '国内网站直连' '无法判断' '国内检测点无响应' ''
}

$catchAll = Get-Chain 'https://example.com' 'example\.com' 8
if ($catchAll) {
    $hops = @($catchAll.chains)
    Add-Result '兜底去向' '信息' "example.com → $($hops -join ' <- ')" '兜底组是「没命中任何规则」的流量去的地方，按需确认是否符合预期'
}

$trace2 = Invoke-Curl 'https://claude.ai/cdn-cgi/trace'
$ip2 = if ($trace2 -match 'ip=([0-9\.]+)') { $Matches[1] } else { $null }
if ($traceIp -and $ip2) {
    Add-Result '出口稳定性' $(if ($traceIp -eq $ip2) { '符合' } else { '提醒' }) "两次请求出口：$traceIp / $ip2" $(if ($traceIp -eq $ip2) { '' } else { '出口 IP 会变，多账号场景更容易被关联，建议换固定出口节点' })
}

# ---------- 系统隐私 ----------
$loc = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location').Value
Add-Result 'Windows 定位授权' $(if ($loc -eq 'Deny') { '符合' } else { '不符合' }) "HKCU Value=$loc" $(if ($loc -eq 'Deny') { '' } else { '设置 → 隐私 → 位置：关闭定位' })

$webrtc = @()
foreach ($k in @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge')) {
    $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue).WebRtcIPHandlingPolicy
    $name = if ($k -like '*Chrome*') { 'Chrome' } else { 'Edge' }
    if ($v) { $webrtc += "$name=$v" }
}
Add-Result '浏览器 WebRTC' $(if ($webrtc.Count -ge 1) { '符合' } else { '提醒' }) $(if ($webrtc.Count) { $webrtc -join ' | ' } else { '未设置 WebRtcIPHandlingPolicy' }) $(if ($webrtc.Count) { '' } else { '设置 WebRtcIPHandlingPolicy=disable_non_proxied_udp，避免 TUN 关闭时 WebRTC 泄露' })

# ---------- 输出 ----------
if ($Json) {
    $results | ConvertTo-Json -Depth 4
    if (@($results | Where-Object { $_.结论 -eq '不符合' }).Count -gt 0) { exit 1 }
    exit 0
}

$pass = @($results | Where-Object { $_.结论 -eq '符合' })
$bad = @($results | Where-Object { $_.结论 -eq '不符合' })
$warn = @($results | Where-Object { $_.结论 -eq '提醒' })
$unk = @($results | Where-Object { $_.结论 -eq '无法判断' })

""
if ($pass.Count) { "通过 $($pass.Count) 项：" + (($pass | ForEach-Object { $_.项目 }) -join '、') }
""

$need = @($bad) + @($warn) + @($unk)
if ($need.Count -eq 0) {
    "没有发现问题。"
}
else {
    "要处理 $($need.Count) 项："
    $i = 0
    foreach ($r in $need) {
        $i++
        $tag = switch ($r.结论) { '不符合' { '[X]' } '提醒' { '[!]' } default { '[?]' } }
        "$i. $tag $($r.项目)：$($r.证据)"
        if ($r.建议) { "   → $($r.建议)" }
    }
}
""
if ($bad.Count -eq 0 -and $warn.Count -eq 0) { "结论：可以用。" }
elseif ($bad.Count -gt 0) { "结论：有 $($bad.Count) 项必须改。" }
else { "结论：能用，有 $($warn.Count) 项建议改。" }
""

if ($bad.Count -gt 0) { exit 1 }
exit 0
