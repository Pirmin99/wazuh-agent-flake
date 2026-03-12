{
  description = "Wazuh agent for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {

    # ── The package ──────────────────────────────────────────────────────────
    # Build with:  nix build .#wazuh-agent
    packages.x86_64-linux.wazuh-agent =
      nixpkgs.legacyPackages.x86_64-linux.callPackage ./pkgs/wazuh-agent {};

    packages.x86_64-linux.default =
      self.packages.x86_64-linux.wazuh-agent;

    # ── The NixOS module ─────────────────────────────────────────────────────
    # Use in another flake's nixosConfigurations like:
    #
    #   inputs.wazuh.url = "github:yourname/wazuh-flake";
    #
    #   nixosConfigurations.mymachine = nixpkgs.lib.nixosSystem {
    #     modules = [
    #       wazuh.nixosModules.wazuh-agent
    #       {
    #         services.wazuh-agent = {
    #           enable         = true;
    #           managerAddress = "192.168.1.10";
    #         };
    #       }
    #     ];
    #   };
    nixosModules.wazuh-agent = import ./modules/wazuh-agent.nix;

    # Canonical alias so consumers can also write inputs.wazuh.nixosModules.default
    nixosModules.default = self.nixosModules.wazuh-agent;
  };
}
