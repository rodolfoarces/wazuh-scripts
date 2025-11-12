#!/bin/bash

## Based on docs from 
## https://documentation.wazuh.com/current/proof-of-concept-guide/detect-malware-yara-integration.html

# Variables
TMP_DIR='/tmp/yara'
SRC_DIR='/src/yara'
RULES_DIR='/usr/share/yara'
YARA_VERSION='4.5.5' 

# Validate user
# Check if the effective user ID (EUID) is 0 (root)
if [ "$EUID" -ne 0 ]; then
	echo "This script must be run as root or with sudo" 
	exit 1
fi

## Initial check to run or not
if [[ -f /usr/local/bin/yara  && "${YARA_VERSION}" == "$(/usr/local/bin/yara --version)" ]];
then
	echo "Yara is installed and with the correct version";
	## No options provided
	if [ $# -eq 0 ]; then
		echo -e "No options provided.\nOnly checks performed\nUse -i to force install, -u to update rules, -a to install binary and update rules if necessary.";
		exit 0;
	else
		echo "Proceeding with options";
		INSTALLED=true
	fi

else
	echo "Error, Yara binary is not present or versions don't match"
	if [ $# -eq 0 ]; then
		echo -e "No options provided.\nOnly checks performed\nUse -i to force install, -u to update rules, -a to install binary and update rules if necessary."
  		exit 1;
	fi

fi

add_prerequisites(){
# Yara prerequisites
# automake libtool make gcc pkg-config
## Update repositories
echo "Updating repository information"
apt-get update

## Install missing prerequisites
PACKAGES="automake libtool make gcc pkg-config libssl-dev jq" 

for PACKAGE_NAME in $PACKAGES;
do
	if dpkg -s "$PACKAGE_NAME" &> /dev/null; then
 		echo "$PACKAGE_NAME is installed."
	else
	      	echo "$PACKAGE_NAME is not installed. Installing.. "
		apt-get install -y  $PACKAGE_NAME;
	fi
done
}

compile(){
## Download Yara source code
/usr/bin/mkdir -p ${TMP_DIR}
echo "Downloading Yara Source code"
/usr/bin/curl --silent -L "https://github.com/VirusTotal/yara/archive/v${YARA_VERSION}.tar.gz" --output "${TMP_DIR}/v${YARA_VERSION}.tar.gz"

## Create directories for compilation
/usr/bin/mkdir -p ${SRC_DIR}/yara-v${YARA_VERSION}
/usr/bin/tar -zxf "${TMP_DIR}/v${YARA_VERSION}.tar.gz" -C "${SRC_DIR}/yara-v${YARA_VERSION}/" 

## Compiling
echo "Starting source code compilation"
cd "${SRC_DIR}/yara-v${YARA_VERSION}/yara-${YARA_VERSION}" && ./bootstrap.sh && ./configure && make && make install

if [[ "$YARA_VERSION" == "$(/usr/local/bin/yara --version)" ]]
then
	echo "Installed successful";
else
	echo "Binary version don't match";
	exit 2;
fi

## Cleanup
echo "Cleaning tmp directory"
/usr/bin/rm -fR "${TMP_DIR}"
echo "Cleaning src directory"
/usr/bin/rm -fR "${SRC_DIR}"
}

update_rules(){
## Creating rules directory
mkdir -p ${RULES_DIR}
echo "Downloading Yara rules to $RULES_DIR"
/usr/bin/curl --silent 'https://valhalla.nextron-systems.com/api/v1/get' \
	-H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
	-H 'Accept-Language: en-US,en;q=0.5' \
	--compressed \
	-H 'Referer: https://valhalla.nextron-systems.com/' \
	-H 'Content-Type: application/x-www-form-urlencoded' \
	-H 'DNT: 1' -H 'Connection: keep-alive' -H 'Upgrade-Insecure-Requests: 1' \
	--data 'demo=demo&apikey=1111111111111111111111111111111111111111111111111111111111111111&format=text' \
	-o ${RULES_DIR}/yara_rules.yar

/usr/bin/chmod 644 ${RULES_DIR}/yara_rules.yar
/usr/bin/chown root:wazuh ${RULES_DIR}/yara_rules.yar
}

set_script(){
	if [[ ! -f "/var/ossec/active-response/bin/yara.sh" ]];
	then
		## Setting yara active response script
		echo "Downloading yara active response script"
		/usr/bin/curl --silent -L "https://github.com/rodolfoarces/wazuh-scripts/raw/refs/heads/main/active-response/yara/yara.sh" --output "/var/ossec/active-response/bin/yara.sh" 
		echo "Changing permissions on files"
		/usr/bin/chmod 750 /var/ossec/active-response/bin/yara.sh
		/usr/bin/chown root:wazuh /var/ossec/active-response/bin/yara.sh
	else
		echo "Yara active response script already present, skipping download"
	fi
}


## Using options to manage parameters

while getopts "iaus" opt; do
  case $opt in
	a)
	  if [ "$INSTALLED" = true ]; then
		echo "Yara is already installed, proceeding to update rules";
		update_rules;
	  	set_script;
	  	echo "Yara installation completed successfully";
	  else
		echo "Yara is not installed or wrong version, proceeding to install binary and rules";
	  	add_prerequisites;
	  	compile;
	  	update_rules;
	  	set_script;
	  	echo "Yara installation completed successfully";
	  fi
	  ;;
	u)
	  update_rules;
	  echo "Yara rules updated successfully";
	  ;;
	i)
		add_prerequisites;
	  	compile;
	  	update_rules;
	  	set_script;
	  	echo "Yara installation completed successfully";
		;;
	s)
		set_script;
		echo "Yara active response script set successfully";
		;;
	\?)
	  echo "Invalid option: -$OPTARG" >&2
	  ;;
  esac
done
