#!/bin/bash

# Wazuh 5.0 all-in-one installation from the nightly packages.
#
# Follows the installation assistant's all-in-one path (wazuh-install.sh -a)
# step by step, with no parameters: root and system checks, dependencies,
# port and hardware checks, package download, then indexer -> manager ->
# dashboard, each installed, configured and started the way the assistant
# does it. The packages create their own CA, certificates and passwords and
# publish them for each other under /etc/<component>/export, so nothing is
# placed by hand. On any failure the installation is rolled back, as the
# assistant does.

umask 177

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERROR] $*" >&2; }

##############################################
# 0) Root check
##############################################
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root."
    exit 1
fi

##############################################
# 1) Detect package manager, architecture & package type
##############################################
ARCH=$(uname -m)
PKG_TYPE=""
SYS_TYPE=""

if command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
    PKG_TYPE="rpm"
    SYS_TYPE="yum"
    command -v dnf >/dev/null 2>&1 && SYS_TYPE="dnf"
    case "$ARCH" in
        amd64)    ARCH="x86_64" ;;
        arm64)    ARCH="aarch64" ;;
    esac
elif command -v apt-get >/dev/null 2>&1; then
    PKG_TYPE="deb"
    SYS_TYPE="apt-get"
    case "$ARCH" in
        x86_64)   ARCH="amd64" ;;
        aarch64)  ARCH="arm64" ;;
    esac
else
    err "Couldn't find YUM, DNF or APT package manager – cannot install."
    exit 1
fi

if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" && "$ARCH" != "amd64" && "$ARCH" != "arm64" ]]; then
    err "Unsupported architecture: $ARCH. Only x86_64/amd64 and aarch64/arm64 are supported."
    exit 1
fi

log "Package manager: $SYS_TYPE"
log "Detected architecture: $ARCH"
log "Package type: $PKG_TYPE"

##############################################
# 2) Previous installation check
##############################################
# The assistant refuses to install over an existing component unless asked
# to overwrite. Uninstall first (or remove the packages and their
# directories) before running this script again.
is_installed() {
    local name=$1
    if [[ "$PKG_TYPE" == "rpm" ]]; then
        rpm -q "$name" >/dev/null 2>&1
    else
        dpkg-query -W -f='${Status}' "$name" 2>/dev/null | grep -q "ok installed"
    fi
}

for name in wazuh-indexer wazuh-manager wazuh-dashboard; do
    if is_installed "$name"; then
        err "$name is already installed. Remove the existing Wazuh installation before running this script."
        exit 1
    fi
done

##############################################
# 3) Dependencies (indexer + manager + dashboard + assistant lists)
##############################################
if [[ "$PKG_TYPE" == "rpm" ]]; then
    DEPS=( coreutils diffutils findutils gawk grep hostname iproute openssl procps-ng sed util-linux libcap tar curl lsof )
else
    DEPS=( debconf adduser procps openssl diffutils iproute2 apt-transport-https gnupg curl hostname util-linux tar libcap2-bin lsof )
fi

log "Installing dependencies: ${DEPS[*]}"
if [[ "$PKG_TYPE" == "rpm" ]]; then
    "$SYS_TYPE" install -y "${DEPS[@]}" >/dev/null 2>&1 || "$SYS_TYPE" install -y "${DEPS[@]}"
else
    DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${DEPS[@]}" >/dev/null 2>&1 \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${DEPS[@]}"
fi

if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    err "Neither curl nor wget found – cannot download packages."
    exit 1
fi
log "Using downloader: $DOWNLOADER"

download_file() {
    local url=$1
    local out=$2

    if [[ "$DOWNLOADER" == "curl" ]]; then
        curl -sS --fail -L --max-time 600 --retry 5 --retry-delay 5 "$url" -o "$out"
    else
        wget -q "$url" -O "$out"
    fi
}

##############################################
# 4) Hardware and port checks
##############################################
cores=$(grep -c processor /proc/cpuinfo)
ram_mb=$(free -m | awk 'FNR == 2 {print $2}')
log "CPU cores detected: $cores"
log "RAM detected: ${ram_mb} MB"
if [ "$cores" -lt 4 ] || [ "$ram_mb" -lt 7300 ]; then
    warn "Your system does not meet the recommended minimum hardware requirements of 8Gb of RAM and 4 CPU cores. The installation will continue, but it may not work properly."
fi

AIO_PORTS=( 9200 9300 1514 1515 1516 1517 55000 443 )
if command -v lsof >/dev/null 2>&1; then
    used_port=0
    for port in "${AIO_PORTS[@]}"; do
        if lsof -sTCP:LISTEN -i:"$port" >/dev/null 2>&1; then
            err "Port $port is being used by another process. Please, check it before installing Wazuh."
            used_port=1
        fi
    done
    if [ "$used_port" -eq 1 ]; then
        err "The installation can not continue due to port usage by other processes."
        exit 1
    fi
else
    warn "Cannot find lsof. Port checking will be skipped."
fi

if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qw running; then
    warn "Firewalld is enabled. Please ensure that traffic is allowed on these ports: 1515, 1517, 1514, 443."
fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw active; then
    warn "UFW is enabled. Please ensure that traffic is allowed on these ports: 1515, 1517, 1514, 443."
fi

##############################################
# 5) Fetch manifest and download packages
#    Try nightly first; on any failure fall back to nightly-backup
##############################################
NIGHTLY_URL="https://packages-staging.xdrsiem.wazuh.info/nightly/5.0.0/artifact-urls/artifact_urls_5.0.0-latest.yaml"
NIGHTLY_BACKUP_URL="https://packages-staging.xdrsiem.wazuh.info/nightly-backup/artifact_urls_5.0.0-latest.yaml"
ARTIFACTS_YAML="artifact_urls_5.0.0-latest.yaml"
DOWNLOAD_DIR="wazuh-install-packages"

mkdir -m 700 "$DOWNLOAD_DIR" 2>/dev/null || chmod 700 "$DOWNLOAD_DIR"

get_artifact_url() {
    local key=$1
    grep "^${key}:" "$ARTIFACTS_YAML" | sed -E 's/^[^:]+:[[:space:]]*"([^"]+)"/\1/'
}

# Resolves the packages from the local manifest and downloads them.
# Returns non-zero if any entry is missing or any package download fails.
download_packages() {
    local source_name=$1

    INDEXER_URL=$(get_artifact_url "wazuh_indexer_${ARCH}_${PKG_TYPE}")
    MANAGER_URL=$(get_artifact_url "wazuh_manager_${ARCH}_${PKG_TYPE}")
    DASHBOARD_URL=$(get_artifact_url "wazuh_dashboard_${ARCH}_${PKG_TYPE}")

    local pair name url pkg
    for pair in "wazuh-indexer:$INDEXER_URL" "wazuh-manager:$MANAGER_URL" "wazuh-dashboard:$DASHBOARD_URL"; do
        name="${pair%%:*}"
        url="${pair#*:}"
        if [ -z "$url" ] || [ "$url" = "null" ]; then
            warn "No manifest entry for $name in $source_name (arch=${ARCH}, pkg_type=${PKG_TYPE})."
            return 1
        fi
    done

    INDEXER_PKG="$DOWNLOAD_DIR/$(basename "$INDEXER_URL")"
    MANAGER_PKG="$DOWNLOAD_DIR/$(basename "$MANAGER_URL")"
    DASHBOARD_PKG="$DOWNLOAD_DIR/$(basename "$DASHBOARD_URL")"

    log "Packages to download from $source_name:"
    echo "  $(basename "$INDEXER_PKG")"
    echo "  $(basename "$MANAGER_PKG")"
    echo "  $(basename "$DASHBOARD_PKG")"

    for pair in "$INDEXER_PKG:$INDEXER_URL" "$MANAGER_PKG:$MANAGER_URL" "$DASHBOARD_PKG:$DASHBOARD_URL"; do
        pkg="${pair%%:*}"
        url="${pair#*:}"
        log "Downloading $(basename "$pkg") ..."
        if ! download_file "$url" "$pkg"; then
            warn "Failed to download $(basename "$pkg") from $source_name."
            rm -f "$INDEXER_PKG" "$MANAGER_PKG" "$DASHBOARD_PKG"
            return 1
        fi
    done
}

# Returns non-zero if the manifest download or any package download fails.
fetch_from_source() {
    local source_name=$1
    local manifest_url=$2

    log "Trying $source_name: $manifest_url"

    if ! download_file "$manifest_url" "${ARTIFACTS_YAML}.tmp"; then
        warn "Could not download manifest from $source_name."
        rm -f "${ARTIFACTS_YAML}.tmp"
        return 1
    fi
    mv "${ARTIFACTS_YAML}.tmp" "$ARTIFACTS_YAML"

    download_packages "$source_name"
}

if [ -f "$ARTIFACTS_YAML" ]; then
    log "$ARTIFACTS_YAML already exists, skipping manifest download."
    if ! download_packages "local manifest"; then
        err "Could not download packages from the existing $ARTIFACTS_YAML."
        err "Remove the file to fetch a fresh manifest from nightly/nightly-backup."
        exit 1
    fi
elif fetch_from_source "nightly" "$NIGHTLY_URL"; then
    log "Using nightly artifacts."
elif fetch_from_source "nightly-backup" "$NIGHTLY_BACKUP_URL"; then
    log "Nightly failed, using nightly-backup artifacts."
else
    err "Could not fetch artifacts from nightly or nightly-backup."
    exit 1
fi

##############################################
# 6) Helpers: package install, service start, rollback
##############################################

# Removes everything this script installed, like the assistant's rollback.
rollback() {
    log "--- Removing existing Wazuh installation ---"
    for name in wazuh-manager wazuh-indexer wazuh-dashboard; do
        if is_installed "$name"; then
            log "Removing $name."
            if [[ "$PKG_TYPE" == "rpm" ]]; then
                "$SYS_TYPE" remove -y "$name" >/dev/null 2>&1
            else
                DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y "$name" >/dev/null 2>&1
            fi
        fi
    done
    rm -rf /var/wazuh-manager/ /etc/wazuh-manager/ \
           /var/lib/wazuh-indexer/ /usr/share/wazuh-indexer/ /etc/wazuh-indexer/ /var/log/wazuh-indexer/ \
           /var/lib/wazuh-dashboard/ /usr/share/wazuh-dashboard/ /etc/wazuh-dashboard/ /run/wazuh-dashboard/ \
           /etc/systemd/system/multi-user.target.wants/wazuh-manager.service \
           /etc/systemd/system/multi-user.target.wants/wazuh-dashboard.service \
           /etc/systemd/system/wazuh-dashboard.service
    systemctl daemon-reload >/dev/null 2>&1
    rm -rf "$DOWNLOAD_DIR"
    log "Installation cleaned."
}

fail() {
    err "$*"
    rollback
    exit 1
}

# Installs a downloaded package the way the assistant does (apt-get for a
# local .deb, rpm -ivh for a local .rpm) and checks the package is present.
install_pkg() {
    local pkg=$1
    local name=$2

    log "Starting $name installation."
    if [[ "$PKG_TYPE" == "rpm" ]]; then
        rpm -ivh "$pkg"
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q "./$pkg"
    fi

    is_installed "$name" || fail "$name installation failed."
    log "$name installation finished."
}

# Enables and starts a unit; on failure prints the problems its package
# resolver reported ("MISSING|INVALID|UNSAFE <subject>: <reason>" lines in
# the journal) and rolls back.
start_service() {
    local unit=$1
    local since
    since=$(date '+%Y-%m-%d %H:%M:%S')

    log "Starting service $unit."
    systemctl daemon-reload
    systemctl enable "$unit" >/dev/null 2>&1
    if systemctl start "$unit" && systemctl is-active --quiet "$unit"; then
        log "$unit service started."
        return 0
    fi

    err "$unit could not be started."
    journalctl -u "$unit" --since "$since" --no-pager -o cat 2>/dev/null \
        | sed -E 's/^resolve-credentials: //' \
        | grep -E '^(MISSING|INVALID|UNSAFE) ' | sort -u | sed 's/^/[ERROR]   /'
    fail "Check 'journalctl -u $unit --since \"$since\"' to learn more about the issue."
}

##############################################
# 7) Wazuh indexer
##############################################
log "--- Wazuh indexer ---"
install_pkg "$INDEXER_PKG" "wazuh-indexer"
sysctl -q -w vm.max_map_count=262144

# JVM heap: a quarter of the RAM on an all-in-one host (the package ships 1g).
ram=$(( ram_mb / 4 ))
[ "$ram" -eq 0 ] && ram=1024
sed -i "s/-Xms1g/-Xms${ram}m/" /etc/wazuh-indexer/jvm.options
sed -i "s/-Xmx1g/-Xmx${ram}m/" /etc/wazuh-indexer/jvm.options

# The package already configured a single node with its own certificates
# and nodes_dn. Only keep the indexer off the network.
sed -i 's|network.host:.*|network.host: "127.0.0.1"|' /etc/wazuh-indexer/opensearch.yml
log "Wazuh indexer post-install configuration finished."

start_service wazuh-indexer

# Load the security configuration once; the wrapper finds host, port and
# admin certificate by itself.
if bash /usr/share/wazuh-indexer/bin/indexer-security-init.sh; then
    log "Wazuh indexer cluster security configuration initialized."
else
    fail "The Wazuh indexer cluster security configuration could not be initialized."
fi

##############################################
# 8) Wazuh manager
##############################################
log "--- Wazuh manager ---"
# The package imports the indexer CA, client certificate and password from
# /etc/wazuh-indexer/export, mints its own CA for the agent listener and
# the API, and publishes /etc/wazuh-manager/export for the dashboard. The
# shipped configuration already points at https://127.0.0.1:9200.
install_pkg "$MANAGER_PKG" "wazuh-manager"
start_service wazuh-manager

##############################################
# 9) Wazuh dashboard
##############################################
log "--- Wazuh dashboard ---"
# The package reads the kibanaserver password and CA from the indexer
# export, the API password and CA from the manager export, and issues its
# own server certificate. The shipped configuration already points at
# https://localhost:9200 and https://localhost:55000.
install_pkg "$DASHBOARD_PKG" "wazuh-dashboard"
start_service wazuh-dashboard

log "Initializing Wazuh dashboard web application."
# The dashboard answers 503 until it is ready, and 000 is no connection.
dashboard_status() {
    curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 "https://127.0.0.1:443/status"
}
code=$(dashboard_status)
j=0
until { [ "$code" != "000" ] && [ "$code" != "503" ]; } || [ "$j" -ge 20 ]; do
    sleep 15
    j=$((j+1))
    code=$(dashboard_status)
done

if [ "$code" == "000" ] || [ "$code" == "503" ]; then
    err "Cannot connect to Wazuh dashboard."
    icode=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 "https://127.0.0.1:9200/")
    if [ "$icode" == "000" ]; then
        err "Failed to connect with the Wazuh indexer at 127.0.0.1:9200."
    elif [ "$icode" == "503" ]; then
        err "Wazuh indexer security settings not initialized."
    fi
    fail "Wazuh dashboard did not come up."
fi
log "Wazuh dashboard web application initialized."

##############################################
# 10) Summary and cleanup
##############################################
rm -rf "$DOWNLOAD_DIR"

# Addresses in the dashboard certificate, without loopback and link-local;
# the host's first address otherwise.
mapfile -t print_ips < <(openssl x509 -in /etc/wazuh-dashboard/certs/dashboard.pem -noout -ext subjectAltName 2>/dev/null \
    | grep -o 'IP Address:[^,[:space:]]*' | cut -d: -f2- \
    | grep -Ev '^(127\.|169\.254\.|0:0:0:0:0:0:0:1$|::1$|[Ff][Ee]80:)')
if [ "${#print_ips[@]}" -eq 0 ]; then
    print_ips=( "$(hostname -I | awk '{print $1}')" )
fi

CREDENTIALS_FILE="/etc/wazuh-indexer/export/credentials.env"
PASSWORD_COMMAND="sudo grep '^WAZUH_INDEXER_ADMIN_PASSWORD=' ${CREDENTIALS_FILE} | cut -d= -f2-"

echo
log "--- Summary ---"
for ip in "${print_ips[@]}"; do
    [[ "$ip" == *:* ]] && ip="[$ip]"
    log "You can access the web interface https://${ip}:443"
done
log "    User: admin (Wazuh dashboard login and Wazuh indexer administrator)"
if [ -t 1 ] && admin_password=$(grep '^WAZUH_INDEXER_ADMIN_PASSWORD=' "$CREDENTIALS_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"') && [ -n "$admin_password" ]; then
    log "    Password: ${admin_password}"
    log "    To read the password again, run:"
else
    log "    Password: to read it from ${CREDENTIALS_FILE}, run:"
fi
log "        ${PASSWORD_COMMAND}"
log "The passwords of the other users are in ${CREDENTIALS_FILE} and /etc/wazuh-manager/export/credentials.env."
log "Installation finished."
