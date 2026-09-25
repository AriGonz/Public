# =============================================================================
# Install-RustDesk.ps1
#
# What:  Installs RustDesk on Windows (x64) and optionally points it at a
#        self-hosted / private relay.
# Why:   One script you can curl / irm from a public GitHub repo - no baked-in
#        secrets, no org-specific defaults.
# How:   Run elevated (Administrator or SYSTEM). Auto install order:
#        winget -> Chocolatey (rustdesk.install) -> official GitHub .exe.
# Exit:  0 on success / already installed (+ relay OK when requested) /
#        uninstalled or not present; 1 if install, relay, or uninstall fails.
#
# SECURITY
#   Never put a relay private key (or any real key) in this file or in git.
#   Pass -Server / -Key at run time, or set RUSTDESK_SERVER / RUSTDESK_KEY.
#   -SkipRelay installs the client only (public RustDesk network).
#
# ---------------------------------------------------------------------------
# HOW TO USE
# ---------------------------------------------------------------------------
#
# 1) Download then run (clearest; args always work):
#
#   curl.exe -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/Install-RustDesk.ps1 `
#     -o Install-RustDesk.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-RustDesk.ps1 `
#     -Server 'relay.example.com' -Key 'YOUR_PUBLIC_KEY_BASE64'
#
# 2) Env vars + irm | iex (good one-liner; set secrets in the shell first):
#
#   $env:RUSTDESK_SERVER = 'relay.example.com'
#   $env:RUSTDESK_KEY    = 'YOUR_PUBLIC_KEY_BASE64'
#   irm https://raw.githubusercontent.com/OWNER/REPO/main/Install-RustDesk.ps1 | iex
#
# 3) irm into a scriptblock (pass named params without saving a file):
#
#   $s = Invoke-RestMethod https://raw.githubusercontent.com/OWNER/REPO/main/Install-RustDesk.ps1
#   & ([scriptblock]::Create($s)) -Server 'relay.example.com' -Key 'YOUR_PUBLIC_KEY_BASE64'
#
# 4) Install client only (no private relay):
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-RustDesk.ps1 -SkipRelay
#
# 5) Force reinstall / pick a source / uninstall:
#
#   .\Install-RustDesk.ps1 -Server 'relay.example.com' -Key 'YOUR_PUBLIC_KEY_BASE64' -Force
#   .\Install-RustDesk.ps1 -Source Official -SkipRelay
#   .\Install-RustDesk.ps1 -Uninstall
#
# Notes:
#   - Replace OWNER/REPO with the GitHub path that hosts this file.
#   - irm | iex alone cannot take -Server/-Key on the same line; use env vars
#     or the scriptblock pattern above.
#   - ASCII-only strings (safe for Windows PowerShell 5.1).
# =============================================================================

[CmdletBinding()]
param(
    # Auto = winget, then Chocolatey, then official GitHub download.
    [ValidateSet('Auto', 'Winget', 'Chocolatey', 'Official')]
    [string]$Source = 'Auto',

    # Private / self-hosted rendezvous + relay hostname (no scheme, no path).
    # Also read from $env:RUSTDESK_SERVER when this is empty.
    [string]$Server = '',

    # Relay public key (base64). Also read from $env:RUSTDESK_KEY when empty.
    # Never commit a real value into this script.
    [string]$Key = '',

    # Install the client but do not write RustDesk2.toml / configure a relay.
    [switch]$SkipRelay,

    # Reinstall even if RustDesk is already detected (relay config still runs
    # unless -SkipRelay).
    [switch]$Force,

    # Uninstall instead of install (winget -> choco -> registry).
    [switch]$Uninstall,

    # Only load functions (for a multi-app launcher). Does not install.
    [switch]$DotSourceOnly
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# === CONFIG (no secrets; org-agnostic) ===

if (-not $Server -and $env:RUSTDESK_SERVER) { $Server = $env:RUSTDESK_SERVER.Trim() }
if (-not $Key -and $env:RUSTDESK_KEY)       { $Key    = $env:RUSTDESK_KEY.Trim() }

$script:RustDeskServer = $Server
$script:RustDeskKey    = $Key

# Winget id is often missing from the community source - still try in Auto.
$script:WingetId = 'RustDesk.RustDesk'
# Prefer rustdesk.install (MSI). Meta package 'rustdesk' can report installed
# without placing rustdesk.exe.
$script:ChocoId  = 'rustdesk.install'

$script:GitHubLatestApi = 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest'
$script:OfficialUrls = @()

$script:DownloadDir = Join-Path $env:TEMP 'install-rustdesk'

# === HELPERS ===

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host "=== $Title ==="
}

function Mask-Secret([string]$Value) {
    if (-not $Value) { return '(none)' }
    if ($Value.Length -le 8) { return '****' }
    return ($Value.Substring(0, 4) + '...' + $Value.Substring($Value.Length - 4))
}

function Find-RustDeskExe {
    $candidates = @(
        'C:\Program Files\RustDesk\rustdesk.exe',
        'C:\Program Files\RustDesk\RustDesk.exe',
        'C:\Program Files (x86)\RustDesk\rustdesk.exe',
        'C:\Program Files (x86)\RustDesk\RustDesk.exe',
        'C:\ProgramData\chocolatey\bin\rustdesk.exe'
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) {
            Write-Host "RustDesk exe (known path): $p"
            return (Get-Item -LiteralPath $p).FullName
        }
    }

    $cmd = Get-Command rustdesk -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) {
        Write-Host "RustDesk exe (Get-Command): $($cmd.Source)"
        return $cmd.Source
    }

    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $props = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'RustDesk' }
    foreach ($prop in $props) {
        foreach ($field in @($prop.DisplayIcon, $prop.InstallLocation)) {
            if (-not $field) { continue }
            $exe = $field -replace ',.*$', ''
            if ($exe -and (Test-Path -LiteralPath $exe) -and ($exe -match 'rustdesk\.exe$')) {
                Write-Host "RustDesk exe (registry): $exe"
                return (Get-Item -LiteralPath $exe).FullName
            }
            if ($prop.InstallLocation) {
                $try = Join-Path $prop.InstallLocation 'rustdesk.exe'
                if (Test-Path -LiteralPath $try) {
                    Write-Host "RustDesk exe (InstallLocation): $try"
                    return (Get-Item -LiteralPath $try).FullName
                }
                $try2 = Join-Path $prop.InstallLocation 'RustDesk.exe'
                if (Test-Path -LiteralPath $try2) {
                    Write-Host "RustDesk exe (InstallLocation): $try2"
                    return (Get-Item -LiteralPath $try2).FullName
                }
            }
        }
    }

    $found = Get-ChildItem 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData\chocolatey' `
        -Recurse -Filter 'rustdesk.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($found) {
        Write-Host "RustDesk exe (search): $found"
        return $found
    }

    return $null
}

function Test-RustDeskInstalled {
    $exe = Find-RustDeskExe
    if ($exe) {
        Write-Host "Detected: $exe"
        return $true
    }
    return $false
}

function Find-Winget {
    $candidates = @(
        (Get-Command winget -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    )
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $resolved = Get-Item $c -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        if ($resolved -and (Test-Path -LiteralPath $resolved)) { return $resolved }
    }
    $g = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($g) { return $g.FullName }
    return $null
}

function Install-ChocolateyIfMissing {
    if (Get-Command choco -ErrorAction SilentlyContinue) { return $true }
    Write-Host 'Chocolatey not found - installing...'
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path', 'User')
        return [bool](Get-Command choco -ErrorAction SilentlyContinue)
    } catch {
        Write-Host "Chocolatey install failed: $_"
        return $false
    }
}

function Install-ViaWinget {
    $winget = Find-Winget
    if (-not $winget) {
        Write-Host 'winget: not found'
        return $false
    }
    Write-Host "winget: $winget"
    Write-Host "winget: install $($script:WingetId) ..."
    & $winget install --id $script:WingetId -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --scope machine 2>&1 | Out-Host
    $code = $LASTEXITCODE
    # 0 = ok; -1978335189 = already installed
    if ($code -eq 0 -or $code -eq -1978335189) {
        Write-Host "winget: OK (exit $code)"
        return $true
    }
    Write-Host "winget: FAIL (exit $code)"
    return $false
}

function Install-ViaChocolatey {
    if (-not (Install-ChocolateyIfMissing)) {
        Write-Host 'choco: unavailable'
        return $false
    }
    Write-Host "choco: install $($script:ChocoId) ..."
    & choco install $script:ChocoId -y --no-progress --ignore-checksums 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0) {
        if (Find-RustDeskExe) {
            Write-Host 'choco: OK (exe present)'
            return $true
        }
        Write-Host 'choco: package OK but exe missing - forcing rustdesk.install'
        & choco install rustdesk.install -y --force --no-progress --ignore-checksums 2>&1 | Out-Host
        if (Find-RustDeskExe) {
            Write-Host 'choco: OK after force (exe present)'
            return $true
        }
        Write-Host 'choco: FAIL (exe still missing)'
        return $false
    }
    Write-Host "choco: FAIL (exit $LASTEXITCODE)"
    return $false
}

function Get-OfficialInstaller {
    if (-not (Test-Path -LiteralPath $script:DownloadDir)) {
        New-Item -ItemType Directory -Path $script:DownloadDir -Force | Out-Null
    }

    $urls = @()
    Write-Host "GitHub API: $($script:GitHubLatestApi)"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = 'Install-RustDesk.ps1' }
        $release = Invoke-RestMethod -Uri $script:GitHubLatestApi -Headers $headers -UseBasicParsing
        $asset = $release.assets |
            Where-Object {
                $_.name -match 'x86_64' -and
                $_.name -match '\.exe$' -and
                $_.name -notmatch '\.(apk|deb|rpm|dmg|AppImage)$' -and
                $_.name -notmatch 'android|ios|linux|macos'
            } |
            Select-Object -First 1
        if (-not $asset) {
            $asset = $release.assets |
                Where-Object { $_.name -match 'windows.*x86_64.*\.exe$' -or $_.name -match 'x86_64.*\.exe$' } |
                Where-Object { $_.name -notmatch 'sciter|portable' } |
                Select-Object -First 1
        }
        if ($asset -and $asset.browser_download_url) {
            Write-Host "Latest asset: $($asset.name)"
            $urls += $asset.browser_download_url
        } else {
            Write-Host 'GitHub API: no Windows x86_64 .exe asset found'
        }
    } catch {
        Write-Host "GitHub API failed: $_"
    }

    foreach ($u in $script:OfficialUrls) {
        if ($urls -notcontains $u) { $urls += $u }
    }

    if ($urls.Count -eq 0) {
        Write-Host 'official: no download URLs'
        return $null
    }

    $outFile = Join-Path $script:DownloadDir 'rustdesk-installer.exe'
    foreach ($url in $urls) {
        Write-Host "Download: $url"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $headers = @{ 'User-Agent' = 'Install-RustDesk.ps1' }
            Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing -MaximumRedirection 5 -Headers $headers
            if ((Test-Path -LiteralPath $outFile) -and ((Get-Item -LiteralPath $outFile).Length -gt 1MB)) {
                $mb = [math]::Round((Get-Item -LiteralPath $outFile).Length / 1MB, 1)
                Write-Host "Saved: $outFile ($mb MB)"
                return $outFile
            }
            Write-Host 'Download too small or empty - try next URL'
        } catch {
            Write-Host "Download failed: $_"
        }
    }
    return $null
}

function Install-ViaOfficial {
    $installer = Get-OfficialInstaller
    if (-not $installer) {
        Write-Host 'official: no installer downloaded'
        return $false
    }
    Write-Host "official: silent install $installer (--silent-install)"
    $p = Start-Process -FilePath $installer `
        -ArgumentList @('--silent-install') `
        -Wait -PassThru
    $code = $p.ExitCode
    if ($code -eq 0) {
        Write-Host "official: OK (exit $code)"
        return $true
    }
    Write-Host "official: FAIL (exit $code)"
    return $false
}

function Set-RustDeskRelay {
    <#
    .SYNOPSIS
      Write RustDesk2.toml for a private relay across common config dirs,
      refresh the service, and print the device ID.
    #>
    if (-not $script:RustDeskServer -or -not $script:RustDeskKey) {
        Write-Host 'Relay: Server and Key are both required (use -Server/-Key or RUSTDESK_SERVER/RUSTDESK_KEY, or pass -SkipRelay).'
        return $false
    }

    $exe = Find-RustDeskExe
    if (-not $exe) {
        Write-Host 'RustDesk exe not found - forcing choco rustdesk.install...'
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            & choco install rustdesk.install -y --force --no-progress --ignore-checksums 2>&1 | Out-Host
            $exe = Find-RustDeskExe
        }
    }
    if (-not $exe) {
        Write-Host 'RustDesk exe not found - skip relay config'
        return $false
    }

    Write-Host "Using RustDesk exe: $exe"
    Write-Host ("Relay server: {0}" -f $script:RustDeskServer)
    Write-Host ("Relay key:    {0}" -f (Mask-Secret $script:RustDeskKey))

    $toml = @"
rendezvous_server = '$($script:RustDeskServer)'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '$($script:RustDeskServer)'
relay-server = '$($script:RustDeskServer)'
key = '$($script:RustDeskKey)'
api-server = ''
"@

    $dirs = @(
        "$env:APPDATA\RustDesk\config",
        'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config'
    )
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $u = Join-Path $_.FullName 'AppData\Roaming\RustDesk\config'
        if ($dirs -notcontains $u) { $dirs += $u }
    }
    foreach ($d in $dirs) {
        try {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            Set-Content -Path (Join-Path $d 'RustDesk2.toml') -Value $toml -Encoding ascii
            Write-Host "Wrote RustDesk2.toml -> $d"
        } catch {
            Write-Host "Skip config dir $d : $_"
        }
    }

    # Install / refresh service (non-blocking - -Wait can hang under SYSTEM)
    Start-Process -FilePath $exe -ArgumentList '--install-service' -WindowStyle Hidden -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Get-Service | Where-Object { $_.Name -match 'RustDesk' -or $_.DisplayName -match 'RustDesk' } | ForEach-Object {
        if ($_.Status -ne 'Running') {
            try { Start-Service $_.Name -ErrorAction SilentlyContinue } catch {}
        }
        Write-Host ("RustDesk service: {0} = {1}" -f $_.Name, $_.Status)
    }

    Write-Host '=== RustDesk ID ==='
    $rdId = cmd /c "`"$exe`" --get-id" 2>&1
    Write-Host $rdId
    Write-Host "Relay: $($script:RustDeskServer)"
    return $true
}

function Uninstall-ViaWinget {
    $winget = Find-Winget
    if (-not $winget) {
        Write-Host 'winget: not found'
        return $false
    }
    Write-Host "winget: $winget"
    Write-Host "winget: uninstall $($script:WingetId) (machine scope) ..."
    & $winget uninstall --id $script:WingetId -e --silent --disable-interactivity --accept-source-agreements --scope machine 2>&1 | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Host "winget: machine-scope exit $code - retry without --scope"
        & $winget uninstall --id $script:WingetId -e --silent --disable-interactivity --accept-source-agreements 2>&1 | Out-Host
        $code = $LASTEXITCODE
    }
    # 0 = ok; -1978335212 = no applicable package / already gone
    if ($code -eq 0 -or $code -eq -1978335212) {
        Write-Host "winget uninstall: OK (exit $code)"
        return $true
    }
    Write-Host "winget uninstall: FAIL (exit $code)"
    return $false
}

function Uninstall-ViaChocolatey {
    param(
        [string[]]$PackageIds = @($script:ChocoId)
    )
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host 'choco: not found'
        return $false
    }
    $anyOk = $false
    foreach ($id in $PackageIds) {
        if (-not $id) { continue }
        Write-Host "choco: uninstall $id ..."
        & choco uninstall $id -y --no-progress 2>&1 | Out-Host
        if ($LASTEXITCODE -eq 0) {
            Write-Host "choco uninstall: OK ($id)"
            $anyOk = $true
        } else {
            Write-Host "choco uninstall: FAIL ($id) exit $LASTEXITCODE"
        }
    }
    return $anyOk
}

function Get-UninstallRegistryEntries {
    param(
        [Parameter(Mandatory)][string]$DisplayNamePattern
    )
    $reg = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $reg -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and ($_.DisplayName -match $DisplayNamePattern) }
}

function Invoke-RegistryUninstallString {
    param(
        [Parameter(Mandatory)]$Entry,
        [string[]]$ExeSilentFlags = @('/S')
    )
    $cmd = $null
    $preferQuiet = $false
    if ($Entry.QuietUninstallString) {
        $cmd = [string]$Entry.QuietUninstallString
        $preferQuiet = $true
        Write-Host "registry: QuietUninstallString = $cmd"
    } elseif ($Entry.UninstallString) {
        $cmd = [string]$Entry.UninstallString
        Write-Host "registry: UninstallString = $cmd"
    } else {
        if ($Entry.PSChildName -match '^\{[0-9A-Fa-f\-]+\}$') {
            Write-Host "registry: no UninstallString; trying msiexec /x $($Entry.PSChildName) /qn /norestart"
            $p = Start-Process -FilePath 'msiexec.exe' `
                -ArgumentList @('/x', $Entry.PSChildName, '/qn', '/norestart') `
                -Wait -PassThru
            $code = $p.ExitCode
            if ($code -eq 0 -or $code -eq 3010 -or $code -eq 1605) {
                Write-Host "registry MSI: OK (exit $code)"
                return $true
            }
            Write-Host "registry MSI: FAIL (exit $code)"
            return $false
        }
        Write-Host 'registry: no UninstallString on entry'
        return $false
    }

    if ($cmd -match '(?i)msiexec(\.exe)?') {
        $guid = $null
        if ($cmd -match '\{[0-9A-Fa-f\-]+\}') { $guid = $Matches[0] }
        if (-not $guid -and $Entry.PSChildName -match '^\{[0-9A-Fa-f\-]+\}$') {
            $guid = $Entry.PSChildName
        }
        if ($guid) {
            Write-Host "registry: msiexec /x $guid /qn /norestart"
            $p = Start-Process -FilePath 'msiexec.exe' `
                -ArgumentList @('/x', $guid, '/qn', '/norestart') `
                -Wait -PassThru
            $code = $p.ExitCode
            if ($code -eq 0 -or $code -eq 3010 -or $code -eq 1605) {
                Write-Host "registry MSI: OK (exit $code)"
                return $true
            }
            Write-Host "registry MSI: FAIL (exit $code)"
            return $false
        }
    }

    $exe = $null
    $argLine = ''
    if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') {
        $exe = $Matches[1]
        $argLine = $Matches[2].Trim()
    } elseif ($cmd -match '^\s*(\S+)\s*(.*)$') {
        $exe = $Matches[1]
        $argLine = $Matches[2].Trim()
    }
    if (-not $exe) {
        Write-Host "registry: could not parse uninstall command: $cmd"
        return $false
    }
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Host "registry: uninstall exe missing: $exe"
        return $false
    }

    $argList = @()
    if ($argLine) {
        $argList = $argLine -split '\s+' | Where-Object { $_ }
    }
    if (-not $preferQuiet) {
        foreach ($f in $ExeSilentFlags) {
            if ($argList -notcontains $f) { $argList += $f }
        }
    }

    Write-Host ("registry: Start-Process {0} {1}" -f $exe, ($argList -join ' '))
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru
        $code = $p.ExitCode
        if ($code -eq 0 -or $null -eq $code) {
            Write-Host "registry EXE: OK (exit $code)"
            return $true
        }
        Write-Host "registry EXE: FAIL (exit $code)"
        return $false
    } catch {
        Write-Host "registry EXE: exception $_"
        return $false
    }
}

function Uninstall-ViaRegistry {
    param(
        [Parameter(Mandatory)][string]$DisplayNamePattern,
        [string[]]$ExeSilentFlags = @('/S')
    )
    $entries = @(Get-UninstallRegistryEntries -DisplayNamePattern $DisplayNamePattern)
    if ($entries.Count -eq 0) {
        Write-Host 'registry: no matching Uninstall entries'
        return $false
    }
    $anyOk = $false
    foreach ($e in $entries) {
        Write-Host "registry: entry $($e.DisplayName) $($e.DisplayVersion)"
        if (Invoke-RegistryUninstallString -Entry $e -ExeSilentFlags $ExeSilentFlags) {
            $anyOk = $true
        }
    }
    return $anyOk
}

function Uninstall-RustDesk {
    [CmdletBinding()]
    param()

    Write-Section 'RustDesk (Uninstall)'

    if (-not (Test-RustDeskInstalled)) {
        Write-Host 'Not installed - nothing to do'
        return $true
    }

    Write-Host 'Uninstall Auto: try winget...'
    [void](Uninstall-ViaWinget)
    if (-not (Test-RustDeskInstalled)) {
        Write-Host 'Verify: uninstalled (winget)'
        Write-Host 'RESULT: SUCCESS'
        return $true
    }

    Write-Host 'Uninstall Auto: still present - try Chocolatey...'
    $chocoIds = @('rustdesk.install', 'rustdesk', $script:ChocoId) | Select-Object -Unique
    [void](Uninstall-ViaChocolatey -PackageIds $chocoIds)
    if (-not (Test-RustDeskInstalled)) {
        Write-Host 'Verify: uninstalled (choco)'
        Write-Host 'RESULT: SUCCESS'
        return $true
    }

    Write-Host 'Uninstall Auto: still present - try registry QuietUninstallString/UninstallString...'
    [void](Uninstall-ViaRegistry -DisplayNamePattern 'RustDesk' -ExeSilentFlags @('--uninstall', '--silent'))
    if (-not (Test-RustDeskInstalled)) {
        Write-Host 'Verify: uninstalled (registry)'
        Write-Host 'RESULT: SUCCESS'
        return $true
    }

    Write-Host 'RESULT: FAILED (still installed after winget/choco/registry)'
    return $false
}

function Install-RustDesk {
    <#
    .SYNOPSIS
      Install RustDesk via winget, Chocolatey, and/or official GitHub exe,
      then optionally configure a private relay from -Server/-Key (or env).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'Winget', 'Chocolatey', 'Official')]
        [string]$Source = 'Auto',
        [switch]$Force,
        [switch]$Uninstall,
        [switch]$SkipRelay
    )

    if ($Uninstall) {
        return Uninstall-RustDesk
    }

    Write-Section "RustDesk ($Source)"

    $already = Test-RustDeskInstalled
    $ok = $false

    if (-not $Force -and $already) {
        Write-Host 'Already installed - skip install (use -Force to reinstall)'
        $ok = $true
    } else {
        switch ($Source) {
            'Winget'     { $ok = Install-ViaWinget }
            'Chocolatey' { $ok = Install-ViaChocolatey }
            'Official'   { $ok = Install-ViaOfficial }
            'Auto' {
                $ok = Install-ViaWinget
                if (-not $ok) {
                    Write-Host 'Auto: winget failed - try Chocolatey'
                    $ok = Install-ViaChocolatey
                }
                if (-not $ok) {
                    Write-Host 'Auto: Chocolatey failed - try official download'
                    $ok = Install-ViaOfficial
                }
            }
        }

        if ($ok -and -not (Find-RustDeskExe)) {
            Write-Host 'Package reported OK but exe missing - forcing rustdesk.install'
            if (Install-ChocolateyIfMissing) {
                & choco install rustdesk.install -y --force --no-progress --ignore-checksums 2>&1 | Out-Host
                $ok = [bool](Find-RustDeskExe)
            } else {
                $ok = $false
            }
        }
    }

    if (-not $ok) {
        Write-Host 'RESULT: FAILED (install)'
        return $false
    }

    if ($SkipRelay) {
        Write-Host 'SkipRelay: leaving client on default (public) network'
    } else {
        if (-not $script:RustDeskServer -or -not $script:RustDeskKey) {
            Write-Host 'RESULT: FAILED (relay config needs -Server and -Key, or RUSTDESK_SERVER and RUSTDESK_KEY; or pass -SkipRelay)'
            return $false
        }
        Write-Section 'Configure RustDesk private relay'
        if (-not (Set-RustDeskRelay)) {
            Write-Host 'RESULT: FAILED (relay config)'
            return $false
        }
    }

    if (Test-RustDeskInstalled) {
        Write-Host 'Verify: installed'
    } else {
        Write-Host 'Verify: configured but exe not seen yet (may need refresh)'
    }
    Write-Host 'RESULT: SUCCESS'
    return $true
}

# === MAIN (skipped when -DotSourceOnly) ===

if ($DotSourceOnly) {
    return
}

if ($Uninstall) {
    $ok = Uninstall-RustDesk
} else {
    $ok = Install-RustDesk -Source $Source -Force:$Force -SkipRelay:$SkipRelay
}
exit $(if ($ok) { 0 } else { 1 })
