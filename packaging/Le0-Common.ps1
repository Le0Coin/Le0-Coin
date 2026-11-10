# Shared Le0 node helpers. No extra installs.
$ErrorActionPreference = "Stop"

function Get-Le0Rpc {
    param(
        [Parameter(Mandatory)][string]$Method,
        [object[]]$Params = @(),
        [int]$Port = 28443,
        [string]$Wallet = "",
        [string]$User = "le0",
        [string]$Pass = "le0pass",
        [int]$TimeoutSec = 8
    )
    $uri = "http://127.0.0.1:$Port/"
    if ($Wallet) { $uri += "wallet/" + [uri]::EscapeDataString($Wallet) }
    $payload = @{ jsonrpc = "1.0"; id = "le0"; method = $Method; params = @($Params) } | ConvertTo-Json -Compress -Depth 6
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}"))
    return Invoke-RestMethod -Uri $uri -Method Post -Body $payload -ContentType "application/json" -Headers @{ Authorization = "Basic $auth" } -TimeoutSec $TimeoutSec
}

function Get-Le0NetworkId {
    param([string]$Root = $script:Le0Root)
    $n = 1
    try {
        if (-not $Root) { $Root = Split-Path -Parent $PSCommandPath }
        $f = Join-Path $Root "network.id"
        if (Test-Path $f) {
            $raw = (Get-Content $f -TotalCount 1).Trim()
            if ($raw -match '^\d+$') { $n = [int]$raw }
        }
    } catch {}
    return $n
}

function Get-Le0NetworkTag {
    param([string]$Root = $script:Le0Root)
    return "le0net$(Get-Le0NetworkId -Root $Root)"
}

function Test-Le0NetworkPeer {
    param($Peer, [string]$Root = $script:Le0Root)
    if ($null -eq $Peer) { return $false }
    $tag = Get-Le0NetworkTag -Root $Root
    $sub = [string]$Peer.subver
    $alive = ([int64]$Peer.bytesrecv -gt 0) -or ([int]$Peer.version -gt 0) -or (-not [string]::IsNullOrWhiteSpace($sub))
    return $alive -and ($sub -like "*${tag}*")
}

# Live peers that also match this release's network.id (old zips lack the tag).
function Get-Le0LivePeerCount {
    param([int]$Port = 28443, [string]$Root = $script:Le0Root)
    try {
        $peers = @((Get-Le0Rpc -Method "getpeerinfo" -Port $Port).result)
        return @($peers | Where-Object { Test-Le0NetworkPeer -Peer $_ -Root $Root }).Count
    } catch {
        return 0
    }
}

# Host: drop miners still on an old Discord zip after you bump network.id.
# Disconnect only — never IP-ban. Real miners must always be able to come back on a new zip.
function Protect-Le0NetworkPeers {
    param([int]$Port = 28443, [string]$Root = $script:Le0Root)
    try {
        $tag = Get-Le0NetworkTag -Root $Root
        $peers = @((Get-Le0Rpc -Method "getpeerinfo" -Port $Port).result)
        foreach ($p in $peers) {
            if ($null -eq $p) { continue }
            $sub = [string]$p.subver
            # Still handshaking — leave them alone.
            if ([int]$p.version -le 0 -or [string]::IsNullOrWhiteSpace($sub)) { continue }
            if ($sub -like "*${tag}*") { continue }
            try { Get-Le0Rpc -Method "disconnectnode" -Params @([string]$p.addr) -Port $Port | Out-Null } catch {}
        }
    } catch {}
}

function Update-Le0DuckDns {
    $cfg = Join-Path $env:LOCALAPPDATA "Le0-seed\dns.json"
    if (-not (Test-Path $cfg)) { return $null }
    try {
        $j = Get-Content $cfg -Raw | ConvertFrom-Json
        if (-not $j.domain -or -not $j.token) { return $null }
        $url = "https://www.duckdns.org/update?domains=$([uri]::EscapeDataString([string]$j.domain))&token=$([uri]::EscapeDataString([string]$j.token))&ip="
        $resp = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 12).Content.Trim()
        if ($resp -ne "OK") { return $null }
        return "$($j.domain).duckdns.org"
    } catch {
        return $null
    }
}

function Get-Le0PublicSeedHost {
    param([string]$Root = $script:Le0Root)
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA "Le0-seed\seed-host.txt"),
        (Join-Path $Root "seed-host.txt")
    )) {
        if (Test-Path $p) {
            $h = (Get-Content $p -TotalCount 1).Trim()
            if ($h) { return $h }
        }
    }
    return $null
}

function Get-Le0ExplorerConfig {
    $cfgPath = Join-Path $env:LOCALAPPDATA "Le0-seed\explorer.json"
    if (-not (Test-Path $cfgPath)) { return $null }
    try { return Get-Content $cfgPath -Raw | ConvertFrom-Json } catch { return $null }
}

# Snapshot for the public explorer (no IPs / RPC secrets).
function Get-Le0ChainSnapshot {
    param([int]$Port = 28443, [int]$Count = 30)
    $info = (Get-Le0Rpc -Method "getblockchaininfo" -Port $Port).result
    $height = [int]$info.blocks
    $blocks = @()
    $from = [Math]::Max(0, $height - $Count + 1)
    for ($h = $height; $h -ge $from; $h--) {
        try {
            $hash = (Get-Le0Rpc -Method "getblockhash" -Params @($h) -Port $Port).result
            $blk = (Get-Le0Rpc -Method "getblock" -Params @($hash, 1) -Port $Port).result
            $blocks += [ordered]@{
                height = [int]$blk.height
                hash   = [string]$blk.hash
                time   = [int64]$blk.time
                nTx    = @($blk.tx).Count
                size   = [int]$blk.size
            }
        } catch {}
    }
    return [ordered]@{
        updatedAt = (Get-Date).ToUniversalTime().ToString("o")
        height    = $height
        bestHash  = [string]$info.bestblockhash
        chain     = [string]$info.chain
        blocks    = $blocks
    }
}

function Publish-Le0ChainSnapshot {
    param([int]$Port = 28443)
    $cfg = Get-Le0ExplorerConfig
    if (-not $cfg -or -not $cfg.url -or -not $cfg.secret) { return $false }
    try {
        $snap = Get-Le0ChainSnapshot -Port $Port
        $json = $snap | ConvertTo-Json -Depth 6 -Compress
        Invoke-RestMethod -Method Post -Uri ([string]$cfg.url) -Headers @{
            Authorization = "Bearer $($cfg.secret)"
            "Content-Type" = "application/json"
        } -Body $json -TimeoutSec 20 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-Le0IconPath {
    param([string]$Root = $script:Le0Root)
    if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.PSCommandPath }
    foreach ($name in @("le0.ico", "le0.png")) {
        $p = Join-Path $Root $name
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Set-Le0WindowIcon {
    param($Window, [string]$Root = $script:Le0Root)
    try {
        $ico = Get-Le0IconPath -Root $Root
        if (-not $ico -or -not $Window) { return }
        $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$ico)
    } catch {}
}

# Keep the hashrate terminal visible, but remove its close button so closing it
# cannot kill mining. Hide the old stock Qt wallet window — the new Le0 UI is the wallet.
function Update-Le0Windows {
    if (-not ("Le0Win32" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Le0Win32 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern IntPtr GetSystemMenu(IntPtr h, bool revert);
  [DllImport("user32.dll")] public static extern bool DeleteMenu(IntPtr h, uint pos, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr LoadImage(IntPtr hInst, string name, uint type, int cx, int cy, uint fuLoad);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@
    }
    try {
    $targets = @(Get-Process -Name "le0-qt" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    if (-not $targets) { return }
    $iconBig = [IntPtr]::Zero
    $iconSmall = [IntPtr]::Zero
    $icoPath = Get-Le0IconPath
    if ($icoPath -and ($icoPath -like "*.ico")) {
        $iconBig = [Le0Win32]::LoadImage([IntPtr]::Zero, $icoPath, 1, 32, 32, 0x10)
        $iconSmall = [Le0Win32]::LoadImage([IntPtr]::Zero, $icoPath, 1, 16, 16, 0x10)
    }
    $sb = New-Object System.Text.StringBuilder 512
    $callback = [Le0Win32+EnumProc]{
        param($h, $l)
        [uint32]$winPid = 0
        [void][Le0Win32]::GetWindowThreadProcessId($h, [ref]$winPid)
        if ($targets -notcontains [int]$winPid) { return $true }
        [void]$sb.Clear()
        [void][Le0Win32]::GetWindowText($h, $sb, $sb.Capacity)
        $title = $sb.ToString()
        if ([string]::IsNullOrWhiteSpace($title)) { return $true }
        if ($title -like "Le0 Miner*") {
            $menu = [Le0Win32]::GetSystemMenu($h, $false)
            if ($menu -ne [IntPtr]::Zero) { [void][Le0Win32]::DeleteMenu($menu, 0xF060, 0x0000) }
            [void][Le0Win32]::ShowWindow($h, 5) # show hashrate terminal
            if ($iconBig -ne [IntPtr]::Zero) {
                [void][Le0Win32]::SendMessage($h, 0x80, [IntPtr]1, $iconBig)   # WM_SETICON ICON_BIG
                [void][Le0Win32]::SendMessage($h, 0x80, [IntPtr]0, $iconSmall) # WM_SETICON ICON_SMALL
            }
        } elseif ($title -like "Le0*" -or $title -like "*Wallet*" -or $title -like "Bitcoin*") {
            [void][Le0Win32]::ShowWindow($h, 0) # hide old stock wallet UI
        }
        return $true
    }
    [void][Le0Win32]::EnumWindows($callback, [IntPtr]::Zero)
    } catch {}
}

function Write-Le0Conf {
    param([string]$DataDir, [int]$Port, [int]$RpcPort, [string]$WalletDir, [string[]]$AddNodes, [string]$UaComment = "")
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $lines = @(
        "server=1",
        "listen=1",
        "dnsseed=0",
        "fixedseeds=0",
        "upnp=0",
        "natpmp=0",
        "v2transport=0",
        "port=$Port",
        "rpcport=$RpcPort",
        "rpcuser=le0",
        "rpcpassword=le0pass",
        "rpcallowip=127.0.0.1",
        "fallbackfee=0.0002"
    )
    if ($UaComment) { $lines += "uacomment=$UaComment" }
    if ($WalletDir) { $lines += ("walletdir=" + ($WalletDir -replace '\\','/')) }
    foreach ($n in $AddNodes) {
        if ($n) { $lines += "addnode=$n" }
    }
    Set-Content -Path (Join-Path $DataDir "le0.conf") -Value $lines -Encoding ASCII
}

function Start-Le0Qt {
    param(
        [string]$Qt,
        [string]$DataDir,
        [string]$WalletDir,
        [int]$Port,
        [int]$RpcPort,
        [string[]]$AddNodes = @(),
        [string]$MineAddress = "",
        [switch]$DisableWallet,
        [string]$Root = $script:Le0Root
    )
    $tag = Get-Le0NetworkTag -Root $Root
    Write-Le0Conf -DataDir $DataDir -Port $Port -RpcPort $RpcPort -WalletDir $WalletDir -AddNodes $AddNodes -UaComment $tag
    $args = @(
        "-datadir=$DataDir",
        "-server=1",
        "-listen=1",
        "-port=$Port",
        "-rpcport=$RpcPort",
        "-rpcuser=le0",
        "-rpcpassword=le0pass",
        "-rpcallowip=127.0.0.1",
        "-dnsseed=0",
        "-fixedseeds=0",
        "-upnp=0",
        "-natpmp=0",
        "-v2transport=0",
        "-uacomment=$tag",
        "-printtoconsole=0",
        "-splash=0",
        "-min"
    )
    if ($WalletDir -and -not $DisableWallet) { $args += "-walletdir=$WalletDir" }
    if ($DisableWallet) { $args += "-disablewallet" }
    foreach ($n in $AddNodes) { if ($n) { $args += "-addnode=$n" } }
    if ($MineAddress) { $args += "-mineaddress=$MineAddress" }
    $quoted = foreach ($a in $args) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"','\"') + '"' } else { $a }
    }
    Start-Process -FilePath $Qt -ArgumentList ($quoted -join ' ') -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 80
        try { Update-Le0Windows } catch {}
    }
}

function Stop-Le0Rpc {
    param([int]$Port = 28443)
    try { Get-Le0Rpc -Method "stop" -Port $Port -TimeoutSec 4 | Out-Null } catch {}
}

function Wait-Le0Rpc {
    param([int]$Port = 28443, [int]$Seconds = 90)
    for ($i = 0; $i -lt $Seconds; $i++) {
        try {
            $r = Get-Le0Rpc -Method "getblockcount" -Port $Port -TimeoutSec 3
            return [int]$r.result
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    throw "Le0 did not answer RPC on port $Port"
}

function Read-SeedList {
    param([string]$Path)
    $list = @()
    if (-not (Test-Path $Path)) { return $list }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) { $list += $line }
    }
    return $list
}
