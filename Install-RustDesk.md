# Install-RustDesk.ps1

Generic Windows installer for stock [RustDesk](https://github.com/rustdesk/rustdesk)
(public / default network). Safe to host in a **public** repo: installs or
uninstalls the stock client only.

## What it does

1. Installs RustDesk (x64) using **winget -> Chocolatey (`rustdesk.install`) -> official GitHub `.exe`**.
2. Leaves the client on the public / default RustDesk network.
3. Can uninstall (`-Uninstall`) via the same Auto order (winget -> Chocolatey -> registry).

## Requirements

- Windows 10/11 (or Server) x64
- Elevated PowerShell (Administrator or SYSTEM)
- Network access to GitHub / winget / Chocolatey as needed

## Parameters

| Parameter | Purpose |
|-----------|---------|
| `-Source` | `Auto` (default), `Winget`, `Chocolatey`, or `Official` |
| `-Force` | Reinstall even if already present |
| `-Uninstall` | Remove RustDesk |
| `-DotSourceOnly` | Load functions only (for a launcher) |

## How to run (curl / irm style)

Replace `OWNER/REPO` with the GitHub path that hosts `Install-RustDesk.ps1`
(e.g. `AriGonz/Public`).

### Download, then run (recommended)

```powershell
curl.exe -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/Install-RustDesk.ps1 -o Install-RustDesk.ps1

powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-RustDesk.ps1
```

### One-liner (`irm | iex`)

```powershell
irm https://raw.githubusercontent.com/OWNER/REPO/main/Install-RustDesk.ps1 | iex
```

### Scriptblock (params without saving a file)

```powershell
$s = Invoke-RestMethod https://raw.githubusercontent.com/OWNER/REPO/main/Install-RustDesk.ps1
& ([scriptblock]::Create($s)) -Force
& ([scriptblock]::Create($s)) -Source Official
& ([scriptblock]::Create($s)) -Uninstall
```

### Force / pick a source

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-RustDesk.ps1 -Force
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-RustDesk.ps1 -Source Official
```

### Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-RustDesk.ps1 -Uninstall
```

## Notes

- Run elevated (Administrator or SYSTEM).
- ASCII-only script (safe for Windows PowerShell 5.1).
- Exit `0` on success / already installed / uninstalled or not present; `1` on failure.
- Review this script before piping it to `iex` on production machines (same rule as any remote install script).
