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

# ── Bundle EDB PostgreSQL 17 installer (fallback if Homebrew is unavailable) ──
# The postinstall script will use this only when Homebrew is not found.
# To update the PostgreSQL version, replace the URL below.
# Latest macOS installers: https://www.enterprisedb.com/downloads/postgres-postgresql-downloads
#
# ARM64 (Apple Silicon) — PostgreSQL 17
EDB_MAC_URL="https://sbp.enterprisedb.com/getfile.jsp?fileid=1258893"
EDB_DMG="/tmp/pg17_edb_installer.dmg"
EDB_MOUNT="/tmp/pg17_edb_mount"

echo "==> Downloading EDB PostgreSQL 17 installer for macOS (ARM64)..."
curl -fSL --progress-bar -o "$EDB_DMG" "$EDB_MAC_URL" \
  || { echo "⚠️  WARNING: EDB download failed. Installer will rely on Homebrew only."; EDB_SKIP=1; }

if [ "${EDB_SKIP:-0}" -eq 0 ]; then
  echo "==> Extracting EDB installer from DMG..."
  hdiutil attach "$EDB_DMG" -mountpoint "$EDB_MOUNT" -nobrowse -quiet

  # The EDB macOS DMG contains a .run (Linux-style) or .app installer.
  # Copy whichever is present into the payload as a known filename.
  EDB_RUN=$(find "$EDB_MOUNT" -maxdepth 2 -name "*.run" | head -1)
  if [ -n "$EDB_RUN" ]; then
    cp "$EDB_RUN" payload/postgresql-17-installer.run
    chmod +x payload/postgresql-17-installer.run
    echo "==> EDB .run installer bundled: $(basename "$EDB_RUN")"
  else
    EDB_APP=$(find "$EDB_MOUNT" -maxdepth 2 -name "*.app" | head -1)
    if [ -n "$EDB_APP" ]; then
      cp -r "$EDB_APP" payload/postgresql-17-installer.app
      echo "==> EDB .app installer bundled: $(basename "$EDB_APP")"
    else
      echo "⚠️  WARNING: Could not find installer inside EDB DMG — skipping bundling."
    fi
  fi

  hdiutil detach "$EDB_MOUNT" -quiet
  rm -f "$EDB_DMG"
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
