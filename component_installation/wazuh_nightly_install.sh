#!/bin/bash

##############################################
# 1) Detect architecture & package type
##############################################
ARCH=$(uname -m)
PKG_TYPE=""

if command -v rpm >/dev/null 2>&1; then
    PKG_TYPE="rpm"
    case "$ARCH" in
        amd64)    ARCH="x86_64" ;;
        arm64)    ARCH="aarch64" ;;
    esac
elif command -v dpkg >/dev/null 2>&1; then
    PKG_TYPE="deb"
    case "$ARCH" in
        x86_64)   ARCH="amd64" ;;
        aarch64)  ARCH="arm64" ;;
        armv7l)   ARCH="armhf" ;;
    esac
else
    echo "[ERROR] Neither rpm nor dpkg found – cannot install."
    exit 1
fi

echo "[INFO] Detected architecture: $ARCH"
echo "[INFO] Package type: $PKG_TYPE"

##############################################
# 1b) Detect download tool (curl preferred, wget fallback)
##############################################
if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    echo "[ERROR] Neither curl nor wget found – cannot download packages."
    exit 1
fi

echo "[INFO] Using downloader: $DOWNLOADER"

download_file() {
    local url=$1
    local out=$2

    if [[ "$DOWNLOADER" == "curl" ]]; then
        curl -sS --fail -L "$url" -o "$out"
    else
        wget -q "$url" -O "$out"
    fi
}

##############################################
# 2-4) Fetch manifest and download packages
#      Try nightly first; on any failure fall back to nightly-backup
##############################################
NIGHTLY_URL="https://packages-staging.xdrsiem.wazuh.info/nightly/5.0.0/artifact-urls/artifact_urls_5.0.0-latest.yaml"
NIGHTLY_BACKUP_URL="https://packages-staging.xdrsiem.wazuh.info/nightly-backup/artifact_urls_5.0.0-latest.yaml"
ARTIFACTS_YAML="artifact_urls_5.0.0-latest.yaml"

get_artifact_url() {
    local key=$1
    grep "^${key}:" "$ARTIFACTS_YAML" | sed -E 's/^[^:]+:[[:space:]]*"([^"]+)"/\1/'
}

# Returns non-zero if the manifest, any entry, or any package download fails.
fetch_from_source() {
    local source_name=$1
    local manifest_url=$2

    echo "[INFO] Trying $source_name: $manifest_url"

    if ! download_file "$manifest_url" "${ARTIFACTS_YAML}.tmp"; then
        echo "[WARN] Could not download manifest from $source_name."
        rm -f "${ARTIFACTS_YAML}.tmp"
        return 1
    fi
    mv "${ARTIFACTS_YAML}.tmp" "$ARTIFACTS_YAML"

    INDEXER_URL=$(get_artifact_url "wazuh_indexer_${ARCH}_${PKG_TYPE}")
    MANAGER_URL=$(get_artifact_url "wazuh_manager_${ARCH}_${PKG_TYPE}")
    DASHBOARD_URL=$(get_artifact_url "wazuh_dashboard_${ARCH}_${PKG_TYPE}")

    local pair name url pkg
    for pair in "wazuh-indexer:$INDEXER_URL" "wazuh-manager:$MANAGER_URL" "wazuh-dashboard:$DASHBOARD_URL"; do
        name="${pair%%:*}"
        url="${pair#*:}"
        if [ -z "$url" ] || [ "$url" = "null" ]; then
            echo "[WARN] No manifest entry for $name in $source_name (arch=${ARCH}, pkg_type=${PKG_TYPE})."
            return 1
        fi
    done

    INDEXER_PKG=$(basename "$INDEXER_URL")
    MANAGER_PKG=$(basename "$MANAGER_URL")
    DASHBOARD_PKG=$(basename "$DASHBOARD_URL")

    echo "[INFO] Packages to download from $source_name:"
    echo "  $INDEXER_PKG"
    echo "  $MANAGER_PKG"
    echo "  $DASHBOARD_PKG"

    for pair in "$INDEXER_PKG:$INDEXER_URL" "$MANAGER_PKG:$MANAGER_URL" "$DASHBOARD_PKG:$DASHBOARD_URL"; do
        pkg="${pair%%:*}"
        url="${pair#*:}"
        echo "[INFO] Downloading $pkg ..."
        if ! download_file "$url" "$pkg"; then
            echo "[WARN] Failed to download $pkg from $source_name."
            rm -f "$INDEXER_PKG" "$MANAGER_PKG" "$DASHBOARD_PKG"
            return 1
        fi
    done
}

if fetch_from_source "nightly" "$NIGHTLY_URL"; then
    echo "[INFO] Using nightly artifacts."
elif fetch_from_source "nightly-backup" "$NIGHTLY_BACKUP_URL"; then
    echo "[INFO] Nightly failed, using nightly-backup artifacts."
else
    echo "[ERROR] Could not fetch artifacts from nightly or nightly-backup."
    exit 1
fi

##############################################
# 5) Interactive install/uninstall function
##############################################
install_pkg() {
    local pkg=$1
    local name=$2

    echo "[INFO] Checking $name installation..."

    if [[ "$PKG_TYPE" == "rpm" ]]; then
        if rpm -q "$name" >/dev/null 2>&1; then
            echo "[INFO] $name detected as already installed."
            read -p "Uninstall and reinstall $name? (y/N): " choice
        fi

        if [[ -z "$choice" || "$choice" =~ ^[Yy]$ ]]; then
            if [[ "$name" == "wazuh-indexer" ]]; then
              GENERATE_CERTS=true rpm -ivh --replacepkgs "$pkg"
            else 
              rpm -ivh --replacepkgs "$pkg"
            fi
        fi
    else
        if dpkg -l | grep -q "^ii\s\+$name"; then
            echo "[INFO] $name detected as already installed."
            read -p "Uninstall and reinstall $name? (y/N): " choice
        fi

        if [[ -z "$choice" || "$choice" =~ ^[Yy]$ ]]; then
          if [[ "$name" == "wazuh-indexer" ]]; then
            GENERATE_CERTS=true dpkg -i "$pkg"
          else 
            dpkg -i "$pkg"
          fi
        fi
    fi
}

##############################################
# 6) Install the packages
##############################################
install_pkg "$INDEXER_PKG"  "wazuh-indexer"
install_pkg "$MANAGER_PKG"  "wazuh-manager"
install_pkg "$DASHBOARD_PKG" "wazuh-dashboard"

##############################################
# 7) All in one configuration
##############################################

systemctl daemon-reload
systemctl enable wazuh-indexer
systemctl start wazuh-indexer

/usr/share/wazuh-indexer/bin/indexer-security-init.sh

sed -i '/<indexer>/,/<\/indexer>/c\
  <indexer>\
    <hosts>\
      <host>https://localhost:9200</host>\
    </hosts>\
    <ssl>\
      <certificate_authorities>\
        <ca>/etc/wazuh-indexer/certs/root-ca.pem</ca>\
      </certificate_authorities>\
      <certificate>/etc/wazuh-indexer/certs/indexer.pem</certificate>\
      <key>/etc/wazuh-indexer/certs/indexer-key.pem</key>\
    </ssl>\
  </indexer>' /var/ossec/etc/ossec.conf

systemctl enable wazuh-manager
systemctl start wazuh-manager

mkdir /etc/wazuh-dashboard/certs
cp /etc/wazuh-indexer/certs/* /etc/wazuh-dashboard/certs
chmod 500 /etc/wazuh-dashboard/certs
chmod 400 /etc/wazuh-dashboard/certs/*
chown -R wazuh-dashboard:wazuh-dashboard /etc/wazuh-dashboard/certs

sed -i 's#server\.ssl\.key: "/etc/wazuh-dashboard/certs/dashboard-key\.pem"#server.ssl.key: "/etc/wazuh-dashboard/certs/indexer-key.pem"#' /etc/wazuh-dashboard/opensearch_dashboards.yml
sed -i 's#server\.ssl\.certificate: "/etc/wazuh-dashboard/certs/dashboard\.pem"#server.ssl.certificate: "/etc/wazuh-dashboard/certs/indexer.pem"#' /etc/wazuh-dashboard/opensearch_dashboards.yml

systemctl enable wazuh-dashboard
systemctl start wazuh-dashboard

ip=$(hostname -I | awk '{print $1}')

echo
echo "======================================================"
echo " WAZUH INSTALL COMPLETE — latest packages used"
echo " Dashboard (default): https://${ip}"
echo "======================================================"
echo