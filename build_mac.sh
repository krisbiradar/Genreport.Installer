#!/bin/bash
set -e

echo "==> Preparing clean workspace..."
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
# TODO: Add your build commands for the 3 cloned repos here!
# Example:
#   cd external_repos/frontend && npm install && npm run build
#   cp -r dist ../../payload/web
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
