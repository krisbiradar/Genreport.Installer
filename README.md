# Genreport Installer

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/krisbiradar/Genreport.Installer)](https://github.com/krisbiradar/Genreport.Installer/releases)

Cross-platform installer for **Genreport** — an AI-powered report generation platform that bundles a .NET API, Go service, RabbitMQ, Ollama (local LLM), and a React web front-end into a single native installer.

---

## Overview

The installer guides the user through a native wizard on each platform — no external dependencies, no web UIs — collecting database, port, SMTP, and cloud storage credentials, then silently writes them into the correct config files before starting the application services.

| Platform | Installer type | Wizard style |
|---|---|---|
| **Windows** | `.exe` via [Inno Setup](https://jrsoftware.org/isinfo.php) | Native multi-page wizard |
| **macOS** | `.pkg` via `pkgbuild` | Native macOS `.pkg` + `osascript` dialogs |

---

## What the user sees

```
Windows                              macOS
───────────────────────────────      ───────────────────────────────
[Welcome]      ← built-in           [Welcome]      ← pkg built-in
[License]      ← built-in           [License]      ← pkg built-in
[Install dir]  ← built-in           [Destination]  ← pkg built-in
[DB page]      ← Pascal wizard      [DB dialogs]   ← preinstall bash
[Ports page]   ← Pascal wizard      [Ports dialogs]← preinstall bash
[SMTP page]    ← Pascal wizard      [SMTP dialogs] ← preinstall bash
[R2 page]      ← Pascal wizard      [R2 dialogs]   ← preinstall bash
[Installing]   ← built-in           [Installing]   ← pkg built-in
[Done]         ← built-in           [Done]         ← pkg built-in
                                      ↓
                                    postinstall runs configwriter
                                    + loads launchd plist
```

---

## Repository structure

```
.
├── windows/
│   └── setup.iss                       # Inno Setup script — wizard pages + service registration
│
├── mac/
│   ├── pkg_scripts/
│   │   ├── preinstall                  # osascript dialogs — collects all user input
│   │   └── postinstall                 # calls configwriter, registers launchd service
│   └── com.genreport.launcher.plist    # launchd service definition
│
├── configwriter/                       # Go binary — writes config files, no UI
│   ├── main.go
│   └── go.mod
│
└── .github/
    └── workflows/
        └── release.yml                 # Cross-platform build + GitHub Release on tag push
```

---

## Components

### `windows/setup.iss` — Inno Setup script

Defines 4 custom wizard pages inserted after the built-in install-directory page:

| Page | Fields |
|---|---|
| **Database** | Host, Port, Database name, Username, Password |
| **Ports** | .NET API, Go service, RabbitMQ, Ollama |
| **SMTP** | Host, Port, Username, Password, From address |
| **R2 Storage** | Account ID, Bucket, Access Key, Secret Key, Public URL |

After installation the script calls `configwriter.exe` with all collected values,
then registers `launcher.exe` as a Windows Service via `sc.exe`.

### `mac/pkg_scripts/` — preinstall & postinstall

`preinstall` runs **before** files are copied. It auto-detects whether RabbitMQ and Ollama are already running on their default ports, then presents one `osascript` dialog per logical group (matching the 4-page Windows flow). Results are written to `/tmp/genreport_install_config` (mode `600`).

`postinstall` runs **after** files are copied. It sources the temp config, invokes the `configwriter` binary, registers the launchd daemon, and deletes the temp file (which contains secrets).

### `configwriter/` — config writer binary

A small, dependency-free Go binary that accepts all installation parameters as CLI flags and writes:

- `{install_dir}/dotnet/appsettings.Production.json` — consumed by the .NET API
- `{install_dir}/go/.env` — consumed by the Go service

It is **identical on both platforms** and has no UI; only the caller differs (Pascal vs. bash).

#### Flags

| Flag | Default | Description |
|---|---|---|
| `--installdir` | *(required)* | Root installation directory |
| `--dbhost` | `localhost` | PostgreSQL host |
| `--dbport` | `5432` | PostgreSQL port |
| `--dbname` | `genreport` | PostgreSQL database name |
| `--dbuser` | `postgres` | PostgreSQL username |
| `--dbpassword` | | PostgreSQL password |
| `--dotnetport` | `5000` | .NET API listen port |
| `--goport` | `12334` | Go service listen port |
| `--rabbitmqport` | `5672` | RabbitMQ AMQP port |
| `--ollamaport` | `11434` | Ollama port |
| `--smtphost` | | SMTP host |
| `--smtpport` | `587` | SMTP port |
| `--smtpuser` | | SMTP username |
| `--smtppass` | | SMTP password |
| `--smtpfrom` | `noreply@genreport.app` | Sender address |
| `--r2accountid` | | Cloudflare R2 Account ID |
| `--r2bucket` | | R2 Bucket name |
| `--r2accesskey` | | R2 Access Key ID |
| `--r2secretkey` | | R2 Secret Access Key |
| `--r2publicurl` | | R2 Public URL |

---

## Building locally

### configwriter

```bash
cd configwriter

# macOS / Linux
go build -ldflags="-s -w" -o configwriter .

# Cross-compile for Windows
GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" -o configwriter.exe .
```

### Windows installer

Requires [Inno Setup 6+](https://jrsoftware.org/isinfo.php) installed.

```bash
# Place all publish/* artifacts first, then:
iscc windows/setup.iss
# Output: windows/dist/GenreportSetup.exe
```

### macOS installer

Requires `pkgbuild` (Xcode Command Line Tools).

```bash
chmod +x mac/pkg_scripts/preinstall mac/pkg_scripts/postinstall

pkgbuild \
  --root payload/ \
  --scripts mac/pkg_scripts \
  --identifier com.genreport.installer \
  --version 1.0.0 \
  --install-location /Applications/Genreport \
  Genreport.pkg
```

---

## Release

Push a semver tag to trigger the GitHub Actions workflow, which builds both installers and attaches them to a GitHub Release.

```bash
git tag v1.0.0
git push origin v1.0.0
```

---

## 🔗 Related Repositories

| Repo | Description |
|---|---|
| [GenReport](https://github.com/krisbiradar/GenReport) | Main repository — overview, quick start & docs |
| [GenReport.Go](https://github.com/krisbiradar/GenReport.Go) | Go service layer — HTTP server & process orchestration |
| [GenReport.ClientWebsite](https://github.com/krisbiradar/GenReport.ClientWebsite) | React frontend — dashboards, chart builder & web UI |

---

## License

[MIT](LICENSE) © 2026 Kris Biradar
