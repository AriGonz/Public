# =============================================================================
# Install-RustDesk.ps1
#
# What:  Installs (or uninstalls) stock RustDesk on Windows (x64) using the
#        public / default RustDesk network. Stock client only (no custom backend).
# Why:   One script you can curl / irm from a public GitHub repo.
# How:   Run elevated (Administrator or SYSTEM). Auto install order:
#        winget -> Chocolatey (rustdesk.install) -> official GitHub .exe.
# Exit:  0 on success / already installed / uninstalled or not present;
#        1 if install or uninstall fails.
#
# ---------------------------------------------------------------------------
# HOW TO USE
# ---------------------------------------------------------------------------
#
# 1) Download then run (clearest; args always work):
#
#   curl.exe -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/Install-RustDesk.ps1 `
#     -o Install-RustDesk.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-RustDesk.ps1
#
# 2) irm | iex (one-liner):
#
#   irm https://raw.githubusercontent.com/OWNER/REPO/main/Install-RustDesk.ps1 | iex
#
# 3) irm into a scriptblock (pass named params without saving a file):
#
#   $s = Invoke-RestMethod https://raw.githubusercontent.com/OWNER/REPO/main/Install-RustDesk.ps1
#   & ([scriptblock]::Create($s)) -Force
#   & ([scriptblock]::Create($s)) -Source Official
#   & ([scriptblock]::Create($s)) -Uninstall
#
# 4) Force reinstall / pick a source / uninstall:
#
#   .\Install-RustDesk.ps1 -Force
#   .\Install-RustDesk.ps1 -Source Official
#   .\Install-RustDesk.ps1 -Uninstall
#
# Notes:
#   - Replace OWNER/REPO with the GitHub path that hosts this file
#     (e.g. AriGonz/Public).
#   - ASCII-only strings (safe for Windows PowerShell 5.1).
# =============================================================================

[CmdletBinding()]
param(
    # Auto = winget, then Chocolatey, then official GitHub download.
    [ValidateSet('Auto', 'Winget', 'Chocolatey', 'Official')]
    [string]$Source = 'Auto',

    # Reinstall even if RustDesk is already detected.
    [switch]$Force,

    # Uninstall instead of install (winget -> choco -> registry).
    [switch]$Uninstall,

    # Only load functions (for a multi-app launcher). Does not install.
    [switch]$DotSourceOnly
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# === CONFIG (stock client only; org-agnostic) ===

# Winget id is often missing from the community source - still try in Auto.
$script:WingetId = 'RustDesk.RustDesk'
# Prefer rustdesk.install (MSI). Meta package 'rustdesk' can report installed
# without placing rustdesk.exe.
$script:ChocoId  = 'rustdesk.install'

$script:GitHubLatestApi = 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest'
$script:OfficialUrls = @()

$script:DownloadDir = Join-Path $env:TEMP 'install-rustdesk'

$script:NormalInstallRoots = @(
    'C:\Program Files\RustDesk',
    'C:\Program Files (x86)\RustDesk'
)

# === HELPERS ===

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host "=== $Title ==="
}

function Test-PathIsNormalRustDeskExe {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $Path) { return $false }
    $full = $null
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $full = (Get-Item -LiteralPath $Path).FullName
    } catch {
        return $false
    }
    if ($full -notmatch '(?i)[\\/]rustdesk\.exe$') { return $false }
    # Require the exe's parent directory to equal a known install root.
    # A prefix-only check would accept C:\Program Files\RustDesk-Portable\...
    $parent = [System.IO.Path]::GetDirectoryName($full)
    if (-not $parent) { return $false }
    foreach ($root in $script:NormalInstallRoots) {
        $rootFull = $root.TrimEnd('\', '/')
        if ([string]::Equals($parent, $rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-RustDeskUninstallEntries {
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    @(Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and ($_.DisplayName -match 'RustDesk') })
}

function Test-RustDeskInstalled {
    # Authoritative install check: HKLM uninstall entry + real Program Files exe
    # (or winget list / RustDesk service with Program Files exe present).
    # Never use PATH / Get-Command / chocolatey shims / recursive ProgramData search.

    $entries = Get-RustDeskUninstallEntries
    foreach ($prop in $entries) {
        if ($prop.InstallLocation) {
            foreach ($name in @('rustdesk.exe', 'RustDesk.exe')) {
                $try = Join-Path $prop.InstallLocation $name
                if (Test-Path -LiteralPath $try) {
                    Write-Host "Detected (registry InstallLocation): $try"
                    return $true
                }
            }
            foreach ($root in $script:NormalInstallRoots) {
                if ($prop.InstallLocation.TrimEnd('\') -ieq $root.TrimEnd('\')) {
                    foreach ($name in @('rustdesk.exe', 'RustDesk.exe')) {
                        $try = Join-Path $root $name
                        if (Test-Path -LiteralPath $try) {
                            Write-Host "Detected (InstallLocation root): $try"
                            return $true
                        }
                    }
                }
            }
        }
        if ($prop.DisplayIcon) {
            $exe = ([string]$prop.DisplayIcon) -replace ',.*$', ''
            if (Test-PathIsNormalRustDeskExe -Path $exe) {
                Write-Host "Detected (registry DisplayIcon): $exe"
                return $true
            }
        }
    }

    foreach ($root in $script:NormalInstallRoots) {
        foreach ($name in @('rustdesk.exe', 'RustDesk.exe')) {
            $try = Join-Path $root $name
            if (Test-Path -LiteralPath $try) {
                # Prefer registry proof; still accept Program Files exe when a
                # matching uninstall entry exists (InstallLocation may be empty).
                if ($entries.Count -gt 0) {
                    Write-Host "Detected (Program Files + uninstall entry): $try"
                    return $true
                }
            }
        }
    }

    $winget = Find-Winget
    if ($winget) {
        $listOut = & $winget list --id $script:WingetId -e --disable-interactivity 2>$null
        $listed = ($LASTEXITCODE -eq 0) -and ($listOut -match [regex]::Escape($script:WingetId))
        if ($listed) {
            foreach ($root in $script:NormalInstallRoots) {
                foreach ($name in @('rustdesk.exe', 'RustDesk.exe')) {
                    $try = Join-Path $root $name
                    if (Test-Path -LiteralPath $try) {
                        Write-Host "Detected (winget list + Program Files): $try"
                        return $true
                    }
                }
            }
        }
    }

    $svc = Get-Service -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '(?i)rustdesk' -or
            $_.DisplayName -match '(?i)rustdesk'
        } |
        Select-Object -First 1
    if ($svc) {
        foreach ($root in $script:NormalInstallRoots) {
            foreach ($name in @('rustdesk.exe', 'RustDesk.exe')) {
                $try = Join-Path $root $name
                if (Test-Path -LiteralPath $try) {
                    Write-Host "Detected (service + Program Files): $try"
                    return $true
                }
            }
        }
    }

    return $false
}

function Find-RustDeskExe {
    # Optional helper after a confirmed install (logging only).
    # Known Program Files paths + registry InstallLocation/DisplayIcon only.
    # No PATH / Get-Command; no recursive ProgramData/chocolatey search.
    $candidates = @(
        'C:\Program Files\RustDesk\rustdesk.exe',
        'C:\Program Files\RustDesk\RustDesk.exe',
        'C:\Program Files (x86)\RustDesk\rustdesk.exe',
        'C:\Program Files (x86)\RustDesk\RustDesk.exe'
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) {
            Write-Host "RustDesk exe (known path): $p"
            return (Get-Item -LiteralPath $p).FullName
        }
    }

    foreach ($prop in (Get-RustDeskUninstallEntries)) {
        if ($prop.DisplayIcon) {
            $exe = ([string]$prop.DisplayIcon) -replace ',.*$', ''
            if ($exe -and (Test-Path -LiteralPath $exe) -and ($exe -match '(?i)rustdesk\.exe$')) {
                Write-Host "RustDesk exe (registry DisplayIcon): $exe"
                return (Get-Item -LiteralPath $exe).FullName
            }
        }
        if ($prop.InstallLocation) {
            foreach ($name in @('rustdesk.exe', 'RustDesk.exe')) {
                $try = Join-Path $prop.InstallLocation $name
                if (Test-Path -LiteralPath $try) {
                    Write-Host "RustDesk exe (InstallLocation): $try"
                    return (Get-Item -LiteralPath $try).FullName
                }
            }
        }
    }

    return $null
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
    param([switch]$Force)

    $winget = Find-Winget
    if (-not $winget) {
        Write-Host 'winget: not found'
        return $false
    }
    Write-Host "winget: $winget"

    $didReinstall = $false
    if ($Force) {
        Write-Host "winget: -Force requested - uninstall then install $($script:WingetId)"
        & $winget uninstall --id $script:WingetId -e --silent --disable-interactivity --accept-source-agreements --scope machine 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            & $winget uninstall --id $script:WingetId -e --silent --disable-interactivity --accept-source-agreements 2>&1 | Out-Host
        }
        $didReinstall = $true
    }

    Write-Host "winget: install $($script:WingetId) ..."
    $installArgs = @(
        'install', '--id', $script:WingetId, '-e',
        '--silent', '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity', '--scope', 'machine'
    )
    if ($Force) {
        $installArgs += '--force'
    }
    & $winget @installArgs 2>&1 | Out-Host
    $code = $LASTEXITCODE
    # 0 = ok; -1978335189 = already installed
    if ($code -eq 0) {
        Write-Host "winget: OK (exit $code)"
        return $true
    }
    if ($code -eq -1978335189) {
        if ($Force -and -not $didReinstall) {
            Write-Host 'winget: FAIL (already installed with -Force but no reinstall ran)'
            return $false
        }
        if ($Force) {
            # Uninstall+install ran but winget still reported already-installed.
            # Treat as failure unless Test-RustDeskInstalled confirms a real install
            # after the caller verifies; here report false so Auto can try next source
            # only if verify would also fail - prefer requiring a real reinstall.
            Write-Host 'winget: FAIL (already installed exit after Force reinstall path)'
            return $false
        }
        Write-Host "winget: OK (exit $code already installed)"
        return $true
    }
    Write-Host "winget: FAIL (exit $code)"
    return $false
}

function Install-ViaChocolatey {
    param([switch]$Force)

    if (-not (Install-ChocolateyIfMissing)) {
        Write-Host 'choco: unavailable'
        return $false
    }

    $chocoArgs = @('install', $script:ChocoId, '-y', '--no-progress')
    if ($Force) {
        $chocoArgs += '--force'
        Write-Host "choco: install $($script:ChocoId) (with --force) ..."
    } else {
        Write-Host "choco: install $($script:ChocoId) ..."
    }
    & choco @chocoArgs 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0) {
        if (Test-RustDeskInstalled) {
            Write-Host 'choco: OK (installed)'
            return $true
        }
        Write-Host 'choco: package OK but not detected - forcing rustdesk.install'
        & choco install rustdesk.install -y --force --no-progress 2>&1 | Out-Host
        if (Test-RustDeskInstalled) {
            Write-Host 'choco: OK after force (installed)'
            return $true
        }
        Write-Host 'choco: FAIL (still not detected)'
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
    param([switch]$Force)

    if ($Force) {
        Write-Host 'official: -Force requested - download and run silent install again'
    }

    $installer = Get-OfficialInstaller
    if (-not $installer) {
        Write-Host 'official: no installer downloaded'
        return $false
    }
    Write-Host "official: silent install $installer (--silent-install)"
    try {
        $p = Start-Process -FilePath $installer `
            -ArgumentList @('--silent-install') `
            -Wait -PassThru -ErrorAction Stop
        if ($null -eq $p) {
            Write-Host 'official: FAIL (Start-Process returned null)'
            return $false
        }
        $code = $p.ExitCode
        if ($null -eq $code) {
            Write-Host 'official: FAIL (null exit code)'
            return $false
        }
        if ($code -eq 0) {
            Write-Host "official: OK (exit $code)"
            return $true
        }
        Write-Host "official: FAIL (exit $code)"
        return $false
    } catch {
        Write-Host "official: exception $_"
        return $false
    }
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

    # Always wrap the split pipeline in @(...) so a single token stays an array;
    # otherwise PowerShell collapses it to a string and += glues flags together.
    $argList = @()
    if ($argLine) {
        $argList = @($argLine -split '\s+' | Where-Object { $_ })
    }
    if (-not $preferQuiet) {
        foreach ($f in $ExeSilentFlags) {
            if ($argList -notcontains $f) { $argList += $f }
        }
    }

    Write-Host ("registry: Start-Process {0} {1}" -f $exe, ($argList -join ' '))
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru -ErrorAction Stop
        if ($null -eq $p) {
            Write-Host 'registry EXE: FAIL (Start-Process returned null)'
            return $false
        }
        $code = $p.ExitCode
        if ($null -eq $code) {
            Write-Host 'registry EXE: FAIL (null exit code)'
            return $false
        }
        if ($code -eq 0) {
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
      Install stock RustDesk via winget, Chocolatey, and/or official GitHub exe.
      Uses the public / default RustDesk network (stock client only).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'Winget', 'Chocolatey', 'Official')]
        [string]$Source = 'Auto',
        [switch]$Force,
        [switch]$Uninstall
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
        if ($Force -and $already) {
            Write-Host 'Already installed - Force reinstall requested'
        }
        switch ($Source) {
            'Winget'     { $ok = Install-ViaWinget -Force:$Force }
            'Chocolatey' { $ok = Install-ViaChocolatey -Force:$Force }
            'Official'   { $ok = Install-ViaOfficial -Force:$Force }
            'Auto' {
                $ok = Install-ViaWinget -Force:$Force
                if (-not $ok) {
                    Write-Host 'Auto: winget failed - try Chocolatey'
                    $ok = Install-ViaChocolatey -Force:$Force
                }
                if (-not $ok) {
                    Write-Host 'Auto: Chocolatey failed - try official download'
                    $ok = Install-ViaOfficial -Force:$Force
                }
            }
        }

        if ($ok -and -not (Test-RustDeskInstalled)) {
            Write-Host 'Package reported OK but install not detected - forcing rustdesk.install'
            if (Install-ChocolateyIfMissing) {
                & choco install rustdesk.install -y --force --no-progress 2>&1 | Out-Host
                $ok = Test-RustDeskInstalled
            } else {
                $ok = $false
            }
        }
    }

    if (-not $ok) {
        Write-Host 'RESULT: FAILED (install)'
        return $false
    }

    if (Test-RustDeskInstalled) {
        $exe = Find-RustDeskExe
        if ($exe) { Write-Host "Verify: installed ($exe)" }
        else { Write-Host 'Verify: installed' }
        Write-Host 'RESULT: SUCCESS'
        return $true
    }

    if ($Force) {
        Write-Host 'RESULT: FAILED (Force path did not leave a verified install)'
        return $false
    }

    Write-Host 'Verify: install reported OK but not detected yet (may need refresh)'
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
    $ok = Install-RustDesk -Source $Source -Force:$Force
}
exit $(if ($ok) { 0 } else { 1 })
