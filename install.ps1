# Copyright 2026 duobaiawa
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

<#
    MT5 -> MT5 同平台跟单桥 - Windows 一键安装
    右键本文件 -> "使用 PowerShell 运行"，或在 PowerShell 里执行 .\install.ps1
    全过程无需任何配置，结束后会自动打开控制台并显示管理令牌。
#>

param(
    [switch]$NoStart,        # 只安装不启动
    [switch]$Force,          # 重新生成令牌（会使已配置的客户端失效）
    [int]$Port = 0           # 覆盖默认端口
)

$ErrorActionPreference = "Stop"

function Pause-Safe($text) {
    # 交互式运行时暂停以便阅读；被 AI 代理或 CI 非交互调用时静默跳过。
    try { Read-Host $text | Out-Null } catch { }
}
$ProgressPreference = "SilentlyContinue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Say($text, $color = "White") { Write-Host $text -ForegroundColor $color }
function Step($n, $text) { Write-Host "" ; Write-Host "[$n/6] $text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "      OK  $text" -ForegroundColor Green }
function Bad($text) { Write-Host "      !!  $text" -ForegroundColor Red }

Say ""
Say "  ==================================================" Yellow
Say "   MT5 -> MT5 同平台跟单桥" Yellow
Say "   Windows 一键安装" Yellow
Say "  ==================================================" Yellow
Say ""
Say "  这套程序会在真实资金账户上自动下单。" Red
Say "  安装完成后交易开关默认关闭，请先用模拟账户验证。" Red
Say "  中国大陆用户请务必先读 COMPLIANCE.md。" Red

# ---------------------------------------------------------------- 1. Python
Step 1 "检查 Python 运行环境"
$pythonCmd = $null
foreach ($candidate in @("py -3.13", "py -3.12", "py -3.11", "python", "python3")) {
    $parts = $candidate.Split(" ")
    $exe = $parts[0]
    $args = if ($parts.Count -gt 1) { $parts[1..($parts.Count - 1)] } else { @() }
    try {
        $v = & $exe @args -c "import sys;print('%d.%d' % sys.version_info[:2])" 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) {
            $parsed = [version]$v
            if ($parsed -ge [version]"3.11") { $pythonCmd = $candidate; Ok "找到 Python $v ($candidate)"; break }
        }
    } catch { }
}
if (-not $pythonCmd) {
    Bad "没有找到 Python 3.11 或更高版本。"
    Say ""
    Say "  本程序需要 Python 3.11+（低版本会导致命令重发计时失效）。" Yellow
    Say "  请安装后重新运行本脚本：" Yellow
    Say "    https://www.python.org/downloads/" White
    Say ""
    Say "  安装时务必勾选 [Add Python to PATH]。" Yellow
    $open = try { Read-Host "  现在打开下载页面吗？(Y/n)" } catch { "n" }
    if ($open -ne "n") { Start-Process "https://www.python.org/downloads/" }
    Pause-Safe "  按回车退出"
    exit 1
}

# ---------------------------------------------------------------- 2. venv
Step 2 "创建独立运行环境 (.venv)"
$venvPython = Join-Path $Root ".venv\Scripts\python.exe"
if (Test-Path $venvPython) {
    Ok "运行环境已存在，跳过"
} else {
    $parts = $pythonCmd.Split(" ")
    $exe = $parts[0]
    $args = if ($parts.Count -gt 1) { $parts[1..($parts.Count - 1)] } else { @() }
    & $exe @args -m venv (Join-Path $Root ".venv")
    if (-not (Test-Path $venvPython)) { Bad "创建失败"; Pause-Safe "  按回车退出"; exit 1 }
    Ok "已创建 .venv"
}

# ---------------------------------------------------------------- 3. deps
Step 3 "安装依赖包"
& $venvPython -m pip install --quiet --upgrade pip 2>$null
& $venvPython -m pip install --quiet -r (Join-Path $Root "requirements.txt")
if ($LASTEXITCODE -ne 0) {
    Bad "依赖安装失败，尝试使用国内镜像重试..."
    & $venvPython -m pip install --quiet -i https://pypi.tuna.tsinghua.edu.cn/simple -r (Join-Path $Root "requirements.txt")
    if ($LASTEXITCODE -ne 0) { Bad "仍然失败，请检查网络后重试"; Pause-Safe "  按回车退出"; exit 1 }
}
Ok "依赖就绪"

# ---------------------------------------------------------------- 4. config
Step 4 "生成配置与访问令牌"
$envPath = Join-Path $Root ".env"
if ($Force -and (Test-Path $envPath)) {
    & $venvPython (Join-Path $Root "scripts\init_env.py") --force | Out-Null
    Ok "令牌已重新生成（旧令牌立即失效）"
} elseif (Test-Path $envPath) {
    Ok "配置已存在，保留现有令牌"
} else {
    & $venvPython (Join-Path $Root "scripts\init_env.py") | Out-Null
    Ok "已生成 .env 和随机令牌"
}

$config = @{}
foreach ($line in Get-Content $envPath -Encoding UTF8) {
    $t = $line.Trim()
    if ($t -and -not $t.StartsWith("#") -and $t.Contains("=")) {
        $k, $v = $t.Split("=", 2)
        $config[$k.Trim()] = $v.Trim()
    }
}
$adminToken = $config["FOREX_MT5_ADMIN_TOKEN"]
$bridgeToken = $config["FOREX_MT5_BRIDGE_TOKEN"]
if ($Port -gt 0) {
    $listenPort = $Port
    $content = Get-Content $envPath -Encoding UTF8
    if ($content -match "^FOREX_MT5_COPY_PORT=") {
        $content = $content -replace "^FOREX_MT5_COPY_PORT=.*", "FOREX_MT5_COPY_PORT=$Port"
    } else {
        $content += "FOREX_MT5_COPY_PORT=$Port"
    }
    Set-Content -Path $envPath -Value $content -Encoding UTF8
    Ok "监听端口已设为 $Port"
} else {
    $listenPort = if ($config["FOREX_MT5_COPY_PORT"]) { $config["FOREX_MT5_COPY_PORT"] } else { "18197" }
}

# ---------------------------------------------------------------- 5. self-test
Step 5 "自检"
$check = & $venvPython -c "import fastapi, uvicorn; import core; print('ok')" 2>&1
if ($LASTEXITCODE -ne 0) { Bad "自检失败: $check"; Pause-Safe "  按回车退出"; exit 1 }
Ok "模块加载正常"

$portBusy = Get-NetTCPConnection -LocalPort ([int]$listenPort) -State Listen -ErrorAction SilentlyContinue
if ($portBusy) {
    Bad "端口 $listenPort 已被占用（可能服务已在运行）"
    Say "      换端口重装：.\install.ps1 -Port 18200" Yellow
} else {
    Ok "端口 $listenPort 可用"
}

# ---------------------------------------------------------------- 6. start
Step 6 "启动服务"
if ($NoStart) {
    Ok "已跳过启动 (-NoStart)"
} elseif ($portBusy) {
    Ok "服务似乎已在运行，跳过启动"
} else {
    $startScript = Join-Path $Root "start.ps1"
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoExit", "-ExecutionPolicy", "Bypass", "-File", $startScript) `
        -WorkingDirectory $Root
    Ok "服务已在新窗口启动（关闭那个窗口即停止服务）"

    $url = "http://127.0.0.1:$listenPort"
    $ready = $false
    foreach ($i in 1..30) {
        Start-Sleep -Milliseconds 700
        try {
            $r = Invoke-WebRequest -Uri "$url/api/health" -TimeoutSec 2 -UseBasicParsing
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch { }
    }
    if ($ready) { Ok "服务已就绪" } else { Bad "服务启动超时，请查看新开的那个窗口里的报错" }
}

# ---------------------------------------------------------------- done
$url = "http://127.0.0.1:$listenPort"
Say ""
Say "  ==================================================" Green
Say "   安装完成" Green
Say "  ==================================================" Green
Say ""
Say "   控制台地址   $url" White
Say ""
Say "   管理令牌（首次打开控制台时粘贴进去）:" White
Say "   $adminToken" Yellow
Say ""
Say "   桥接令牌（装在 MT5 电脑上的桥接器要填这个）:" White
Say "   $bridgeToken" Yellow
Say ""
Say "   两个令牌也保存在本目录的 .env 文件里，不要发给任何人。" Gray
Say ""
Say "   注意：这只装好了【服务器】这一半。" Yellow
Say "   还要在跑 MT5 的电脑上装桥接器，把上面的桥接令牌填进去。" Yellow
Say "   步骤见 QUICKSTART.md 的第二部分。" Yellow
Say ""

Say "   下一步：" White
Say "     1. 浏览器会自动打开控制台，把上面的管理令牌粘进去" Gray
Say "     2. 在控制台里填好参数，先用模拟账户验证整条链路" Gray
Say "     3. 确认无误后再打开交易开关" Gray
Say ""
Say "   停止服务：关闭那个新开的 PowerShell 窗口" Gray
Say "   重新启动：双击运行 start.ps1" Gray
Say ""

if (-not $NoStart -and -not $portBusy) { Start-Process $url }
Pause-Safe "  按回车关闭本窗口"
