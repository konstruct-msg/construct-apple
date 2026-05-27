#!/usr/bin/env bash
# Downloads GeoLite2-Country.mmdb and GeoLite2-ASN.mmdb if they are absent or
# older than 30 days.  Runs as an Xcode Build Phase (Run Script) so the
# databases are always present before compilation without bloating the repo.
#
# To add in Xcode: Target → Build Phases → "+" → New Run Script Phase
# Shell: /bin/bash
# Script body: "${SRCROOT}/scripts/fetch_geoip.sh"
# Uncheck "Based on dependency analysis" so it always runs.

set -euo pipefail

BASE_URL="https://github.com/P3TERX/GeoLite.mmdb/raw/download"
DEST_DIR="${SRCROOT:-.}"   # When run from Xcode, SRCROOT is the project root

need_download() {
    local file="$1"
    # Download if the file does not exist or was last modified more than 30 days ago
    [ ! -f "$file" ] || find "$file" -mtime +30 | grep -q .
}

for DB in GeoLite2-Country GeoLite2-ASN; do
    DEST="$DEST_DIR/${DB}.mmdb"
    if need_download "$DEST"; then
        echo "fetch_geoip: downloading ${DB}.mmdb…"
        curl -fsSL "${BASE_URL}/${DB}.mmdb" -o "$DEST"
        echo "fetch_geoip: ${DB}.mmdb saved to $DEST"
    else
        echo "fetch_geoip: ${DB}.mmdb is up to date (skipping)"
    fi
done
