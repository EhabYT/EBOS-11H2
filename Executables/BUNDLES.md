# Bundled assets

These four files make an EBOS install work with no network. None of them are committed —
they are binaries of tens of megabytes and change on their own release cadence. Drop them
here before packing the `.apbx`.

```
Executables/
├── vc_redist.x64.exe                 ~25 MB   Microsoft, signed
├── BraveSetup.exe                    ~130 MB  Brave, signed
├── windhawk-cli-1.1.0-installer.exe  13.0 MB  windhawk-cli v1.1.0, signed
└── windhawk-cache/                            made by build-windhawk-cache.ps1
    ├── windows-11-taskbar-styler/
    └── windows-11-file-explorer-styler/
```

## What each one unblocks

| Asset | Phase | Without it, offline |
|---|---|---|
| `vc_redist.x64.exe` | 1 | VC++ step is skipped and logged; games needing the runtime may fail to start |
| `BraveSetup.exe` | 1 | Brave step is skipped and logged; with `remove-edge` also ticked you can end up with no browser |
| `windhawk-cli-*-installer.exe` | 7b | Windhawk step fails with exit 3 |
| `windhawk-cache/` | 7b | Windhawk step fails with exit 3 |

Nothing else in the playbook downloads: DirectX ships in `dxredist/`, and every other phase
is registry, service, AppX or file work.

## Getting the windhawk-cli installer

One release exists as of this writing: **v1.1.0**, asset `windhawk-cli-1.1.0-installer.exe`,
13,661,576 bytes.

| Field | Value |
|---|---|
| URL | `https://github.com/hansonxyz/windhawk-cli/releases/download/v1.1.0/windhawk-cli-1.1.0-installer.exe` |
| Size | 13,661,576 bytes |
| SHA-256 | `63962b290a3c63c45cf442bf3a99e91ee721ac151c7b3f774dee4424f7a238ab` |

That hash is pinned in `configure-windhawk-styler.ps1` (`$KnownInstallerHashes`), so a wrong
or swapped binary is refused before it runs. Add a row there when you adopt a new release.

Note for the online path: the release download is a 302 to
`objects.githubusercontent.com`, so any egress allowlist needs **both** hosts, not just
`github.com`. The offline path never touches either.

## Building the Windhawk half

On a Windows 11 machine with internet:

```powershell
.\build-windhawk-cache.ps1 -OutDir D:\ebos-offline-bundle
Copy-Item D:\ebos-offline-bundle\* . -Recurse
```

That script runs the same `configure-windhawk-styler.ps1` the playbook runs, then
`whcli export-cache`, so the cache describes exactly what will be applied rather than a
hand-built approximation. It also writes `BUILDING-OFFLINE-BUNDLE.txt` recording which mod
versions were frozen.

## Licensing when you redistribute

Windhawk is GPL-3.0 (Ramen Software); windhawk-cli is a GPL-3.0 fork of it (HansonXYZ).
Bundling the unmodified binary next to a PolyForm-Noncommercial playbook is normally treated
as mere aggregation, but you still carry the GPL obligations for that component: ship the
licence text and be able to point at the corresponding source
(`https://github.com/hansonxyz/windhawk-cli`). Do not describe the bundle as PolyForm-licensed.

## Verifying before you pack

```powershell
.\test-ebos-bundles.ps1 -RequireOffline
```

Checks presence, size, Authenticode signature, that both required mods are in the cache, and
that every cached mod actually carries a precompiled DLL. Exit code 0 means air-gap ready.

## Why not commit these

The engine and mods are GPL-3.0 (Windhawk by Ramen Software, windhawk-cli by HansonXYZ) —
shipping them inside a PolyForm Noncommercial package is a licensing question you should
answer deliberately, not by accident in a git history. Keep them in a build artifact or a
release asset.
