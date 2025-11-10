# Yara installation script

It was tested with Ubuntu 22.04 and 24.04

## Deploying

The script can be deployed as with centralized configuration

It can be run with parameters to perform regular checks and tasks

```
<agent_config>
    <wodle name="command">
        <disabled>no</disabled>
        <tag>yara_install</tag>
        <command>/bin/bash /var/ossec/etc/shared/yara_install.sh -a</command>
        <interval>7d</interval>
        <ignore_output>yes</ignore_output>
        <run_on_start>yes</run_on_start>
        <timeout>0</timeout>
    </wodle>
</agent_config>
```

## Running as is

The script without parameters will only check if the yara binary is present and it matches the expected version

Example:

```
/bin/bash  /var/ossec/etc/shared/yara_install.sh
```
Output:

```
Yara is installed and with the correct version
No options provided.
Only checks performed
Use -i to force install, -u to update rules, -a to install binary and update rules if necessary.
```

## Running with parameters

### Run all

The scripts can use parameters to perform multiple tasks

The `-a` parameter allows to validate if the binaries and scripts is present and if not present then install the necessary binaries and scripts

Example:

```
/bin/bash  /var/ossec/etc/shared/yara_install.sh -a
```

Output:

```
Yara is installed and with the correct version
Proceeding with options
Yara is already installed, proceeding to update rules
Downloading Yara rules to /usr/share/yara
Yara active response script already present, skipping download
Yara installation completed successfully
```
If there are missing binaries and scripts you have out put of compiling process

### Update the rules files

The script can update the rules files, the parameter `-u` will only update the Yara rule file using the demo content from [Valhala](https://valhalla.nextron-systems.com/)

Example:

```
/bin/bash  /var/ossec/etc/shared/yara_install.sh -u
```
Output:

```
Yara is installed and with the correct version
Proceeding with options
Downloading Yara rules to /usr/share/yara
Yara rules updated successfully
```

### Force Installation

The `-i` parameter forces installation of all components even if present. Similar to `-a`

Example

```
/bin/bash  /var/ossec/etc/shared/yara_install.sh -i
```