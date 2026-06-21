# AgentBridge

Public desktop release downloads for AgentBridge.

## Install

macOS Apple Silicon:

```sh
curl -fsSL https://raw.githubusercontent.com/elementalife/agentbridge/main/install-latest-mac-release.sh | bash
```

Windows x64:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-RestMethod https://raw.githubusercontent.com/elementalife/agentbridge/main/install-latest-windows-release.ps1 | Invoke-Expression"
```

Release assets and checksums are published at https://github.com/elementalife/agentbridge/releases/latest.

These builds are not Developer ID signed or notarized. Windows and macOS may warn on first launch, so only open them after confirming the checksum and source.
