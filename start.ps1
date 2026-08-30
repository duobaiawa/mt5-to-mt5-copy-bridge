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
    MT5 -> MT5 同平台跟单桥 - 启动服务
    双击运行，或右键 -> "使用 PowerShell 运行"。
    关闭本窗口即停止服务。
#>

$ErrorActionPreference = "Stop"

function Pause-Safe($text) {
    # 交互式运行时暂停以便阅读；被 AI 代理或 CI 非交互调用时静默跳过。
    try { Read-Host $text | Out-Null } catch { }
}
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$venvPython = Join-Path $Root ".venv\Scripts\python.exe"
if (-not (Test-Path $venvPython)) {
    Write-Host "还没有安装。请先运行 install.ps1" -ForegroundColor Red
    Pause-Safe "按回车退出"
    exit 1
}

Write-Host ""
Write-Host "  MT5 -> MT5 同平台跟单桥" -ForegroundColor Yellow
Write-Host "  服务运行中 - 关闭本窗口即停止" -ForegroundColor Gray
Write-Host ""

& $venvPython (Join-Path $Root "app.py")

Write-Host ""
Write-Host "  服务已停止。" -ForegroundColor Yellow
Pause-Safe "  按回车关闭"
