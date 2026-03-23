# wazuh-agent flake

NixOS flake that builds the Wazuh agent from source and provides a NixOS
module with a contained runtime layout.

Many patches were needed to make the agent work. The flake should be reviewed at some point, but I do not have the time currently.
Feel free to contribute.

AI helped to create this module.

nix.settings.sandbox = "relaxed" is required.

#### Add to flake inputs:

wazuh-agent = {
    url = "github:Pirmin99/wazuh-agent-flake";
    inputs.nixpkgs.follows = "nixpkgs";
};

#### Add this to imports:

inputs.wazuh-agent.nixosModules.wazuh-agent

### Minimal configuration:

services.wazuh-agent = {
    enable = true;
    managerAddress = "server-address-here";
  };

### Optional parameters:

| parameter         | default value                             | description                                                       |
| :-----------      | :------------:                            | :------------                                                     |
| managerPort       | 1514                                      | Port of the wazuh manager                                         |
| protocol          | tcp                                       | Transport protocol to connect to the manager. Either tcp or udp   |
| enableSyscheck    | true                                      | Enable file integrity monitoring                                  |
| enableRootcheck   | true                                      | Enable rootkit detection                                          |
| autoEnroll        | false                                     | Auto-enroll with the manager via the enrollment protocol          |
| enableSca         | true                                      | Enable Security Configuration Assessment                          |
| scaPolicies       | generic/sca_distro_independent_linux.yml  | List of SCA policy files to evaluate                              |
| extraConfig       | ""                                        | Raw XML appended inside <ossec_config>                            |


### Perform the enrollment
sudo WAZUH_HOME=/var/lib/wazuh-agent agent-auth \
  -m "WAZUH_MANAGER" \
  -P "WAZUH_REGISTRATION_PASSWORD" \
  -G "WAZUH_AGENT_GROUP" \
  -A "WAZUH_AGENT_NAME"
