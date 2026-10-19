#Requires -Version 5.1
<#
  codex-switch - switch between multiple Codex (ChatGPT) accounts on one PC
  while keeping ONE shared CODEX_HOME, so every account shares the same local
  workspace, sessions, history and settings. No cloud, no logout/login dance.

  Layout:
    <CODEX_HOME>\auth.json                live login used by codex
    <CODEX_HOME>\accounts\<name>.json     saved login snapshot per account
    <CODEX_HOME>\accounts\.active         name of the active snapshot

  Usage: codex-switch <command> [name] [extra...] [-y] [-f]
  Run 'codex-switch help' for details.
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- arg parsing
$Yes = $false
$Force = $false
$positional = @()
foreach ($a in $args) {
    if ($a -match '^(?i)--?y(es)?$') { $Yes = $true; continue }
    if ($a -match '^(?i)--?f(orce)?$') { $Force = $true; $Yes = $true; continue }
    $positional += $a
}
$Command = ''
$Name = ''
if ($positional.Count -ge 1) { $Command = [string]$positional[0] }
if ($positional.Count -ge 2) { $Name = [string]$positional[1] }
$Extra = @($positional | Select-Object -Skip 2)

# ---------------------------------------------------------------- locations
function Resolve-CodexHome {
    $userHome = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($userHome)) { $userHome = $env:HOME }
    if ([string]::IsNullOrWhiteSpace($userHome)) { $userHome = [Environment]::GetFolderPath('UserProfile') }
    $h = $env:CODEX_HOME
    if ([string]::IsNullOrWhiteSpace($h)) { $h = Join-Path $userHome '.codex' }
    $h = [Environment]::ExpandEnvironmentVariables($h)
    if ($h -match '^~($|[\\/])') { $h = Join-Path $userHome ($h -replace '^~[\\/]?', '') }
    return $h
}

$CodexHome   = Resolve-CodexHome
$AccountsDir = Join-Path $CodexHome 'accounts'
$AuthPath    = Join-Path $CodexHome 'auth.json'
$ActivePath  = Join-Path $AccountsDir '.active'

$CodexExe = $null
$codexCmd = Get-Command codex -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -in @('Application', 'ExternalScript') } | Select-Object -First 1
if ($codexCmd) { $CodexExe = $codexCmd.Source }

if (-not (Test-Path $AccountsDir)) { New-Item -ItemType Directory -Path $AccountsDir -Force | Out-Null }

# ---------------------------------------------------------------- output helpers
function Write-Ok([string]$Message)      { Write-Host $Message -ForegroundColor Green }
function Write-WarnMsg([string]$Message) { Write-Host $Message -ForegroundColor Yellow }
function Write-ErrMsg([string]$Message)  { Write-Host $Message -ForegroundColor Red }
function Write-Step([string]$Message)    { Write-Host $Message -ForegroundColor Cyan }

function Confirm-Action([string]$Question) {
    if ($Yes) { return $true }
    $answer = ''
    try { $answer = Read-Host $Question } catch { return $false }
    return ($answer -match '^(?i)\s*(y|yes)\s*$')
}

# ---------------------------------------------------------------- auth helpers
function Read-AuthFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try {
        $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Get-JwtPayload([string]$Jwt) {
    try {
        $parts = $Jwt.Split('.')
        if ($parts.Count -lt 2) { return $null }
        $b64 = $parts[1].Replace('-', '+').Replace('_', '/')
        while ($b64.Length % 4 -ne 0) { $b64 += '=' }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
        return ($json | ConvertFrom-Json)
    } catch { return $null }
}

function Get-AuthIdentity($Auth) {
    $result = [pscustomobject]@{
        Kind       = 'none'
        Email      = $null
        Plan       = $null
        AccountId  = $null
        Expires    = $null
        ApiKeyTail = $null
    }
    if ($null -eq $Auth) { return $result }
    if ($Auth.tokens -and $Auth.tokens.id_token) {
        $result.Kind = 'chatgpt'
        $claims = Get-JwtPayload ([string]$Auth.tokens.id_token)
        if ($claims) {
            if ($claims.email) { $result.Email = [string]$claims.email }
            $openai = $claims.'https://api.openai.com/auth'
            if ($openai) {
                if ($openai.chatgpt_plan_type) { $result.Plan = [string]$openai.chatgpt_plan_type }
                if ($openai.chatgpt_account_id) { $result.AccountId = [string]$openai.chatgpt_account_id }
            }
            if ($claims.exp) { $result.Expires = [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp).ToLocalTime() }
        }
        if (-not $result.AccountId -and $Auth.tokens.account_id) { $result.AccountId = [string]$Auth.tokens.account_id }
    } elseif ($Auth.PSObject.Properties['OPENAI_API_KEY'] -and $Auth.OPENAI_API_KEY) {
        $result.Kind = 'apikey'
        $k = [string]$Auth.OPENAI_API_KEY
        if ($k.Length -gt 8) { $result.ApiKeyTail = $k.Substring($k.Length - 4) } else { $result.ApiKeyTail = '****' }
    }
    return $result
}

function Format-Identity($Id) {
    if ($null -eq $Id -or $Id.Kind -eq 'none') { return 'not logged in' }
    if ($Id.Kind -eq 'apikey') { return "API key (ends ...$($Id.ApiKeyTail))" }
    $text = [string]$Id.Email
    if ([string]::IsNullOrWhiteSpace($text)) { $text = 'ChatGPT account' }
    if ($Id.Plan) { $text += " [$($Id.Plan)]" }
    return $text
}

function Test-SameAccount($A, $B) {
    if ($null -eq $A -or $null -eq $B) { return $false }
    $ia = Get-AuthIdentity $A
    $ib = Get-AuthIdentity $B
    if ($ia.Kind -ne $ib.Kind) { return $false }
    if ($ia.Kind -eq 'none') { return $false }
    if ($ia.Kind -eq 'apikey') { return ($A.OPENAI_API_KEY -eq $B.OPENAI_API_KEY) }
    if ($ia.AccountId -and $ib.AccountId) { return ($ia.AccountId -eq $ib.AccountId) }
    if ($ia.Email -and $ib.Email) { return ($ia.Email -eq $ib.Email) }
    $ra = $null; $rb = $null
    if ($A.tokens) { $ra = $A.tokens.refresh_token }
    if ($B.tokens) { $rb = $B.tokens.refresh_token }
    if ($ra -and $rb) { return ($ra -eq $rb) }
    return $false
}

# ---------------------------------------------------------------- account store
function Get-AccountNames {
    if (-not (Test-Path $AccountsDir)) { return @() }
    return @(Get-ChildItem -Path $AccountsDir -Filter '*.json' -File | Sort-Object Name | ForEach-Object { $_.BaseName })
}

function Get-AccountPath([string]$Account) { return (Join-Path $AccountsDir ($Account + '.json')) }

function Set-ActiveName([string]$Account) { Set-Content -Path $ActivePath -Value $Account -NoNewline -Encoding Ascii }

function Assert-ValidName([string]$Account) {
    if ($Account -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        Write-ErrMsg "Invalid account name '$Account'. Use letters, digits, '.', '-' or '_' (must start with a letter or digit)."
        exit 1
    }
}

function Get-ActiveName {
    $marker = $null
    if (Test-Path $ActivePath) { $marker = ([string](Get-Content -Path $ActivePath -Raw)).Trim() }
    $live = Read-AuthFile $AuthPath
    if ($live) {
        if ($marker -and (Test-Path (Get-AccountPath $marker))) {
            if (Test-SameAccount $live (Read-AuthFile (Get-AccountPath $marker))) { return $marker }
        }
        foreach ($acct in (Get-AccountNames)) {
            if (Test-SameAccount $live (Read-AuthFile (Get-AccountPath $acct))) {
                Set-ActiveName $acct
                return $acct
            }
        }
    }
    if ($marker -and (Test-Path (Get-AccountPath $marker))) { return $marker }
    return $null
}

function Save-LiveAuth {
    if (-not (Test-Path $AuthPath)) { return $null }
    $live = Read-AuthFile $AuthPath
    if ($null -eq $live) {
        Write-WarnMsg '! auth.json exists but could not be parsed; leaving it untouched.'
        return $null
    }
    $name = $null
    foreach ($acct in (Get-AccountNames)) {
        if (Test-SameAccount $live (Read-AuthFile (Get-AccountPath $acct))) { $name = $acct; break }
    }
    if (-not $name) {
        $name = 'untracked-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Write-WarnMsg "! Current login does not match any saved account; saving it as '$name'."
    }
    Copy-Item -Path $AuthPath -Destination (Get-AccountPath $name) -Force
    Set-ActiveName $name
    return $name
}

# ---------------------------------------------------------------- daemon + clients
function Test-DaemonRunning {
    $pidFile = Join-Path (Join-Path $CodexHome 'app-server-daemon') 'daemon.pid'
    if (Test-Path $pidFile) {
        try {
            $j = Get-Content -Path $pidFile -Raw | ConvertFrom-Json
            if ($j.pid) {
                $p = Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue
                if ($p -and $p.ProcessName -eq 'codex') { return $true }
            }
        } catch { }
    }
    $daemons = @(Get-Process -Name 'codex' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*app-server-daemon*' })
    return ($daemons.Count -gt 0)
}

function Offer-DaemonRestart {
    $daemonRunning = Test-DaemonRunning
    $clients = @(Get-Process -Name 'codex' -ErrorAction SilentlyContinue)
    if (-not $daemonRunning -and $clients.Count -eq 0) { return }
    Write-Host ''
    if ($daemonRunning) {
        Write-WarnMsg '! The Codex app-server daemon (Desktop app / IDE backend) is running and keeps the OLD account until restarted.'
    } elseif ($clients.Count -gt 0) {
        Write-WarnMsg '! Other codex sessions are still running; they keep the old account until restarted.'
    }
    Write-Host "  New terminal sessions ('codex', 'codex resume') pick up the new account immediately."
    if ($daemonRunning -and $CodexExe) {
        if (Confirm-Action 'Restart the app-server daemon now so Desktop/IDE use the new account? Interrupts any in-flight Desktop/IDE task. [y/N] ') {
            Write-Step 'Restarting app-server daemon...'
            & $CodexExe app-server daemon restart
            if ($LASTEXITCODE -eq 0) { Write-Ok 'App-server daemon restarted.' }
            else { Write-WarnMsg "! Restart failed (exit $LASTEXITCODE). Run manually: codex app-server daemon restart" }
        } else {
            Write-Host '  Skipped. To apply it later:  codex app-server daemon restart'
        }
    }
    Write-Host ''
}

# ---------------------------------------------------------------- rate limits
function Format-Duration([TimeSpan]$Span) {
    if ($Span.TotalSeconds -le 0) { return 'now' }
    if ($Span.TotalDays -ge 1) { return ('{0}d {1}h' -f [int][Math]::Floor($Span.TotalDays), $Span.Hours) }
    if ($Span.TotalHours -ge 1) { return ('{0}h {1}m' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes) }
    return ('{0}m' -f [int][Math]::Ceiling($Span.TotalMinutes))
}

function Format-WindowLabel($Minutes) {
    if ($null -eq $Minutes) { return '?' }
    $m = [int]$Minutes
    if ($m -le 0) { return '?' }
    if ($m % 10080 -eq 0) { return ('{0}w' -f ($m / 10080)) }
    if ($m % 1440 -eq 0) { return ('{0}d' -f ($m / 1440)) }
    if ($m % 60 -eq 0) { return ('{0}h' -f ($m / 60)) }
    return ('{0}m' -f $m)
}

function Get-LimitBar([int]$PercentLeft, [int]$Width = 10) {
    $filled = [int][Math]::Round(($PercentLeft / 100.0) * $Width)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $Width) { $filled = $Width }
    return (('#' * $filled) + ('-' * ($Width - $filled)))
}

function Get-ResetText($Window) {
    if ($null -eq $Window -or $null -eq $Window.resetsAt) { return '' }
    $when = [DateTimeOffset]::FromUnixTimeSeconds([long]$Window.resetsAt).ToLocalTime()
    $span = $when - [DateTimeOffset]::Now
    $format = if ($span.TotalDays -ge 1) { 'ddd HH:mm' } else { 'HH:mm' }
    return ('resets in {0} ({1})' -f (Format-Duration $span), $when.ToString($format))
}

function Write-AuthFileSafe([string]$Path, [string]$Content) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-JsonLine($Process, $Object) {
    $json = $Object | ConvertTo-Json -Compress -Depth 10
    $Process.StandardInput.WriteLine($json)
    $Process.StandardInput.Flush()
}

function Read-JsonLine([hashtable]$State, [int]$TimeoutMs) {
    if ($null -eq $State.Pending) { return $null }
    if (-not $State.Pending.Wait($TimeoutMs)) { return $null }
    $line = $State.Pending.Result
    $State.Pending = $State.Reader.ReadLineAsync()
    return $line
}

# Asks a short-lived, isolated app-server for one account's rate limits.
# It never touches the live login: the saved snapshot is copied into a temp
# CODEX_HOME, and any tokens the server refreshes are handed back in NewAuth.
function Invoke-RateLimitQuery {
    param([string]$AuthFile, [int]$TimeoutSec = 30)

    $out = [pscustomobject]@{ Ok = $false; Error = $null; Data = $null; NewAuth = $null }
    if (-not $CodexExe) { $out.Error = 'codex executable not found on PATH'; return $out }
    if (-not (Test-Path $AuthFile)) { $out.Error = 'saved login not found'; return $out }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-switch-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $tmpAuth = $null
    $before = $null
    $proc = $null
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $tmpAuth = Join-Path $tmp 'auth.json'
        Copy-Item -Path $AuthFile -Destination $tmpAuth -Force
        $before = (Get-FileHash -Path $tmpAuth -Algorithm SHA256).Hash

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        if ($CodexExe -match '\.(cmd|bat)$') {
            $psi.FileName = $env:ComSpec
            $psi.Arguments = '/c ""' + $CodexExe + '" app-server"'
        } else {
            $psi.FileName = $CodexExe
            $psi.Arguments = 'app-server'
        }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables['CODEX_HOME'] = $tmp

        $proc = [System.Diagnostics.Process]::Start($psi)
        $null = $proc.StandardError.ReadToEndAsync()
        $state = @{ Reader = $proc.StandardOutput; Pending = $proc.StandardOutput.ReadLineAsync() }

        Write-JsonLine $proc @{
            jsonrpc = '2.0'
            id      = 1
            method  = 'initialize'
            params  = @{ clientInfo = @{ name = 'codex-switch'; version = '1.0.0' } }
        }
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            $line = Read-JsonLine $state 250
            if ($null -eq $line) { continue }
            if ($line -match '"id"\s*:\s*1\b') { $ready = $true; break }
        }
        if (-not $ready) { throw 'timed out waiting for the Codex app-server to start' }

        Write-JsonLine $proc @{ jsonrpc = '2.0'; method = 'initialized' }
        Write-JsonLine $proc @{ jsonrpc = '2.0'; id = 2; method = 'account/rateLimits/read'; params = @{} }

        $reply = $null
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            $line = Read-JsonLine $state 250
            if ($null -eq $line) { continue }
            if ($line -match '"id"\s*:\s*2\b') { $reply = $line; break }
        }
        if (-not $reply) { throw 'timed out waiting for usage data' }

        $parsed = $reply | ConvertFrom-Json
        if ($parsed.error) {
            $message = [string]$parsed.error.message
            if ([string]::IsNullOrWhiteSpace($message)) { $message = ($parsed.error | ConvertTo-Json -Compress) }
            throw $message
        }
        if (-not $parsed.result -or -not $parsed.result.rateLimits) { throw 'usage data was empty' }
        $out.Data = $parsed.result
        $out.Ok = $true
    } catch {
        $out.Error = $_.Exception.Message
    } finally {
        if ($proc) {
            try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
            try { $proc.WaitForExit(2000) | Out-Null } catch { }
            $proc.Dispose()
        }
        if ($tmpAuth -and (Test-Path $tmpAuth)) {
            try {
                $after = (Get-FileHash -Path $tmpAuth -Algorithm SHA256).Hash
                if ($before -and $after -ne $before) { $out.NewAuth = Get-Content -Path $tmpAuth -Raw }
            } catch { }
        }
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $out
}

function Show-Limits {
    $names = @(Get-AccountNames)
    if ($names.Count -eq 0) {
        Write-WarnMsg 'No accounts saved yet.'
        Write-Host 'Add one with: codex-switch login <name>'
        return
    }
    $active = Get-ActiveName
    Write-Host ''
    Write-Host ("Reading live usage for {0} account(s) from OpenAI..." -f $names.Count) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ("  {0,-14} {1,-7} {2,-6} {3}" -f 'ACCOUNT', 'PLAN', 'WINDOW', 'REMAINING')
    Write-Host ('  ' + ('-' * 76)) -ForegroundColor DarkGray

    $hadError = $false
    foreach ($acct in $names) {
        $isActive = ($acct -eq $active)
        $authFile = Get-AccountPath $acct
        if ($isActive -and (Test-Path $AuthPath)) { $authFile = $AuthPath }

        $query = Invoke-RateLimitQuery -AuthFile $authFile

        # Keep snapshots current if the server rotated tokens during the read.
        if ($query.NewAuth) {
            try {
                Write-AuthFileSafe (Get-AccountPath $acct) $query.NewAuth
                if ($isActive) { Write-AuthFileSafe $AuthPath $query.NewAuth }
            } catch { }
        }

        $marker = if ($isActive) { '*' } else { ' ' }
        $identity = Get-AuthIdentity (Read-AuthFile $authFile)
        $plan = if ($identity.Plan) { $identity.Plan } else { '-' }

        if (-not $query.Ok) {
            $hadError = $true
            Write-Host ("{0} {1,-14} {2,-7} {3}" -f $marker, $acct, $plan, ('n/a  (' + $query.Error + ')')) -ForegroundColor DarkYellow
            continue
        }

        $snapshot = $query.Data.rateLimits
        $windows = @()
        if ($snapshot.primary) {
            $windows += [pscustomobject]@{ Label = (Format-WindowLabel $snapshot.primary.windowDurationMins); Data = $snapshot.primary }
        }
        if ($snapshot.secondary) {
            $windows += [pscustomobject]@{ Label = (Format-WindowLabel $snapshot.secondary.windowDurationMins); Data = $snapshot.secondary }
        }

        if ($windows.Count -eq 0) {
            $hadError = $true
            Write-Host ("{0} {1,-14} {2,-7} {3}" -f $marker, $acct, $plan, 'n/a  (no usage windows reported)') -ForegroundColor DarkYellow
            continue
        }

        $first = $true
        foreach ($window in $windows) {
            $left = 100 - [int]$window.Data.usedPercent
            if ($left -lt 0) { $left = 0 }
            if ($left -gt 100) { $left = 100 }
            $bar = Get-LimitBar $left
            $reset = Get-ResetText $window.Data

            if ($first) {
                Write-Host ("{0} {1,-14} {2,-7} " -f $marker, $acct, $plan) -NoNewline
            } else {
                Write-Host ("  {0,-14} {1,-7} " -f '', '') -NoNewline
            }
            Write-Host ("{0,-6} " -f $window.Label) -NoNewline
            $color = if ($left -ge 50) { 'Green' } elseif ($left -ge 20) { 'Yellow' } else { 'Red' }
            Write-Host ("{0,3}% left " -f $left) -NoNewline -ForegroundColor $color
            Write-Host ("[{0}]  {1}" -f $bar, $reset)
            $first = $false
        }

        $credits = $query.Data.rateLimitResetCredits
        if ($credits -and [int]$credits.availableCount -gt 0) {
            Write-Host ("  {0,-14} {1,-7} {2}" -f '', '', ("{0} rate-limit reset credit(s) available" -f [int]$credits.availableCount)) -ForegroundColor DarkCyan
        }
    }

    Write-Host ''
    Write-Host '  * = active account' -ForegroundColor DarkGray
    Write-Host '  Usage is read live; no account switch is performed.' -ForegroundColor DarkGray
    if ($hadError) {
        Write-Host '  n/a usually means the saved login expired - refresh it with: codex-switch login <name>' -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ---------------------------------------------------------------- commands
function Show-Accounts {
    $names = @(Get-AccountNames)
    $active = Get-ActiveName
    $live = Read-AuthFile $AuthPath
    if ($names.Count -eq 0) {
        Write-WarnMsg 'No accounts saved yet.'
        Write-Host "Current login : $(Format-Identity (Get-AuthIdentity $live))"
        Write-Host 'Save it with  : codex-switch import <name>'
        Write-Host 'Add another   : codex-switch login <name>'
        return
    }
    Write-Host ''
    Write-Host "Saved accounts   (snapshots: $AccountsDir)"
    Write-Host ''
    foreach ($acct in $names) {
        $id = Get-AuthIdentity (Read-AuthFile (Get-AccountPath $acct))
        if ($acct -eq $active) {
            Write-Host ('* ' + $acct.PadRight(14) + ' ' + (Format-Identity $id)) -ForegroundColor Green
        } else {
            Write-Host ('  ' + $acct.PadRight(14) + ' ' + (Format-Identity $id))
        }
    }
    Write-Host ''
    if ($active) { Write-Host ("Active: {0}   ->   {1}" -f $active, $AuthPath) }
    else { Write-Host ("Active: (none)   ->   {0}" -f $AuthPath) }
    if ($live) { Write-Host ("Live auth.json: {0}" -f (Format-Identity (Get-AuthIdentity $live))) }
    Write-Host ''
    Write-Host 'Switch:  codex-switch next      (toggle between accounts)'
    Write-Host '         codex-switch use <name>'
    Write-Host ''
}

function Show-Whoami {
    $active = Get-ActiveName
    $live = Read-AuthFile $AuthPath
    if ($active) { Write-Host ("Active account : {0}" -f $active) }
    else { Write-Host 'Active account : (untracked login)' }
    Write-Host ("Current login  : {0}" -f (Format-Identity (Get-AuthIdentity $live)))
    Write-Host ("Auth file      : {0}" -f $AuthPath)
}

function Invoke-SwitchAccount([string]$Target) {
    Assert-ValidName $Target
    $source = Get-AccountPath $Target
    if (-not (Test-Path $source)) {
        Write-ErrMsg "No saved account named '$Target'."
        $saved = @(Get-AccountNames)
        if ($saved.Count -gt 0) { Write-Host ("Saved accounts: {0}" -f ($saved -join ', ')) }
        Write-Host 'Add one with: codex-switch login <name>'
        exit 1
    }
    $active = Get-ActiveName
    if ($active -eq $Target) {
        $id = Get-AuthIdentity (Read-AuthFile $AuthPath)
        Write-Ok ("Already using '{0}' ({1})." -f $Target, (Format-Identity $id))
        return
    }
    $previous = Save-LiveAuth
    Copy-Item -Path $source -Destination $AuthPath -Force
    Set-ActiveName $Target
    $newId = Get-AuthIdentity (Read-AuthFile $AuthPath)
    $fromText = 'no previous login'
    if ($previous) {
        $oldId = Get-AuthIdentity (Read-AuthFile (Get-AccountPath $previous))
        $fromText = "'$previous' ($(Format-Identity $oldId))"
    }
    Write-Host ''
    Write-Ok ("Switched: {0}  ->  '{1}' ({2})" -f $fromText, $Target, (Format-Identity $newId))
    Write-Host "Start a new codex session ('codex' or 'codex resume') to use '$Target'."
    Offer-DaemonRestart
}

function Invoke-NextAccount {
    $names = @(Get-AccountNames)
    if ($names.Count -eq 0) {
        Write-ErrMsg 'No accounts saved yet. Log one in with: codex-switch login <name>'
        exit 1
    }
    if ($names.Count -eq 1) {
        Write-ErrMsg ("Only one account saved ('{0}'). Add the second with: codex-switch login <name>" -f $names[0])
        exit 1
    }
    $active = Get-ActiveName
    $idx = [Array]::IndexOf($names, $active)
    $nextIndex = ($idx + 1) % $names.Count
    Invoke-SwitchAccount $names[$nextIndex]
}

function Invoke-Import([string]$Target) {
    Assert-ValidName $Target
    if (-not (Test-Path $AuthPath)) {
        Write-ErrMsg "No current login found at $AuthPath."
        Write-Host "Log in first, or use: codex-switch login $Target"
        exit 1
    }
    $live = Read-AuthFile $AuthPath
    if ($null -eq $live) { Write-ErrMsg 'auth.json could not be parsed.'; exit 1 }
    $dest = Get-AccountPath $Target
    if ((Test-Path $dest) -and -not (Confirm-Action "'$Target' already exists - overwrite it with the current login? [y/N] ")) {
        Write-Host 'Cancelled.'
        return
    }
    Copy-Item -Path $AuthPath -Destination $dest -Force
    Set-ActiveName $Target
    Write-Ok ("Saved current login as '{0}' ({1})." -f $Target, (Format-Identity (Get-AuthIdentity $live)))
}

function Invoke-Login([string]$Target, [string[]]$CodexArgs) {
    Assert-ValidName $Target
    if (-not $CodexExe) {
        Write-ErrMsg 'codex was not found on PATH.'
        exit 1
    }
    $dest = Get-AccountPath $Target
    if ((Test-Path $dest) -and -not (Confirm-Action "'$Target' already exists - log in again and overwrite it? [y/N] ")) {
        Write-Host 'Cancelled.'
        return
    }
    Save-LiveAuth | Out-Null
    $pending = Join-Path $CodexHome 'auth.json.pre-login-backup'
    $hadLive = Test-Path $AuthPath
    if ($hadLive) { Copy-Item -Path $AuthPath -Destination $pending -Force }
    try {
        if ($hadLive) { Remove-Item -Path $AuthPath -Force }
        Write-Step "Launching 'codex login' - finish the sign-in in your browser..."
        if ($CodexArgs -and $CodexArgs.Count -gt 0) { & $CodexExe login @CodexArgs } else { & $CodexExe login }
        if ($LASTEXITCODE -ne 0) { throw ("codex login exited with code {0}" -f $LASTEXITCODE) }
        $new = Read-AuthFile $AuthPath
        if ($null -eq $new) { throw 'codex login finished but no readable auth.json was produced' }
        Copy-Item -Path $AuthPath -Destination $dest -Force
        Set-ActiveName $Target
        Write-Ok ("Logged in as '{0}' ({1})." -f $Target, (Format-Identity (Get-AuthIdentity $new)))
        foreach ($other in @(Get-AccountNames | Where-Object { $_ -ne $Target })) {
            if (Test-SameAccount $new (Read-AuthFile (Get-AccountPath $other))) {
                Write-WarnMsg ("! '{0}' is the same ChatGPT account as '{1}'." -f $Target, $other)
            }
        }
        if (Test-Path $pending) { Remove-Item -Path $pending -Force }
    } catch {
        if (Test-Path $pending) {
            Copy-Item -Path $pending -Destination $AuthPath -Force
            Remove-Item -Path $pending -Force
            Write-WarnMsg 'Login cancelled or failed - previous login restored.'
        }
        throw
    }
    Offer-DaemonRestart
}

function Invoke-Remove([string]$Target) {
    Assert-ValidName $Target
    $dest = Get-AccountPath $Target
    if (-not (Test-Path $dest)) { Write-ErrMsg "No saved account named '$Target'."; exit 1 }
    if ((Get-ActiveName) -eq $Target) {
        Write-ErrMsg "'$Target' is the active account. Switch to another one first (codex-switch next)."
        exit 1
    }
    if (-not (Confirm-Action "Delete saved account '$Target'? [y/N] ")) { Write-Host 'Cancelled.'; return }
    Remove-Item -Path $dest -Force
    Write-Ok "Removed '$Target'."
}

function Show-Help {
    @'
codex-switch - switch between multiple Codex accounts, sharing one local workspace

Usage:
  codex-switch <command> [name] [extra-args...] [-y] [-f]

Commands:
  next                     Switch to the next saved account (with 2 accounts: toggles).
  use <name>               Switch to a specific saved account. (switch / set)
  list                     Show saved accounts and which one is active. (ls / status)
  limits                   Show live rate-limit usage for every saved account. (usage)
  whoami                   Show the account Codex is currently logged in with.
  import <name>            Save the CURRENT login (auth.json) as <name>.
  login <name> [args...]   Log in a new account (runs "codex login": browser flow),
                           then saves it as <name>. Extra args go to "codex login".
  remove <name>            Delete a saved account. (rm / delete)
  help                     Show this help.

Flags:
  -y, -yes                 Don't ask for confirmation.
  -f, -force               Same as -y.

Notes:
  * All accounts share CODEX_HOME (sessions, threads, history, config), so
    "codex resume" shows chats from every account. Nothing is stored in the cloud.
  * After switching, start a new codex session. If the Codex Desktop app or its
    app-server daemon is running, codex-switch offers to restart it so the
    Desktop/IDE pick up the new account too.
'@ | Write-Host
}

# ---------------------------------------------------------------- dispatch
$cmd = ''
if ($Command) { $cmd = $Command.ToLowerInvariant() }

if (-not $cmd) {
    Show-Help
    Write-Host ''
    Show-Whoami
    exit 0
}

if ($cmd -in @('list', 'ls', 'status', 'accounts')) { Show-Accounts; exit 0 }
if ($cmd -in @('limits', 'limit', 'usage', 'remaining')) { Show-Limits; exit 0 }
if ($cmd -in @('next', 'toggle', 'swap')) { Invoke-NextAccount; exit 0 }
if ($cmd -in @('use', 'switch', 'set')) {
    if (-not $Name) { Write-ErrMsg 'Usage: codex-switch use <name>'; exit 1 }
    Invoke-SwitchAccount $Name; exit 0
}
if ($cmd -in @('import', 'add', 'init', 'save')) {
    if (-not $Name) { Write-ErrMsg 'Usage: codex-switch import <name>'; exit 1 }
    Invoke-Import $Name; exit 0
}
if ($cmd -in @('login', 'signin', 'new')) {
    if (-not $Name) { Write-ErrMsg 'Usage: codex-switch login <name> [extra args for codex login]'; exit 1 }
    Invoke-Login $Name $Extra; exit 0
}
if ($cmd -in @('remove', 'rm', 'delete', 'del')) {
    if (-not $Name) { Write-ErrMsg 'Usage: codex-switch remove <name>'; exit 1 }
    Invoke-Remove $Name; exit 0
}
if ($cmd -in @('whoami', 'current', 'me')) { Show-Whoami; exit 0 }
if ($cmd -in @('help', '-h', '--help', '/?', '-?')) { Show-Help; exit 0 }

if (@(Get-AccountNames) -contains $Command) { Invoke-SwitchAccount $Command; exit 0 }

Write-ErrMsg "Unknown command or account: '$Command'"
Write-Host ''
Show-Help
exit 1
