{
  description = "Wazuh agent for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {

      # ── The package ──────────────────────────────────────────────────────────
      # Build with:  nix build .#wazuh-agent
      packages.${system} = {
        wazuh-agent = pkgs.callPackage ./pkgs/wazuh-agent { };
        default = self.packages.${system}.wazuh-agent;
      };

      # Overlay so consumers can get the package through their own pkgs:
      #   nixpkgs.overlays = [ wazuh.overlays.default ];
      overlays.default = final: prev: {
        wazuh-agent = final.callPackage ./pkgs/wazuh-agent { };
      };

      nixosModules.wazuh-agent = import ./modules/wazuh-agent.nix;

      nixosModules.default = self.nixosModules.wazuh-agent;

      formatter.${system} = pkgs.nixfmt;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nixfmt
          statix
          deadnix
        ];
      };

      # Eval-only smoke test of the NixOS module — renders the systemd units
      # without building Wazuh itself.  Run with:  nix flake check
      checks.${system}.module =
        let
          eval = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.wazuh-agent
              {
                services.wazuh-agent = {
                  enable = true;
                  managerAddresses = [
                    "wazuh1.example.org"
                    "wazuh2.example.org"
                  ];
                  enrollmentPasswordFile = "/run/secrets/wazuh-enrollment-password";
                };
                system.stateVersion = "25.11";
              }
            ];
          };
          units = eval.config.systemd.units;
          # Discard string context: the check only inspects the rendered unit
          # text and must not pull in a full Wazuh build.
          rendered = builtins.unsafeDiscardStringContext ''
            === wazuh-agent.target ===
            ${units."wazuh-agent.target".text}
            === wazuh-agent-setup.service ===
            ${units."wazuh-agent-setup.service".text}
            === wazuh-execd.service ===
            ${units."wazuh-execd.service".text}
            === wazuh-agentd.service ===
            ${units."wazuh-agentd.service".text}
            === wazuh-syscheckd.service ===
            ${units."wazuh-syscheckd.service".text}
            === wazuh-logcollector.service ===
            ${units."wazuh-logcollector.service".text}
            === wazuh-modulesd.service ===
            ${units."wazuh-modulesd.service".text}
          '';
        in
        pkgs.runCommand "wazuh-module-eval-check"
          {
            inherit rendered;
            passAsFile = [ "rendered" ];
          }
          ''
            grep -q -- "wazuh-agentd -f" "$renderedPath"
            grep -q "Requires=wazuh-agent-setup.service" "$renderedPath"
            grep -q "PartOf=wazuh-agent.target" "$renderedPath"
            grep -q "Restart=on-failure" "$renderedPath"
            touch $out
          '';

    };
}
