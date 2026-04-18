#!/bin/bash
set -e

echo "==> Preparing clean workspace..."
# Strip immutable flags and ACLs copied from the read-only Postgres DMG
chflags -R nouchg external_repos payload Genreport.pkg 2>/dev/null || true
chmod -RN external_repos payload Genreport.pkg 2>/dev/null || true
chmod -R u+w external_repos payload Genreport.pkg 2>/dev/null || true
rm -rf external_repos payload Genreport.pkg
mkdir -p external_repos payload

echo "==> Cloning remote repositories..."
git clone https://github.com/krisbiradar/GenReport.ClientWebsite.git external_repos/frontend || echo "⚠️ Warning: Frontend repo not found (update URL if needed)"
git clone https://github.com/krisbiradar/GenReport.git external_repos/backend || echo "⚠️ Warning: Backend repo not found (update URL if needed)"
git clone https://github.com/krisbiradar/GenReport.Go.git external_repos/go || echo "⚠️ Warning: Go service repo not found (update URL if needed)"

echo "==> Building configwriter for macOS (Apple Silicon)..."
# Note: change GOARCH=arm64 to amd64 if you are on an Intel Mac
cd configwriter
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o ../publish/configwriter-darwin-arm64 .
cd ..

echo "==> Preparing macOS Payload..."
cp publish/configwriter-darwin-arm64 payload/configwriter
chmod +x payload/configwriter
cp mac/com.genreport.launcher.plist payload/

# ── Bundle Postgres.app (PostgreSQL 17 for macOS, fallback if Homebrew absent) ──
# Postgres.app is a self-contained macOS application that includes pg client
# tools (psql, pg_isready, etc.) and a full PostgreSQL 17 server.
# Its GitHub release URLs are stable and versioned — safe to use in CI.
#
# Resolve the latest Postgres.app v17-only DMG URL dynamically:
echo "==> Resolving latest Postgres.app v17 release URL..."
PGAPP_DMG_URL=$(curl -fsSL https://api.github.com/repos/PostgresApp/PostgresApp/releases/latest \
  | python3 -c "
import json, sys
assets = json.load(sys.stdin)['assets']
# Pick the single-version PG17 DMG (smallest download, no extra versions)
for a in assets:
    if a['name'].endswith('-17.dmg'):
        print(a['browser_download_url'])
        break
") || true

if [ -z "$PGAPP_DMG_URL" ]; then
  echo "⚠️  WARNING: Could not resolve Postgres.app download URL. Installer will rely on Homebrew only."
  PGAPP_SKIP=1
fi

if [ "${PGAPP_SKIP:-0}" -eq 0 ]; then
  PGAPP_DMG="/tmp/Postgres-17.dmg"
  PGAPP_MOUNT="/tmp/PostgresApp_mount"

  echo "==> Downloading Postgres.app: $PGAPP_DMG_URL"
  curl -fSL --progress-bar -o "$PGAPP_DMG" "$PGAPP_DMG_URL" \
    || { echo "⚠️  WARNING: Postgres.app download failed. Installer will rely on Homebrew only."; PGAPP_SKIP=1; }
fi

if [ "${PGAPP_SKIP:-0}" -eq 0 ]; then
  echo "==> Mounting Postgres.app DMG..."
  hdiutil attach "$PGAPP_DMG" -mountpoint "$PGAPP_MOUNT" -nobrowse -quiet \
    || { echo "⚠️  WARNING: Could not mount Postgres.app DMG."; PGAPP_SKIP=1; }
fi

if [ "${PGAPP_SKIP:-0}" -eq 0 ]; then
  PGAPP_SRC=$(find "$PGAPP_MOUNT" -maxdepth 1 -name "*.app" | head -1)
  if [ -n "$PGAPP_SRC" ]; then
    echo "==> Bundling $(basename "$PGAPP_SRC") into payload..."
    cp -r "$PGAPP_SRC" payload/Postgres.app
    echo "==> Postgres.app bundled successfully."
  else
    echo "⚠️  WARNING: .app not found in Postgres DMG — skipping."
  fi
  hdiutil detach "$PGAPP_MOUNT" -quiet
  rm -f "$PGAPP_DMG"
fi

# -----------------------------------------------------------------------------
# ── Build all core application components ────────────────────────────────────
echo "==> Loading environment paths (for Homebrew node/go)..."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "==> Building Go launcher..."
cd launcher
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o ../payload/launcher .
cd ..

echo "==> Building React frontend..."
cd external_repos/frontend
npm install
VITE_BASE_URL=/api npm run build
cd ../..
mkdir -p payload/web
cp -r external_repos/frontend/dist/* payload/web/

echo "==> Building .NET backend (Self-Contained)..."
# We target osx-arm64 and produce a single standalone executable (GenReport)
dotnet publish external_repos/backend/GenReport.Api/GenReport.csproj -c Release -r osx-arm64 --self-contained true -p:PublishSingleFile=true -o payload/dotnet

echo "==> Building Go service..."
cd external_repos/go
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 go build \
  -ldflags="-s -w -X main.version=$(git describe --tags --always) -X main.buildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -trimpath \
  -o ../../payload/go/goservice \
  ./cmd/server
cd ../..

echo "==> Building configwriter..."
cd configwriter
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o ../payload/configwriter .
cd ..

echo "==> Copying launch daemon plist..."
cp mac/com.genreport.launcher.plist payload/
# -----------------------------------------------------------------------------

echo "==> Setting installer script permissions..."
chmod +x mac/pkg_scripts/preinstall mac/pkg_scripts/postinstall

echo "==> Packaging Genreport.pkg..."
pkgbuild \
  --root payload/ \
  --scripts mac/pkg_scripts \
  --identifier com.genreport.installer \
  --version "1.0.0-local" \
  --install-location /Applications/Genreport \
  Genreport.pkg

echo "==> Done! Genreport.pkg has been built."
