# Install-RustDesk.ps1

Generic Windows installer for [RustDesk](https://github.com/rustdesk/rustdesk).
Safe to host in a **public** repo: no org-specific hosts and **no relay keys** in the file.

## What it does

1. Installs RustDesk (x64) using **winget → Chocolatey (`rustdesk.install`) → official GitHub `.exe`**.
2. Optionally writes `RustDesk2.toml` for a **self-hosted / private relay** when you pass a server + key at run time.
3. Can uninstall (`-Uninstall`) via the same Auto order (winget → Chocolatey → registry).

## Requirements

- Windows 10/11 (or Server) x64
- Elevated PowerShell (Administrator or SYSTEM)
- Network access to GitHub / winget / Chocolatey as needed

## Parameters

| Parameter | Env fallback | Purpose |
|-----------|--------------|---------|
| `-Server` | `RUSTDESK_SERVER` | Relay / rendezvous hostname (no `https://`) |
| `-Key` | `RUSTDESK_KEY` | Relay **public** key (base64). Never commit a real value. |
| `-SkipRelay` | — | Install client only; leave public network defaults |
| `-Source` | — | `Auto` (default), `Winget`, `Chocolatey`, or `Official` |
| `-Force` | — | Reinstall even if already present |
| `-Uninstall` | — | Remove RustDesk |
| `-DotSourceOnly` | — | Load functions only (for a launcher) |

If you do **not** pass `-SkipRelay`, both server and key are required (param or env).

## How to run (curl / irm style)

Replace `OWNER/REPO` with the GitHub path that hosts `Install-RustDesk.ps1`.

### Download, then run (recommended)

```powershell
curl.exe -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/Install-RustDesk.ps1 -o Install-RustDesk.ps1

powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-RustDesk.ps1 `
  -Server 'relay.example.com' -Key 'YOUR_PUBLIC_KEY_BASE64'
```

### One-liner with env vars (`irm | iex`)

`irm | iex` cannot take `-Server` / `-Key` on the same line. Set env first:

```powershell
$env:RUSTDESK_SERVER = 'relay.example.com'
$env:RUSTDESK_KEY    = 'YOUR_PUBLIC_KEY_BASE64'
irm https://raw.githubusercontent.com/OWNER/REPO/main/Install-RustDesk.ps1 | iex
```

### Scriptblock (params without saving a file)

```powershell
$s = Invoke-RestMethod https://raw.githubusercontent.com/OWNER/REPO/main/Install-RustDesk.ps1
& ([scriptblock]::Create($s)) -Server 'relay.example.com' -Key 'YOUR_PUBLIC_KEY_BASE64'
```

### Client only (no private relay)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-RustDesk.ps1 -SkipRelay
```

### Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-RustDesk.ps1 -Uninstall
```

## Security notes

- Treat the relay key like a secret in your deployment pipeline (TRMM args, CI secrets, env), not like documentation.
- Do not paste real keys into issues, chat, or git history.
- Review this script before piping it to `iex` on production machines (same rule as any remote install script).

## Related

- Private / managed fleets that **must** bake org defaults belong in a **private** repo or TRMM script body, not here.
