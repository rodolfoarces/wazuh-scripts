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
# 2) Update the artifacts manifest
##############################################
ARTIFACTS_URL="https://packages-staging.xdrsiem.wazuh.info/nightly-backup/artifact_urls_5.0.0-latest.yaml"
ARTIFACTS_YAML="artifact_urls_5.0.0-latest.yaml"

echo "[INFO] Updating artifacts manifest from $ARTIFACTS_URL ..."
download_file "$ARTIFACTS_URL" "${ARTIFACTS_YAML}.tmp"
mv "${ARTIFACTS_YAML}.tmp" "$ARTIFACTS_YAML"

get_artifact_url() {
    local key=$1
    grep "^${key}:" "$ARTIFACTS_YAML" | sed -E 's/^[^:]+:[[:space:]]*"([^"]+)"/\1/'
}

##############################################
# 3) Resolve package URLs from the manifest
##############################################
INDEXER_URL=$(get_artifact_url "wazuh_indexer_${ARCH}_${PKG_TYPE}")
MANAGER_URL=$(get_artifact_url "wazuh_manager_${ARCH}_${PKG_TYPE}")
DASHBOARD_URL=$(get_artifact_url "wazuh_dashboard_${ARCH}_${PKG_TYPE}")

for pair in "wazuh-indexer:$INDEXER_URL" "wazuh-manager:$MANAGER_URL" "wazuh-dashboard:$DASHBOARD_URL"; do
    name="${pair%%:*}"
    url="${pair#*:}"
    if [ -z "$url" ]; then
        echo "[ERROR] No manifest entry found for $name (arch=${ARCH}, pkg_type=${PKG_TYPE})."
        exit 1
    fi
done

INDEXER_PKG=$(basename "$INDEXER_URL")
MANAGER_PKG=$(basename "$MANAGER_URL")
DASHBOARD_PKG=$(basename "$DASHBOARD_URL")

echo "[INFO] Packages to download:"
echo "  $INDEXER_PKG"
echo "  $MANAGER_PKG"
echo "  $DASHBOARD_PKG"

##############################################
# 4) Download latest packages
##############################################
for pair in "$INDEXER_PKG:$INDEXER_URL" "$MANAGER_PKG:$MANAGER_URL" "$DASHBOARD_PKG:$DASHBOARD_URL"; do
    pkg="${pair%%:*}"
    url="${pair#*:}"
    echo "[INFO] Downloading $pkg ..."
    download_file "$url" "$pkg"
done

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