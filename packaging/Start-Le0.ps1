# Le0 one-click: persistent wallet + solo mine
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Qt = Join-Path $Root "le0-qt.exe"
$Cli = Join-Path $Root "le0-cli.exe"
if (-not (Test-Path $Qt)) { throw "le0-qt.exe missing - put binaries next to this script." }

$DataDir = Join-Path $env:LOCALAPPDATA "Le0"
$WalletDir = Join-Path $env:LOCALAPPDATA "Le0-wallets"
$AddrFile = Join-Path $WalletDir "mining-address.txt"
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $WalletDir | Out-Null

function Get-Le0WalletName {
    $dirs = @(Get-ChildItem -Path $WalletDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "wallet.dat") } |
        Select-Object -ExpandProperty Name)
    if ($dirs -contains "Leo's Le0 Wallet") { return "Leo's Le0 Wallet" }
    if ($dirs -contains "main") { return "main" }
    if ($dirs.Count -gt 0) { return $dirs[0] }
    return $null
}

# Quote args so names with spaces (e.g. Leo's Le0 Wallet) stay one token
function Start-Le0Process {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [switch]$PassThru
    )
    $quoted = foreach ($a in $Arguments) {
        if ($null -eq $a) { continue }
        if ($a -match '[\s"]') {
            '"' + ($a -replace '"', '\"') + '"'
        } else {
            $a
        }
    }
    $argLine = [string]::Join(' ', $quoted)
    if ($PassThru) {
        return Start-Process -FilePath $FilePath -ArgumentList $argLine -PassThru
    }
    Start-Process -FilePath $FilePath -ArgumentList $argLine | Out-Null
}

$SeedArgs = @()
$SeedFile = Join-Path $Root "seeds.txt"
if (Test-Path $SeedFile) {
    Get-Content $SeedFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) { $SeedArgs += "-addnode=$line" }
    }
}

$SavedAddr = ""
if (Test-Path $AddrFile) {
    $SavedAddr = (Get-Content $AddrFile -Raw).Trim()
}

# Only one instance can hold the datadir lock
$existing = @(Get-Process -Name "le0-qt" -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) {
    Write-Host "Closing already-running Le0..."
    $existing | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host "  Le0 starter"
Write-Host "  -----------"
Write-Host "  Wallet saved at: $WalletDir"
Write-Host ""
if ($SavedAddr) {
    Write-Host "  Last mining address: $SavedAddr"
    Write-Host "  Press Enter to keep it, or paste a different address."
} else {
    Write-Host "  Press Enter to create/use your saved wallet address,"
    Write-Host "  or paste an L... / le0... address."
}
Write-Host ""
$Address = (Read-Host "Mining address").Trim()
if (-not $Address -and $SavedAddr) { $Address = $SavedAddr }

$RpcPort = 28443
$RpcUser = "le0"
$RpcPass = "le0pass"
$WalletName = Get-Le0WalletName

# Wallet name only in settings.json (not conf + settings — that triggers duplicate -wallet)
$confLines = @(
    "server=1",
    "listen=1",
    "port=37070",
    "rpcport=$RpcPort",
    "rpcuser=$RpcUser",
    "rpcpassword=$RpcPass",
    "fallbackfee=0.0002",
    ("walletdir=" + ($WalletDir -replace '\\', '/'))
)
$confLines | Set-Content -Path (Join-Path $DataDir "le0.conf") -Encoding ASCII

$settingsPath = Join-Path $DataDir "settings.json"
if ($WalletName) {
    $escaped = $WalletName.Replace('\', '\\').Replace('"', '\"')
    $settingsObj = '{ "wallet": [ "' + $escaped + '" ] }'
} else {
    $settingsObj = '{ "wallet": [ ] }'
}
Set-Content -Path $settingsPath -Value $settingsObj -Encoding ASCII

$base = @(
    "-datadir=$DataDir",
    "-walletdir=$WalletDir",
    "-server=1",
    "-rpcport=$RpcPort",
    "-rpcuser=$RpcUser",
    "-rpcpassword=$RpcPass"
) + $SeedArgs

function Wait-Rpc {
    $c = @("-datadir=$DataDir", "-rpcport=$RpcPort", "-rpcuser=$RpcUser", "-rpcpassword=$RpcPass")
    for ($i = 0; $i -lt 90; $i++) {
        & $Cli @c getblockchaininfo 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Ensure-WalletAndAddress {
    param([string]$Preferred)
    $c = @("-datadir=$DataDir", "-rpcport=$RpcPort", "-rpcuser=$RpcUser", "-rpcpassword=$RpcPass")
    $name = Get-Le0WalletName
    if (-not $name) {
        $name = "main"
        Write-Host "Creating persistent wallet '$name'..."
        & $Cli @c createwallet $name 1>$null 2>$null
    } else {
        & $Cli @c loadwallet $name 1>$null 2>$null
    }
    $script:WalletName = $name
    if ($Preferred) { return $Preferred }
    $addr = ((& $Cli @c "-rpcwallet=$name" getnewaddress) | Out-String).Trim()
    return $addr
}

$needBootstrap = [string]::IsNullOrWhiteSpace($Address) -or -not $WalletName
if ($needBootstrap -and [string]::IsNullOrWhiteSpace($Address)) {
    Write-Host "Starting Le0 to prepare your saved wallet..."
    $p = Start-Le0Process -FilePath $Qt -Arguments $base -PassThru
    if (-not (Wait-Rpc)) {
        Write-Host "GUI started. Re-run Start-Le0.bat after it finishes loading."
        exit 0
    }
    $Address = Ensure-WalletAndAddress -Preferred ""
    if (-not $Address) { throw "Could not get an address from the wallet." }
    Set-Content -Path $AddrFile -Value $Address -Encoding ASCII
    Write-Host "Saved mining address: $Address"
    Write-Host "Restarting with mining on..."
    & $Cli @("-datadir=$DataDir", "-rpcport=$RpcPort", "-rpcuser=$RpcUser", "-rpcpassword=$RpcPass") stop 1>$null 2>$null
    Start-Sleep -Seconds 4
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    $WalletName = Get-Le0WalletName
    if ($WalletName) {
        $escaped = $WalletName.Replace('\', '\\').Replace('"', '\"')
        Set-Content -Path $settingsPath -Value ('{ "wallet": [ "' + $escaped + '" ] }') -Encoding ASCII
    }
    $base = @(
        "-datadir=$DataDir",
        "-walletdir=$WalletDir",
        "-server=1",
        "-rpcport=$RpcPort",
        "-rpcuser=$RpcUser",
        "-rpcpassword=$RpcPass"
    ) + $SeedArgs
} elseif ($Address) {
    Set-Content -Path $AddrFile -Value $Address -Encoding ASCII
}

Write-Host "Starting Le0 - mining to $Address"
if ($WalletName) { Write-Host "Wallet: $WalletName" }
Write-Host "Wallet auto-loads from $WalletDir"
$mineArgs = $base + @("-mineaddress=$Address", "-printtoconsole=0")
Start-Le0Process -FilePath $Qt -Arguments $mineArgs
Start-Sleep -Seconds 3
