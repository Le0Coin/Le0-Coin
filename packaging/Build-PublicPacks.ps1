# Build separate public Wallet and Miner zips from this packaging folder + binaries.
# Run on the build PC after le0-qt.exe (and friends) are next to these scripts.
param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "dist")
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$required = @("le0-qt.exe", "Le0-Wallet.ps1", "Le0-Common.ps1", "Le0-Account.ps1", "seeds.txt", "network.id")
foreach ($f in $required) {
    if (-not (Test-Path (Join-Path $Root $f))) {
        throw "Missing $f in packaging folder. Copy release binaries here first."
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd"

$shared = @(
    "le0-qt.exe",
    "le0-cli.exe",
    "le0.ico",
    "le0.png",
    "seeds.txt",
    "network.id",
    "bip39-english.txt",
    "Le0-Wallet.ps1",
    "Le0-Common.ps1",
    "Le0-Account.ps1",
    "Le0Keys.cs",
    "lib"
)

function New-Le0Pack {
    param([string]$Name, [string[]]$ExtraFiles, [string]$ReadmeSource)
    $stage = Join-Path $OutDir $Name
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    foreach ($item in $shared) {
        $src = Join-Path $Root $item
        if (-not (Test-Path $src)) { continue }
        $dest = Join-Path $stage $item
        if (Test-Path $src -PathType Container) {
            Copy-Item $src $dest -Recurse -Force
        } else {
            Copy-Item $src $dest -Force
        }
    }
    foreach ($item in $ExtraFiles) {
        $src = Join-Path $Root $item
        if (Test-Path $src) { Copy-Item $src (Join-Path $stage $item) -Force }
    }
    Copy-Item (Join-Path $Root $ReadmeSource) (Join-Path $stage "README.txt") -Force
    $zip = Join-Path $OutDir ("$Name-$stamp.zip")
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -Force
    Write-Host "Built $zip"
}

New-Le0Pack -Name "Le0-Wallet" -ReadmeSource "README-WALLET.txt" -ExtraFiles @(
    "Start-Le0-Wallet.bat",
    "Start-Le0-Wallet.vbs"
)

New-Le0Pack -Name "Le0-Miner" -ReadmeSource "README-MINER.txt" -ExtraFiles @(
    "Start-Le0-Miner.bat",
    "Start-Le0-Miner.vbs",
    "Start-Le0.bat",
    "Start-Le0.vbs"
)

Write-Host ""
Write-Host "Upload both zips to Drive, then paste the links into site/config.js"
Write-Host "  downloadWallet: ..."
Write-Host "  downloadMiner:  ..."
