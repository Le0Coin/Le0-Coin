# Le0 wallet (+ optional miner). Mining only runs with a wallet address + live peers.
# -NoMine = wallet pack (send/receive only). Miner pack omits -NoMine.
param(
    [switch]$SelfTest,
    [switch]$NoMine
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Le0Root = $Root
. (Join-Path $Root "Le0-Common.ps1")
. (Join-Path $Root "Le0-Account.ps1")
Initialize-Le0Keys -Root $Root

$Qt = Join-Path $Root "le0-qt.exe"
$DataDir = Join-Path $env:LOCALAPPDATA "Le0"
$WalletDir = Join-Path $env:LOCALAPPDATA "Le0-wallets"
$AddrFile = Join-Path $WalletDir "mining-address.txt"
$Rpc = 28443
$Port = 37070
$script:AllowMine = -not $NoMine

function Get-WalletNames {
    @(Get-ChildItem -Path $WalletDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "wallet.dat") } |
        Select-Object -ExpandProperty Name)
}

function Select-WalletName {
    $acct = Join-Path $WalletDir "account.json"
    if (Test-Path $acct) {
        try {
            $j = Get-Content $acct -Raw | ConvertFrom-Json
            if ($j.wallet) { return [string]$j.wallet }
        } catch {}
    }
    $names = @(Get-WalletNames)
    if ($names -contains "Account") { return "Account" }
    if ($names -contains "Le0 Wallet") { return "Le0 Wallet" }
    return $null
}

function Save-WalletSettings([string]$Name) {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    if ($Name) {
        $escaped = $Name.Replace('\','\\').Replace('"','\"')
        Set-Content (Join-Path $DataDir "settings.json") ("{ `"wallet`": [ `"$escaped`" ] }") -Encoding ASCII
    } else {
        Set-Content (Join-Path $DataDir "settings.json") '{ "wallet": [ ] }' -Encoding ASCII
    }
}

function Read-Seeds {
    Read-SeedList (Join-Path $Root "seeds.txt")
}

function Stop-WalletNode {
    try { Stop-Le0Rpc -Port $Rpc } catch {}
    Start-Sleep -Seconds 2
    Get-Process -Name "le0-qt" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

function Start-WalletNode {
    param([string]$MineTo)
    $seeds = @(Read-Seeds)
    $walletName = Select-WalletName
    Save-WalletSettings $walletName
    Start-Le0Qt -Qt $Qt -DataDir $DataDir -WalletDir $WalletDir -Port $Port -RpcPort $Rpc -AddNodes $seeds -MineAddress $MineTo -Root $Root
}

if ($SelfTest) {
    & (Join-Path $Root "Le0-SelfTest.ps1")
    exit $LASTEXITCODE
}

if (-not (Test-Path $Qt)) { throw "le0-qt.exe is missing next to this script." }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path $WalletDir | Out-Null

Add-Type -AssemblyName PresentationFramework
$script:Le0Gate = Show-Le0LoginGate -WalletDir $WalletDir
if (-not $script:Le0Gate) { exit 0 }
$script:SessionUser = [string]$script:Le0Gate.Username
$script:SessionPassword = [string]$script:Le0Gate.Password

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Le0" Height="680" Width="980"
        WindowStartupLocation="CenterScreen" Background="#101114">
  <Grid Margin="22">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="320"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>
    <StackPanel>
      <TextBlock Text="Le0" Foreground="#F4F7FB" FontSize="36" FontWeight="Bold"/>
      <TextBlock x:Name="NetStatus" Text="Starting node..." Margin="0,4,0,16" Foreground="#E6C36A" FontSize="14"/>
      <Border Background="#1C2128" CornerRadius="14" Padding="18" Margin="0,0,18,12">
        <StackPanel>
          <TextBlock Text="AVAILABLE" Foreground="#8B95A1" FontSize="11"/>
          <TextBlock x:Name="Bal" Text="0.00000000" Foreground="#7CFFB2" FontSize="28" FontWeight="SemiBold" Margin="0,4,0,0"/>
          <TextBlock Text="LE0" Foreground="#8B95A1" FontSize="13"/>
          <TextBlock x:Name="Extra" Margin="0,12,0,0" Foreground="#C5CDD6" FontSize="13" TextWrapping="Wrap"/>
        </StackPanel>
      </Border>
      <Border Background="#1C2128" CornerRadius="14" Padding="18" Margin="0,0,18,0">
        <StackPanel>
          <TextBlock x:Name="HeightText" Foreground="#F4F7FB" FontSize="15"/>
          <TextBlock x:Name="PeerText" Margin="0,6,0,0" Foreground="#F4F7FB" FontSize="15"/>
          <TextBlock x:Name="MineText" Margin="0,6,0,0" Foreground="#F4F7FB" FontSize="15" TextWrapping="Wrap"/>
          <TextBlock x:Name="RateText" Margin="0,6,0,0" Foreground="#8B95A1" FontSize="13" TextWrapping="Wrap"/>
        </StackPanel>
      </Border>
    </StackPanel>
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <StackPanel Orientation="Horizontal" Margin="0,8,0,12">
        <Button x:Name="TabActivity" Content="Activity" Margin="0,0,8,0" Padding="16,8"/>
        <Button x:Name="TabSend" Content="Send" Margin="0,0,8,0" Padding="16,8"/>
        <Button x:Name="TabReceive" Content="Receive" Margin="0,0,8,0" Padding="16,8"/>
        <Button x:Name="TabAccount" Content="Account" Padding="16,8"/>
      </StackPanel>
      <Border x:Name="PageActivity" Grid.Row="1" Background="#1C2128" CornerRadius="14" Padding="16">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="Recent activity" Foreground="#F4F7FB" FontSize="18" Margin="0,0,0,10"/>
          <ListBox x:Name="TxList" Background="#1C2128" Foreground="#F4F7FB" BorderThickness="0" FontSize="14"/>
        </DockPanel>
      </Border>
      <Border x:Name="PageSend" Grid.Row="1" Background="#1C2128" CornerRadius="14" Padding="16" Visibility="Collapsed">
        <StackPanel>
          <TextBlock Text="Send LE0" Foreground="#F4F7FB" FontSize="18" Margin="0,0,0,12"/>
          <TextBlock Text="Address" Foreground="#8B95A1"/>
          <TextBox x:Name="SendAddr" Margin="0,4,0,10" Padding="8" FontSize="14"/>
          <TextBlock Text="Amount" Foreground="#8B95A1"/>
          <TextBox x:Name="SendAmt" Margin="0,4,0,14" Padding="8" FontSize="14"/>
          <Button x:Name="SendBtn" Content="Send" Padding="16,8" HorizontalAlignment="Left"/>
          <TextBlock x:Name="SendResult" Margin="0,12,0,0" Foreground="#C5CDD6" TextWrapping="Wrap"/>
        </StackPanel>
      </Border>
      <Border x:Name="PageReceive" Grid.Row="1" Background="#1C2128" CornerRadius="14" Padding="16" Visibility="Collapsed">
        <StackPanel>
          <TextBlock Text="Your address" Foreground="#F4F7FB" FontSize="18" Margin="0,0,0,12"/>
          <TextBox x:Name="RecvAddr" IsReadOnly="True" Padding="8" FontSize="14" TextWrapping="Wrap"/>
          <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
            <Button x:Name="CopyBtn" Content="Copy" Padding="16,8" Margin="0,0,8,0"/>
            <Button x:Name="NewAddrBtn" Content="New address" Padding="16,8"/>
          </StackPanel>
        </StackPanel>
      </Border>
      <Border x:Name="PageAccount" Grid.Row="1" Background="#1C2128" CornerRadius="14" Padding="16" Visibility="Collapsed">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock Text="Account" Foreground="#F4F7FB" FontSize="18" Margin="0,0,0,8"/>
            <TextBlock x:Name="AccountWho" Foreground="#7CFFB2" Margin="0,0,0,10"/>
            <TextBlock TextWrapping="Wrap" Foreground="#8B95A1" Margin="0,0,0,12" Text="You sign in with your username and password every time this opens. Forgotten password asks for your seed phrase, and that phrase only works for this account."/>
            <Button x:Name="ShowSeedBtn" Content="Show my seed" Padding="14,8" HorizontalAlignment="Left"/>
            <TextBox x:Name="SeedBox" Margin="0,12,0,0" Padding="8" TextWrapping="Wrap" IsReadOnly="True" MinHeight="64"/>
            <TextBlock x:Name="AccountStatus" Margin="0,12,0,0" Foreground="#C5CDD6" TextWrapping="Wrap"/>
          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>
  </Grid>
</Window>
"@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
if (-not $script:AllowMine) { $win.Title = "Le0 Wallet" }
Set-Le0WindowIcon -Window $win -Root $Root
$NetStatus = $win.FindName("NetStatus")
$Bal = $win.FindName("Bal")
$Extra = $win.FindName("Extra")
$HeightText = $win.FindName("HeightText")
$PeerText = $win.FindName("PeerText")
$MineText = $win.FindName("MineText")
$RateText = $win.FindName("RateText")
$TxList = $win.FindName("TxList")
$SendAddr = $win.FindName("SendAddr")
$SendAmt = $win.FindName("SendAmt")
$SendResult = $win.FindName("SendResult")
$RecvAddr = $win.FindName("RecvAddr")

function Show-Page([string]$name) {
    foreach ($p in @("PageActivity","PageSend","PageReceive","PageAccount")) {
        $win.FindName($p).Visibility = $(if ($p -eq $name) { "Visible" } else { "Collapsed" })
    }
}
$win.FindName("TabActivity").Add_Click({ Show-Page "PageActivity" })
$win.FindName("TabSend").Add_Click({ Show-Page "PageSend" })
$win.FindName("TabReceive").Add_Click({ Show-Page "PageReceive" })
$win.FindName("TabAccount").Add_Click({ Show-Page "PageAccount" })
$AccountWho = $win.FindName("AccountWho")
$AccountStatus = $win.FindName("AccountStatus")
$SeedBox = $win.FindName("SeedBox")
$AccountWho.Text = "Signed in as $script:SessionUser"

function Use-AccountAddress([string]$Address, [string]$WalletName) {
    $script:Wallet = $WalletName
    $script:Address = $Address
    Set-Content $AddrFile $Address -Encoding ASCII
    $RecvAddr.Text = $Address
    Save-WalletSettings $WalletName
    if ($script:Mining) {
        $script:Mining = $false
        Stop-WalletNode
        Start-WalletNode -MineTo $Address
        $script:Mining = $true
    }
}

$win.FindName("ShowSeedBtn").Add_Click({
    try {
        $secret = Join-Path $WalletDir "account.secret"
        $blob = Get-Content $secret -Raw
        $SeedBox.Text = ConvertFrom-Le0Secret -Password $script:SessionPassword -Blob $blob.Trim()
        $AccountStatus.Text = "This seed belongs to $script:SessionUser only."
    } catch {
        $AccountStatus.Text = "Could not show the seed."
    }
})
$win.FindName("CopyBtn").Add_Click({
    if ($RecvAddr.Text) { [System.Windows.Clipboard]::SetText($RecvAddr.Text) }
})

$script:Wallet = $null
$script:Mining = $false
$script:ZeroSince = $null
$script:Busy = $false
$script:Address = ""
if (Test-Path $AddrFile) { $script:Address = (Get-Content $AddrFile -Raw).Trim() }

function Ensure-Address {
    if (-not $script:Wallet) { return }
    if ($script:Address) { return }
    $r = Get-Le0Rpc -Method "getnewaddress" -Port $Rpc -Wallet $script:Wallet
    $script:Address = [string]$r.result
    Set-Content $AddrFile $script:Address -Encoding ASCII
}

$win.FindName("NewAddrBtn").Add_Click({
    try {
        $r = Get-Le0Rpc -Method "getnewaddress" -Port $Rpc -Wallet $script:Wallet
        $RecvAddr.Text = [string]$r.result
    } catch { $RecvAddr.Text = $_.Exception.Message }
})
$win.FindName("SendBtn").Add_Click({
    try {
        $amt = [double]$SendAmt.Text
        if ($script:SessionPassword) {
            try { Get-Le0Rpc -Method "walletpassphrase" -Params @($script:SessionPassword, 120) -Port $Rpc -Wallet $script:Wallet | Out-Null } catch {}
        }
        $r = Get-Le0Rpc -Method "sendtoaddress" -Params @([string]$SendAddr.Text, $amt) -Port $Rpc -Wallet $script:Wallet
        $SendResult.Text = "Sent. Txid: $($r.result)"
        $SendAddr.Text = ""
        $SendAmt.Text = ""
    } catch {
        $SendResult.Text = $_.Exception.Message
    }
})

$nodeUp = $false
try {
    Get-Le0Rpc -Method "getblockcount" -Port $Rpc -TimeoutSec 2 | Out-Null
    $nodeUp = $true
} catch {}
if (-not $nodeUp) {
    $mineNow = ""
    # Miner pack only: never start hashing without a saved wallet address.
    if ($script:AllowMine -and $script:Address -and -not $script:Le0Gate.NeedsInstall) {
        $mineNow = $script:Address
    }
    Start-WalletNode -MineTo $mineNow
    try { Wait-Le0Rpc -Port $Rpc -Seconds 90 | Out-Null } catch {}
}
try { Update-Le0Windows } catch {}
if ($script:Le0Gate.NeedsInstall) {
    $newAddr = Install-Le0MnemonicWallet -Username $script:SessionUser -Password $script:SessionPassword -Mnemonic $script:Le0Gate.Mnemonic -WalletDir $WalletDir -Port $Rpc -Reset:([bool]$script:Le0Gate.IsReset)
    $script:Wallet = "Account"
    $script:Address = $newAddr
    Set-Content $AddrFile $newAddr -Encoding ASCII
    Save-WalletSettings "Account"
} else {
    $prefer = Select-WalletName
    if ($prefer) { $script:Wallet = $prefer }
    if ($script:SessionPassword -and $script:Wallet) {
        try { Get-Le0Rpc -Method "walletpassphrase" -Params @($script:SessionPassword, 3600) -Port $Rpc -Wallet $script:Wallet | Out-Null } catch {}
    }
}
try {
    if ($script:AllowMine) {
        $cmd = [string](Get-CimInstance Win32_Process -Filter "Name='le0-qt.exe'" | Select-Object -First 1 -ExpandProperty CommandLine)
        if ($cmd -like "*-mineaddress=*") { $script:Mining = $true }
    }
} catch {}

if (-not $script:AllowMine) {
    $MineText.Text = "Mining  off (wallet pack)"
    $RateText.Text = "This download does not mine. Use the Miner pack if you want to mine."
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        Update-Le0Windows
        try { $info = (Get-Le0Rpc -Method "getblockchaininfo" -Port $Rpc -TimeoutSec 4).result } catch {
            $NetStatus.Text = "Starting node..."
            $NetStatus.Foreground = "#E6C36A"
            return
        }
        if (-not $script:Wallet) {
            try {
                $loaded = @((Get-Le0Rpc -Method "listwallets" -Port $Rpc).result)
                if ($loaded.Count -gt 0) { $script:Wallet = [string]$loaded[0] }
                else {
                    $name = "Le0 Wallet"
                    try { Get-Le0Rpc -Method "createwallet" -Params @($name) -Port $Rpc | Out-Null } catch {}
                    try { Get-Le0Rpc -Method "loadwallet" -Params @($name) -Port $Rpc | Out-Null } catch {}
                    $script:Wallet = $name
                }
            } catch {}
        }
        $peers = 0
        try { $peers = Get-Le0LivePeerCount -Port $Rpc } catch { $peers = 0 }
        # Caught up with the peer. Do not wait for IBD: a brand-new chain looks "old" until the first blocks are mined.
        $synced = ($info.headers -eq $info.blocks) -and ($peers -ge 1)
        $HeightText.Text = "Height  $($info.blocks)"
        $PeerText.Text = "Peers  $peers"
        if ($script:Wallet) {
            try {
                $b = (Get-Le0Rpc -Method "getbalances" -Port $Rpc -Wallet $script:Wallet).result.mine
                $Bal.Text = "{0:N8}" -f [decimal]$b.trusted
                $Extra.Text = "Pending  $($b.untrusted_pending)    Immature  $($b.immature)"
            } catch {}
            try { Ensure-Address } catch {}
            if ($script:Address -and -not $RecvAddr.Text) { $RecvAddr.Text = $script:Address }
            try {
                $txs = @((Get-Le0Rpc -Method "listtransactions" -Params @("*", 12, 0) -Port $Rpc -Wallet $script:Wallet).result)
                $TxList.Items.Clear()
                foreach ($t in ($txs | Sort-Object time -Descending)) {
                    if ($t.category -in @("orphan","conflict")) { continue }
                    $when = [DateTimeOffset]::FromUnixTimeSeconds([int64]$t.time).LocalDateTime.ToString("dd MMM  HH:mm")
                    $sign = if ([decimal]$t.amount -ge 0) { "+" } else { "" }
                    [void]$TxList.Items.Add("$when    $($t.category)    $sign$($t.amount) LE0")
                }
            } catch {}
        }
        if (-not $script:AllowMine) {
            $MineText.Text = "Mining  off (wallet pack)"
            $RateText.Text = "This download does not mine. Use the Miner pack if you want to mine."
            if ($peers -ge 1) {
                $NetStatus.Text = "On the Le0 network"
                $NetStatus.Foreground = "#7CFFB2"
            } else {
                $NetStatus.Text = "Not connected yet"
                $NetStatus.Foreground = "#E6C36A"
            }
            return
        }
        $rate = ""
        $log = Join-Path $DataDir "debug.log"
        if (Test-Path $log) {
            $line = Select-String -Path $log -Pattern "le0-mine: .*H/s" | Select-Object -Last 1
            if ($line) {
                $raw = $line.Line
                $idx = $raw.IndexOf("le0-mine:")
                if ($idx -ge 0) { $rate = $raw.Substring($idx) }
            }
        }
        $RateText.Text = $rate
        # No wallet address = no mining (buyer / empty account cannot hash).
        if (-not $script:Address) {
            $MineText.Text = "Mining  needs a wallet address"
            $RateText.Text = "Sign in / create your Le0 wallet account first. Miner will not run without it."
            if ($peers -ge 1) {
                $NetStatus.Text = "On the Le0 network"
                $NetStatus.Foreground = "#7CFFB2"
            } else {
                $NetStatus.Text = "Not connected yet"
                $NetStatus.Foreground = "#E6C36A"
            }
        } elseif ($synced -and -not $script:Mining -and $script:Address) {
            $NetStatus.Text = "Connected. Starting miner..."
            $script:Mining = $true
            $script:ZeroSince = $null
            Stop-WalletNode
            Start-WalletNode -MineTo $script:Address
            $MineText.Text = "Mining  on"
        } elseif ($script:Mining -and $peers -lt 1) {
            if (-not $script:ZeroSince) { $script:ZeroSince = Get-Date }
            if (((Get-Date) - $script:ZeroSince).TotalSeconds -ge 45) {
                $script:Mining = $false
                $script:ZeroSince = $null
                Stop-WalletNode
                Start-WalletNode -MineTo ""
                $MineText.Text = "Mining  paused (no network)"
            } else {
                $MineText.Text = "Mining  holding (peer dropped)"
            }
        } elseif ($script:Mining -and $peers -ge 1) {
            $script:ZeroSince = $null
            $MineText.Text = "Mining  on"
            $NetStatus.Text = "On the Le0 network"
            $NetStatus.Foreground = "#7CFFB2"
        } else {
            $MineText.Text = "Mining  waiting for the laptop host"
            $NetStatus.Text = "Not connected yet"
            $NetStatus.Foreground = "#E6C36A"
        }
    } finally {
        $script:Busy = $false
    }
})
$timer.Start()
$win.Add_Closed({
    $timer.Stop()
})
[void]$win.ShowDialog()
