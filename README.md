# wazuh-agent flake

NixOS flake that builds the Wazuh agent from source and provides a NixOS
module with a contained runtime layout (everything lives under
`/var/lib/wazuh-agent`).

The agent runs as one systemd unit per daemon, grouped under
`wazuh-agent.target`, so systemd supervises and restarts each daemon
individually:

    systemctl status wazuh-agent.target
    systemctl restart wazuh-agent.target

AI helped to create this module. Contributions welcome.

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

| parameter              | default value                             | description                                                        |
| :--------------------- | :---------------------------------------: | :----------------------------------------------------------------- |
| managerAddresses       | []                                        | List of managers for failover; takes precedence over managerAddress |
| managerPort            | 1514                                      | Port of the wazuh manager                                          |
| protocol               | tcp                                       | Transport protocol to connect to the manager. Either tcp or udp    |
| enableSyscheck         | true                                      | Enable file integrity monitoring                                   |
| enableRootcheck        | true                                      | Enable rootkit detection                                           |
| autoEnroll             | false                                     | Auto-enroll with the manager via the enrollment protocol           |
| enrollmentPasswordFile | null                                      | File with the enrollment password; enables enrollment when set     |
| enableSca              | true                                      | Enable Security Configuration Assessment                           |
| scaPolicies            | generic/sca_distro_independent_linux.yml  | List of SCA policy files to evaluate                               |
| extraConfig            | ""                                        | Raw XML appended inside <ossec_config>                             |

### Enrollment

Declarative (recommended): point `enrollmentPasswordFile` at a runtime
secret (agenix, sops-nix, ...) and the agent enrolls itself on first start:

    services.wazuh-agent = {
        enable = true;
        managerAddress = "server-address-here";
        enrollmentPasswordFile = "/run/secrets/wazuh-enrollment-password";
    };

Manual alternative:

    sudo WAZUH_HOME=/var/lib/wazuh-agent agent-auth \
      -m "WAZUH_MANAGER" \
      -P "WAZUH_REGISTRATION_PASSWORD" \
      -G "WAZUH_AGENT_GROUP" \
      -A "WAZUH_AGENT_NAME"

### Development

    nix build .#wazuh-agent   # build the package (fully sandboxed)
    nix flake check           # eval checks incl. a module smoke test
    nix fmt                   # format
    nix develop               # shell with nixfmt, statix, deadnix
