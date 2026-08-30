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
    [string]$ApiUrl = "http://127.0.0.1:18197",
    [string]$ExecutorId = "executor",
    [string]$BridgeToken = "",
    [int]$IntervalSeconds = 1,
    [string]$BridgeFolder = "Forex_MT5_Copy"
)

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CommonDir = Join-Path $env:APPDATA (Join-Path "MetaQuotes\Terminal\Common\Files" $BridgeFolder)
$SourceOutbox = Join-Path $CommonDir "source_outbox.jsonl"
$SourceSentFile = Join-Path $CommonDir "source_sent_ids.txt"
$CommandFile = Join-Path $CommonDir ("commands_{0}.csv" -f $ExecutorId)
$AckFile = Join-Path $CommonDir ("acks_{0}.jsonl" -f $ExecutorId)
$AckSentFile = Join-Path $CommonDir ("acks_sent_{0}.txt" -f $ExecutorId)
$LogFile = Join-Path $CommonDir "bridge_agent.log"
$SourceSent = @{}
$AckSent = @{}

function Write-BridgeLog([string]$Text) {
    New-Item -ItemType Directory -Force -Path $CommonDir | Out-Null
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text"
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Load-Set([string]$Path, [hashtable]$Target) {
    if (Test-Path -LiteralPath $Path) {
        Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | ForEach-Object {
            $v = $_.Trim()
            if ($v) { $Target[$v] = $true }
        }
    }
}

function Add-Set([string]$Path, [string[]]$Ids, [hashtable]$Target) {
    if (!$Ids -or $Ids.Count -eq 0) { return }
    foreach ($id in $Ids) { $Target[$id] = $true }
    Add-Content -LiteralPath $Path -Value $Ids -Encoding UTF8
}

function Headers {
    $headers = @{}
    if ($BridgeToken) { $headers["X-Bridge-Token"] = $BridgeToken }
    return $headers
}

function Read-SourceRows {
    $rows = New-Object System.Collections.ArrayList
    if (!(Test-Path -LiteralPath $SourceOutbox)) { return $rows }
    foreach ($line in (Get-Content -LiteralPath $SourceOutbox -ErrorAction SilentlyContinue)) {
        $text = $line.Trim()
        if (!$text) { continue }
        try {
            $row = $text | ConvertFrom-Json
            $sourceId = [string]$row.source_id
            $ticket = [string]$row.ticket
            if (!$sourceId -or !$ticket) { continue }
            $id = "$sourceId|$ticket"
            if ($SourceSent.ContainsKey($id)) { continue }
            [void]$rows.Add([pscustomobject]@{ Id = $id; SourceId = $sourceId; Row = $row })
        } catch {
            Write-BridgeLog "bad source row skipped: $($_.Exception.Message)"
        }
    }
    return $rows
}

function Post-SourceGroup($sourceId, $items) {
    $deals = @()
    $ids = @()
    foreach ($item in $items) {
        $deals += $item.Row
        $ids += $item.Id
    }
    if ($deals.Count -eq 0) { return }
    $payload = @{ source_id = $sourceId; deals = $deals } | ConvertTo-Json -Depth 12 -Compress
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "$ApiUrl/api/source-deals/ingest" -Headers (Headers) -Body $payload -ContentType "application/json" -TimeoutSec 15
        Add-Set $SourceSentFile $ids $SourceSent
        Write-BridgeLog "posted $($ids.Count) source deal(s), SourceId=$sourceId, accepted=$($resp.accepted), duplicates=$($resp.duplicates), commands=$($resp.commands)"
    } catch {
        Write-BridgeLog "source post failed SourceId=${sourceId}: $($_.Exception.Message)"
    }
}

function Pull-Commands {
    try {
        $resp = Invoke-RestMethod -Method Get -Uri "$ApiUrl/api/execution/commands?executor_id=$ExecutorId&limit=100" -Headers (Headers) -TimeoutSec 15
        $ids = @()
        foreach ($cmd in @($resp.commands)) {
            $line = @(
                [string]$cmd.command_id,
                [string]$cmd.action,
                [string]$cmd.symbol,
                [string]$cmd.side,
                [string]$cmd.position_side,
                [string]$cmd.volume,
                [string]$cmd.client_ref,
                [string]$cmd.max_slippage_points
            ) -join "|"
            Add-Content -LiteralPath $CommandFile -Value $line -Encoding ASCII
            $ids += [string]$cmd.command_id
        }
        if ($ids.Count -gt 0) {
            $payload = @{ executor_id = $ExecutorId; command_ids = $ids } | ConvertTo-Json -Depth 6 -Compress
            Invoke-RestMethod -Method Post -Uri "$ApiUrl/api/execution/delivered" -Headers (Headers) -Body $payload -ContentType "application/json" -TimeoutSec 15 | Out-Null
            Write-BridgeLog "delivered $($ids.Count) command(s) to MT5 executor"
        }
    } catch {
        Write-BridgeLog "command pull failed: $($_.Exception.Message)"
    }
}

function Read-Acks {
    $acks = New-Object System.Collections.ArrayList
    if (!(Test-Path -LiteralPath $AckFile)) { return $acks }
    foreach ($line in (Get-Content -LiteralPath $AckFile -ErrorAction SilentlyContinue)) {
        $text = $line.Trim()
        if (!$text) { continue }
        try {
            $ack = $text | ConvertFrom-Json
            $commandId = [string]$ack.command_id
            $status = [string]$ack.status
            $key = "$commandId|$status|$($ack.time_msc)"
            if (!$commandId -or $AckSent.ContainsKey($key)) { continue }
            [void]$acks.Add([pscustomobject]@{ Id = $key; Ack = $ack })
        } catch {
            Write-BridgeLog "bad ack skipped: $($_.Exception.Message)"
        }
    }
    return $acks
}

function Post-Acks {
    $items = @(Read-Acks)
    if ($items.Count -eq 0) { return }
    $acks = @()
    $ids = @()
    foreach ($item in $items) {
        $acks += $item.Ack
        $ids += $item.Id
    }
    $payload = @{ executor_id = $ExecutorId; acks = $acks } | ConvertTo-Json -Depth 12 -Compress
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "$ApiUrl/api/execution/acks" -Headers (Headers) -Body $payload -ContentType "application/json" -TimeoutSec 15
        Add-Set $AckSentFile $ids $AckSent
        Write-BridgeLog "posted $($ids.Count) ack(s), accepted=$($resp.accepted)"
    } catch {
        Write-BridgeLog "ack post failed: $($_.Exception.Message)"
    }
}

New-Item -ItemType Directory -Force -Path $CommonDir | Out-Null
Load-Set $SourceSentFile $SourceSent
Load-Set $AckSentFile $AckSent
Write-BridgeLog "Forex MT5 bridge agent started. ApiUrl=$ApiUrl ExecutorId=$ExecutorId CommonDir=$CommonDir"

while ($true) {
    try {
        $rows = @(Read-SourceRows)
        if ($rows.Count -gt 0) {
            foreach ($group in ($rows | Group-Object SourceId)) {
                Post-SourceGroup $group.Name @($group.Group)
            }
        }
        Pull-Commands
        Post-Acks
    } catch {
        Write-BridgeLog "loop error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds ([Math]::Max(1, $IntervalSeconds))
}
