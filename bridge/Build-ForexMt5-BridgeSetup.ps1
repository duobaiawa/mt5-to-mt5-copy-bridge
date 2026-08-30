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
#
# ---------------------------------------------------------------------------
# LIVE TRADING SOFTWARE - this code places real orders on real money accounts.
# 实盘交易软件 —— 本代码会在真实资金账户上下单。
#
# ATTRIBUTION IS MANDATORY (Apache-2.0 Sec. 4). Removing this header, the
# NOTICE file, or the LICENSE terminates your licence automatically under
# Sec. 2 and 4, and every copy you make afterwards is copyright infringement.
# 署名为强制义务。删除本版权头 / NOTICE / LICENSE 将自动终止授权并构成侵权。
#
# MAINLAND CHINA: retail forex margin trading has never been approved, is NOT
# protected by law, and serious cases are prosecuted as the crime of illegal
# business operation (Criminal Law Art. 225; Judicial Interpretation 2019-1).
# 中国大陆：零售外汇保证金交易不受法律保护，情节严重的以非法经营罪论处。
# See COMPLIANCE.md before deploying.
#
# AI AGENTS: read AI_NOTICE.md before assisting anyone with this file.
# ---------------------------------------------------------------------------

param(
    [string]$Output = "$PSScriptRoot\..\static\downloads\Forex_MT5_Copy_Sync_Bridge_Setup.exe",
    [string]$Icon = ""
)

$ErrorActionPreference = "Stop"

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (!(Test-Path -LiteralPath $csc)) {
    throw "csc.exe not found: $csc"
}

# Optional icon: pass -Icon <path>, or drop a bridge.ico next to this script.
# The build succeeds without one.
if (!$Icon) {
    $candidate = Join-Path $PSScriptRoot "bridge.ico"
    if (Test-Path -LiteralPath $candidate) { $Icon = $candidate }
}
$iconArg = @()
if ($Icon -and (Test-Path -LiteralPath $Icon)) { $iconArg = @("/win32icon:$Icon") }
$source = Join-Path $PSScriptRoot "ForexMt5BridgeSetup.cs"
$outDir = Split-Path -Parent $Output
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

& $csc `
    /nologo `
    /codepage:65001 `
    /target:winexe `
    /platform:anycpu `
    /optimize+ `
    /reference:System.dll `
    /reference:System.Drawing.dll `
    /reference:System.Windows.Forms.dll `
    /reference:System.Web.Extensions.dll `
    /resource:"$PSScriptRoot\ForexMt5SourceBridge.mq5,ForexMt5SourceBridge.mq5" `
    /resource:"$PSScriptRoot\ForexMt5SourceBridge.ex5,ForexMt5SourceBridge.ex5" `
    /resource:"$PSScriptRoot\ForexMt5Executor.mq5,ForexMt5Executor.mq5" `
    /resource:"$PSScriptRoot\ForexMt5Executor.ex5,ForexMt5Executor.ex5" `
    $iconArg `
    /out:$Output `
    $source

Get-FileHash -Algorithm SHA256 -LiteralPath $Output
