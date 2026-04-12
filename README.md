# Genreport Installer

Cross-platform installer for [Genreport](https://github.com/genreport) — a multi-service application
that bundles a .NET API, a Go service, RabbitMQ, Ollama, and a React web front-end.

## Repository structure

```
.
├── windows/
│   └── setup.iss              # Inno Setup script (Windows wizard installer)
│
├── mac/
│   ├── pkg_scripts/
│   │   ├── preinstall         # Collects user input via osascript dialogs
│   │   └── postinstall        # Calls configwriter, loads launchd service
│   └── com.genreport.launcher.plist  # launchd service definition
│
├── configwriter/              # Go binary — writes appsettings.json + .env
│   ├── main.go
│   └── go.mod
│
└── .github/
    └── workflows/
        └── release.yml        # Builds both installers and publishes a GitHub Release
```

## What the user sees

| Stage | Windows | macOS |
|---|---|---|
| Welcome | Inno Setup built-in | pkg built-in |
| License | Inno Setup built-in | pkg built-in |
| Install dir | Inno Setup built-in | pkg built-in |
| **Database** | Inno Setup wizard page | osascript dialogs |
| **Ports** | Inno Setup wizard page | osascript dialogs |
| **SMTP** | Inno Setup wizard page | osascript dialogs |
| **R2 Storage** | Inno Setup wizard page | osascript dialogs |
| Installing | Inno Setup built-in | pkg built-in |
| Done | Inno Setup built-in | pkg built-in |

## Config writer

`configwriter` is a small Go binary that accepts all installation parameters as
CLI flags and writes:

- `{install_dir}/dotnet/appsettings.Production.json` — consumed by the .NET service
- `{install_dir}/go/.env` — consumed by the Go service

It has **no UI** — it is invoked silently by the installer after the user
completes the wizard.

### Build locally

```bash
cd configwriter
go build -o configwriter .          # macOS/Linux
GOOS=windows go build -o configwriter.exe .   # cross-compile for Windows
```

## Release

Push a tag matching `v*.*.*` to trigger the GitHub Actions release workflow,
which builds both installers and attaches them to a GitHub Release automatically.

```bash
git tag v1.0.0
git push origin v1.0.0
```
