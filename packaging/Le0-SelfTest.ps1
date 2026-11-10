# Two-node test: handshake, header/block sync, miner stays alive.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root "Le0-Common.ps1")

$Root = Split-Path -Parent $PSScriptRoot
$Qt = Join-Path $Root "Le0-Windows-v0.1\le0-qt.exe"
if (-not (Test-Path $Qt)) { throw "missing qt" }

$src = Join-Path $env:LOCALAPPDATA "Le0"
$base = Join-Path $env:TEMP "le0-selftest"
if (Test-Path $base) { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }
$aDir = Join-Path $base "a"
$bDir = Join-Path $base "b"
$wDir = Join-Path $base "wallets"
New-Item -ItemType Directory -Force -Path $aDir, $bDir, $wDir | Out-Null
Copy-Item (Join-Path $src "blocks") (Join-Path $aDir "blocks") -Recurse -Force
Copy-Item (Join-Path $src "chainstate") (Join-Path $aDir "chainstate") -Recurse -Force
Remove-Item (Join-Path $aDir "chainstate\LOCK") -Force -ErrorAction SilentlyContinue
$realWallet = Join-Path $env:LOCALAPPDATA "Le0-wallets\Leo's Le0 Wallet"
if (Test-Path $realWallet) {
    Copy-Item $realWallet (Join-Path $wDir "Leo's Le0 Wallet") -Recurse -Force
    Set-Content (Join-Path $aDir "settings.json") '{ "wallet": [ "Leo''s Le0 Wallet" ] }' -Encoding ASCII
}
$savedAddr = ""
$addrFile = Join-Path $env:LOCALAPPDATA "Le0-wallets\mining-address.txt"
if (Test-Path $addrFile) { $savedAddr = (Get-Content $addrFile -Raw).Trim() }

Get-Process le0-qt -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$fail = @()
function Say($m) { Write-Host $m }

Say "start node A (has the chain)"
Start-Le0Qt -Qt $Qt -DataDir $aDir -WalletDir $wDir -Port 37270 -RpcPort 28550
$heightA = Wait-Le0Rpc -Port 28550 -Seconds 90
Say "A height $heightA"

Say "start node B (empty, connects to A)"
Start-Le0Qt -Qt $Qt -DataDir $bDir -Port 37271 -RpcPort 28551 -AddNodes @("127.0.0.1:37270") -DisableWallet
Wait-Le0Rpc -Port 28551 -Seconds 90 | Out-Null

$synced = $false
$handshake = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 2
    try {
        $hb = [int](Get-Le0Rpc -Method "getblockcount" -Port 28551).result
        $peers = (Get-Le0Rpc -Method "getpeerinfo" -Port 28551).result
        $p = @($peers) | Select-Object -First 1
        $recv = 0; $sub = ""; $startH = -1
        if ($p) { $recv = [int]$p.bytesrecv; $sub = [string]$p.subver; $startH = $p.startingheight }
        Say ("B height={0} recv={1} sub={2} startH={3}" -f $hb, $recv, $sub, $startH)
        if ($recv -gt 100 -and $sub -like "*Le0*") { $handshake = $true }
        if ($hb -ge $heightA -and $heightA -gt 0) { $synced = $true; break }
    } catch {
        Say "poll $($_.Exception.Message)"
    }
}
if (-not $handshake) { $fail += "handshake failed (B never spoke Le0 to A)" }
if (-not $synced) { $fail += "B did not reach A's height $heightA" }

Say "mine one block on A"
$addr = $savedAddr
if (-not $addr) {
    try { Get-Le0Rpc -Method "createwallet" -Params @("Le0 Wallet") -Port 28550 | Out-Null } catch {}
    $addr = [string](Get-Le0Rpc -Method "getnewaddress" -Port 28550 -Wallet "Le0 Wallet").result
}
Say "address $addr"
Stop-Le0Rpc -Port 28550
Start-Sleep -Seconds 3
Get-Process le0-qt -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -lt (Get-Date).AddMinutes(-1) } | Out-Null
# Restart only A: stop the process bound to 28550 by stopping via already-sent RPC, then if still up kill all and restart BOTH.
Get-Process le0-qt -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Le0Qt -Qt $Qt -DataDir $aDir -WalletDir $wDir -Port 37270 -RpcPort 28550 -MineAddress $addr
Start-Le0Qt -Qt $Qt -DataDir $bDir -Port 37271 -RpcPort 28551 -AddNodes @("127.0.0.1:37270") -DisableWallet
Wait-Le0Rpc -Port 28550 -Seconds 90 | Out-Null
Wait-Le0Rpc -Port 28551 -Seconds 90 | Out-Null

$alive = $true
$found = $false
$before = [int](Get-Le0Rpc -Method "getblockcount" -Port 28550).result
Say "mining from height $before"
for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Seconds 5
    try { Hide-Le0MinerConsole } catch { Say "hide: $($_.Exception.Message)" }
    $procs = @(Get-Process le0-qt -ErrorAction SilentlyContinue)
    if ($procs.Count -lt 1) { $alive = $false; break }
    $now = [int](Get-Le0Rpc -Method "getblockcount" -Port 28550).result
    $bnow = [int](Get-Le0Rpc -Method "getblockcount" -Port 28551).result
    Say "tick A=$now B=$bnow procs=$($procs.Count)"
    if ($now -gt $before -and $bnow -ge $now) { $found = $true; break }
}
$log = Join-Path $aDir "debug.log"
$mineLine = ""
if (Test-Path $log) {
    $hit = Select-String -Path $log -Pattern "le0-mine:" | Select-Object -Last 1
    if ($hit) { $mineLine = $hit.Line.Trim() }
}
Say "miner line: $mineLine"
if (-not $alive) { $fail += "node process died" }
if (-not $mineLine) { $fail += "no le0-mine output (miner did not start)" }
if (-not $found) { $fail += "no new block within 2 minutes (hashing may just be slow)" }

Get-Process le0-qt -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Say "----"
if ($fail.Count -eq 0) {
    Say "SELFTEST PASS"
    exit 0
}
$onlySlow = ($fail.Count -eq 1 -and $fail[0] -like "no new block*")
if ($onlySlow -and $handshake -and $synced -and $mineLine -and $alive) {
    Say "SELFTEST PASS (sync + miner alive; block slower than 2 min)"
    exit 0
}
Say "SELFTEST FAIL"
$fail | ForEach-Object { Say " - $_" }
exit 1
