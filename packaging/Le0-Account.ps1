# Le0 account: 12-word seed signs you in on another device. Password locks spending.
$ErrorActionPreference = "Stop"

function Initialize-Le0Keys {
    param([string]$Root)
    if ("Le0Keys" -as [type]) { return }
    $dll = Join-Path $Root "lib\BouncyCastle.Crypto.dll"
    if (-not (Test-Path $dll)) { throw "Missing lib\BouncyCastle.Crypto.dll" }
    Add-Type -Path $dll
    Add-Type -Path (Join-Path $Root "Le0Keys.cs") -ReferencedAssemblies $dll
}

function Get-Le0Wordlist {
    param([string]$Root)
    $words = @(Get-Content (Join-Path $Root "bip39-english.txt") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($words.Count -ne 2048) { throw "Seed word list is incomplete." }
    return $words
}

function ConvertTo-Le0Secret {
    param([string]$Password, [string]$Mnemonic)
    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt)
    $rng.GetBytes($iv)
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000)
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $kdf.GetBytes(32)
    $aes.IV = $iv
    $plain = [Text.Encoding]::UTF8.GetBytes($Mnemonic)
    $cipher = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
    $all = New-Object byte[] (16 + 16 + $cipher.Length)
    [Buffer]::BlockCopy($salt, 0, $all, 0, 16)
    [Buffer]::BlockCopy($iv, 0, $all, 16, 16)
    [Buffer]::BlockCopy($cipher, 0, $all, 32, $cipher.Length)
    return [Convert]::ToBase64String($all)
}

function ConvertFrom-Le0Secret {
    param([string]$Password, [string]$Blob)
    $all = [Convert]::FromBase64String($Blob)
    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    [Buffer]::BlockCopy($all, 0, $salt, 0, 16)
    [Buffer]::BlockCopy($all, 16, $iv, 0, 16)
    $cipher = New-Object byte[] ($all.Length - 32)
    [Buffer]::BlockCopy($all, 32, $cipher, 0, $cipher.Length)
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000)
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $kdf.GetBytes(32)
    $aes.IV = $iv
    $plain = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length)
    return [Text.Encoding]::UTF8.GetString($plain)
}

function Get-Le0RpcError {
    param($ErrorRecord)
    $raw = $ErrorRecord.ErrorDetails.Message
    if ($raw) {
        try { return (($raw | ConvertFrom-Json).error.message) } catch { return $raw }
    }
    return $ErrorRecord.Exception.Message
}

function Install-Le0MnemonicWallet {
    param(
        [string]$Username,
        [string]$Password,
        [string]$Mnemonic,
        [string]$WalletDir,
        [int]$Port = 28443,
        [switch]$Reset
    )
    $name = "Account"
    $words = Get-Le0Wordlist -Root $script:Le0Root
    if (-not [Le0Keys]::IsValid($Mnemonic, $words)) { throw "Those 12 words are not a valid Le0 seed phrase." }
    $xprv = [Le0Keys]::AccountXprv($Mnemonic)
    $extInfo = (Get-Le0Rpc -Method "getdescriptorinfo" -Params @("wpkh($xprv/0/*)") -Port $Port).result
    $chgInfo = (Get-Le0Rpc -Method "getdescriptorinfo" -Params @("wpkh($xprv/1/*)") -Port $Port).result
    if (-not $extInfo.hasprivatekeys) { throw "Could not build the account key." }
    # getdescriptorinfo returns a public descriptor. Keep the private key and add its checksum.
    $ext = "wpkh($xprv/0/*)#$($extInfo.checksum)"
    $chg = "wpkh($xprv/1/*)#$($chgInfo.checksum)"

    $loaded = @((Get-Le0Rpc -Method "listwallets" -Port $Port).result)
    if ($loaded -contains $name) {
        try { Get-Le0Rpc -Method "unloadwallet" -Params @($name) -Port $Port | Out-Null } catch {}
    }
    $dir = Join-Path $WalletDir $name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }

    try {
        Get-Le0Rpc -Method "createwallet" -Params @($name, $false, $true, $Password, $false, $true, $true) -Port $Port | Out-Null
    } catch {
        throw (Get-Le0RpcError $_)
    }
    try {
        Get-Le0Rpc -Method "walletpassphrase" -Params @($Password, 600) -Port $Port -Wallet $name | Out-Null
        $batch = @(
            @{ desc = $ext; timestamp = 0; active = $true; internal = $false },
            @{ desc = $chg; timestamp = 0; active = $true; internal = $true }
        )
        $imported = Get-Le0Rpc -Method "importdescriptors" -Params @(,$batch) -Port $Port -Wallet $name
        foreach ($row in @($imported.result)) {
            if (-not $row.success) { throw "Could not import the seed: $($row.error.message)" }
        }
        $addr = [string](Get-Le0Rpc -Method "getnewaddress" -Params @("", "bech32") -Port $Port -Wallet $name).result
    } catch {
        throw (Get-Le0RpcError $_)
    }
    if (-not $addr) { throw "Wallet was created but no address came back." }

    New-Item -ItemType Directory -Force -Path $WalletDir | Out-Null
    $phrase = (($Mnemonic -replace '\s+', ' ').Trim().ToLower())
    $seedHash = Get-Le0SeedHash $phrase
    $hashFile = Join-Path $WalletDir "seed-hashes.txt"
    $known = @()
    if (Test-Path $hashFile) { $known = @(Get-Content $hashFile | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $acctPath = Join-Path $WalletDir "account.json"
    $own = ""
    if (Test-Path $acctPath) {
        try { $own = [string](Get-Content $acctPath -Raw | ConvertFrom-Json).seedhash } catch {}
    }
    if ($Reset) {
        if (-not $own -or $seedHash -ne $own) { throw "This seed phrase does not belong to this account." }
    } elseif ($known -contains $seedHash) {
        throw "That seed phrase is already used by an account. Each person gets their own."
    }
    $acct = @{ username = $Username; wallet = $name; seedhash = $seedHash } | ConvertTo-Json -Compress
    Set-Content $acctPath $acct -Encoding UTF8
    Set-Content (Join-Path $WalletDir "account.secret") (ConvertTo-Le0Secret -Password $Password -Mnemonic $phrase) -Encoding ASCII
    if ($known -notcontains $seedHash) { Add-Content $hashFile $seedHash }
    return $addr
}

function Get-Le0SeedHash {
    param([string]$Mnemonic)
    $phrase = (($Mnemonic -replace '\s+', ' ').Trim().ToLower())
    $sha = [Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($phrase))
    return (([BitConverter]::ToString($bytes)) -replace '-','').ToLower()
}

function New-UniqueLe0Mnemonic {
    param([string]$WalletDir)
    $words = Get-Le0Wordlist -Root $script:Le0Root
    $hashFile = Join-Path $WalletDir "seed-hashes.txt"
    $known = @()
    if (Test-Path $hashFile) { $known = @(Get-Content $hashFile | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    for ($i = 0; $i -lt 8; $i++) {
        $m = [Le0Keys]::NewMnemonic($words)
        $h = Get-Le0SeedHash $m
        if ($known -notcontains $h) { return $m }
    }
    throw "Could not make a unique seed phrase. Close the app and try again."
}

function Show-Le0LoginGate {
    param([string]$WalletDir)
    Add-Type -AssemblyName PresentationFramework
    New-Item -ItemType Directory -Force -Path $WalletDir | Out-Null
    $acctPath = Join-Path $WalletDir "account.json"
    $hasAccount = Test-Path $acctPath
    $acctUser = ""
    $acctHash = ""
    if ($hasAccount) {
        $j = Get-Content $acctPath -Raw | ConvertFrom-Json
        $acctUser = [string]$j.username
        $acctHash = [string]$j.seedhash
    }
    $title = $(if ($hasAccount) { "Sign in" } else { "Create your account" })
    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Le0 sign in" Height="560" Width="460"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize" Background="#101114">
  <StackPanel Margin="28">
    <TextBlock Text="Le0" Foreground="#F4F7FB" FontSize="32" FontWeight="Bold"/>
    <TextBlock x:Name="Head" Text="$title" Foreground="#7CFFB2" FontSize="16" Margin="0,4,0,16"/>
    <TextBlock x:Name="UserLabel" Text="Username" Foreground="#8B95A1"/>
    <TextBox x:Name="UserBox" Margin="0,4,0,10" Padding="8"/>
    <StackPanel x:Name="PassPanel">
      <TextBlock Text="Password" Foreground="#8B95A1"/>
      <PasswordBox x:Name="PassA" Margin="0,4,0,10" Padding="8"/>
      <StackPanel x:Name="PassAgain">
        <TextBlock Text="Password again" Foreground="#8B95A1"/>
        <PasswordBox x:Name="PassB" Margin="0,4,0,10" Padding="8"/>
      </StackPanel>
    </StackPanel>
    <StackPanel x:Name="SeedPanel" Visibility="Collapsed">
      <TextBlock x:Name="SeedLabel" Text="Seed phrase" Foreground="#8B95A1" TextWrapping="Wrap"/>
      <TextBox x:Name="SeedBox" Margin="0,4,0,10" Padding="8" TextWrapping="Wrap" AcceptsReturn="True" MinHeight="72"/>
      <TextBlock Text="New password" Foreground="#8B95A1"/>
      <PasswordBox x:Name="NewA" Margin="0,4,0,10" Padding="8"/>
      <TextBlock Text="New password again" Foreground="#8B95A1"/>
      <PasswordBox x:Name="NewB" Margin="0,4,0,10" Padding="8"/>
    </StackPanel>
    <CheckBox x:Name="Saved" Content="I wrote the 12 words down" Foreground="#C5CDD6" Margin="0,0,0,12" Visibility="Collapsed"/>
    <Button x:Name="Go" Content="Sign in" Padding="14,8" HorizontalAlignment="Left"/>
    <Button x:Name="Forgot" Content="Forgotten password" Margin="0,10,0,0" Padding="14,8" HorizontalAlignment="Left"/>
    <Button x:Name="HaveSeed" Content="I already have a seed phrase" Margin="0,10,0,0" Padding="14,8" HorizontalAlignment="Left"/>
    <TextBlock x:Name="Msg" Margin="0,14,0,0" Foreground="#E6C36A" TextWrapping="Wrap"/>
  </StackPanel>
</Window>
"@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    Set-Le0WindowIcon -Window $w -Root $script:Le0Root
    $userBox = $w.FindName("UserBox")
    $passA = $w.FindName("PassA")
    $passB = $w.FindName("PassB")
    $passAgain = $w.FindName("PassAgain")
    $seedPanel = $w.FindName("SeedPanel")
    $seedBox = $w.FindName("SeedBox")
    $seedLabel = $w.FindName("SeedLabel")
    $newA = $w.FindName("NewA")
    $newB = $w.FindName("NewB")
    $passPanel = $w.FindName("PassPanel")
    $saved = $w.FindName("Saved")
    $go = $w.FindName("Go")
    $forgot = $w.FindName("Forgot")
    $haveSeed = $w.FindName("HaveSeed")
    $msg = $w.FindName("Msg")
    $head = $w.FindName("Head")
    $script:Le0AcctUser = $acctUser
    $script:Le0AcctHash = $acctHash
    $script:Le0WalletDir = $WalletDir
    $script:Le0GateMode = "login"
    $script:Le0MadeSeed = ""
    if (-not $hasAccount) {
        $script:Le0GateMode = "create"
        $go.Content = "Create account"
        $forgot.Visibility = "Collapsed"
    } else {
        $passAgain.Visibility = "Collapsed"
        $haveSeed.Visibility = "Collapsed"
        $userBox.Text = $acctUser
    }
    $script:Le0GateResult = $null
    $go.Add_Click({
        try {
            $user = $userBox.Text.Trim()
            if ($user.Length -lt 2) { throw "Enter a username." }
            if ($script:Le0GateMode -eq "create") {
                $p1 = $passA.Password
                $p2 = $passB.Password
                if ($p1.Length -lt 8) { throw "Password must be at least 8 characters." }
                if ($p1 -ne $p2) { throw "Passwords do not match." }
                if (-not $script:Le0MadeSeed) {
                    $script:Le0MadeSeed = New-UniqueLe0Mnemonic -WalletDir $script:Le0WalletDir
                    $seedPanel.Visibility = "Visible"
                    $seedBox.Text = $script:Le0MadeSeed
                    $seedBox.IsReadOnly = $true
                    $seedLabel.Text = "This seed phrase was generated for this username only. Write it down. It will not be shown again unless you use the password."
                    $saved.Visibility = "Visible"
                    $passPanel.Visibility = "Collapsed"
                    $go.Content = "Open wallet"
                    $msg.Text = "Write the 12 words on paper, tick the box, then open the wallet."
                    return
                }
                if (-not $saved.IsChecked) { throw "Tick the box after you write the 12 words down." }
                $script:Le0GateResult = @{ Username = $user; Password = $p1; Mnemonic = $script:Le0MadeSeed; NeedsInstall = $true; IsReset = $false }
                $w.Close()
                return
            }
            if ($script:Le0GateMode -eq "forgot") {
                $p1 = $newA.Password
                $p2 = $newB.Password
                if ($p1.Length -lt 8) { throw "New password must be at least 8 characters." }
                if ($p1 -ne $p2) { throw "New passwords do not match." }
                $phrase = $seedBox.Text.Trim()
                $words = Get-Le0Wordlist -Root $script:Le0Root
                if (-not [Le0Keys]::IsValid($phrase, $words)) { throw "That is not a valid 12 word seed phrase." }
                if ((Get-Le0SeedHash $phrase) -ne $script:Le0AcctHash) { throw "This seed phrase does not belong to this account." }
                if ($user -ne $script:Le0AcctUser) { throw "That username does not belong to this seed phrase." }
                $script:Le0GateResult = @{ Username = $user; Password = $p1; Mnemonic = $phrase; NeedsInstall = $true; IsReset = $true }
                $w.Close()
                return
            }
            if ($script:Le0GateMode -eq "restore") {
                $p1 = $newA.Password
                $p2 = $newB.Password
                if ($p1.Length -lt 8) { throw "Password must be at least 8 characters." }
                if ($p1 -ne $p2) { throw "Passwords do not match." }
                $phrase = $seedBox.Text.Trim()
                $words = Get-Le0Wordlist -Root $script:Le0Root
                if (-not [Le0Keys]::IsValid($phrase, $words)) { throw "That is not a valid 12 word seed phrase." }
                $h = Get-Le0SeedHash $phrase
                $hashFile = Join-Path $script:Le0WalletDir "seed-hashes.txt"
                $known = @()
                if (Test-Path $hashFile) { $known = @(Get-Content $hashFile | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                if ($known -contains $h) { throw "That seed phrase is already used by an account." }
                $script:Le0GateResult = @{ Username = $user; Password = $p1; Mnemonic = $phrase; NeedsInstall = $true; IsReset = $false }
                $w.Close()
                return
            }
            $p1 = $passA.Password
            if ($user -cne $script:Le0AcctUser) { throw "Wrong username or password." }
            $secretPath = Join-Path $script:Le0WalletDir "account.secret"
            try { $phrase = ConvertFrom-Le0Secret -Password $p1 -Blob ((Get-Content $secretPath -Raw).Trim()) }
            catch { throw "Wrong username or password." }
            if ((Get-Le0SeedHash $phrase) -ne $script:Le0AcctHash) { throw "Wrong username or password." }
            $script:Le0GateResult = @{ Username = $user; Password = $p1; Mnemonic = ""; NeedsInstall = $false; IsReset = $false }
            $w.Close()
        } catch {
            $msg.Text = $_.Exception.Message
        }
    })
    $forgot.Add_Click({
        $script:Le0GateMode = "forgot"
        $head.Text = "Reset with your seed phrase"
        $passPanel.Visibility = "Collapsed"
        $seedPanel.Visibility = "Visible"
        $seedBox.IsReadOnly = $false
        $seedBox.Text = ""
        $seedLabel.Text = "Enter the 12 words for this account only."
        $saved.Visibility = "Collapsed"
        $go.Content = "Reset password and sign in"
        $forgot.Visibility = "Collapsed"
        $msg.Text = ""
    })
    $haveSeed.Add_Click({
        $script:Le0GateMode = "restore"
        $head.Text = "Sign in with your seed phrase"
        $passPanel.Visibility = "Collapsed"
        $seedPanel.Visibility = "Visible"
        $seedBox.IsReadOnly = $false
        $seedBox.Text = ""
        $seedLabel.Text = "Enter the 12 words from your account. They only work for that one person."
        $saved.Visibility = "Collapsed"
        $go.Content = "Sign in"
        $haveSeed.Visibility = "Collapsed"
        $msg.Text = ""
    })
    [void]$w.ShowDialog()
    return $script:Le0GateResult
}
