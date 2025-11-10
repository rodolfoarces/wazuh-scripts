## Yara active response usage

The parameter `-yara_rules` was changed from the [documentation](https://documentation.wazuh.com/current/proof-of-concept-guide/detect-malware-yara-integration.html) to match the download directory used by the [yara_install.sh](../../integrations/yara/yara_install.sh) script. Please read the documentation to better understand its usage.

```
<ossec_config>
  <command>
    <name>yara_linux</name>
    <executable>yara.sh</executable>
    <extra_args>-yara_path /usr/local/bin -yara_rules /usr/share/yara/yara_rules.yar</extra_args>
    <timeout_allowed>no</timeout_allowed>
  </command>

  <active-response>
    <disabled>no</disabled>
    <command>yara_linux</command>
    <location>local</location>
    <rules_id>100300,100301</rules_id>
  </active-response>
</ossec_config>
```