{
  description = "configtury — describe a machine in TOML, get Nix that provisions it";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
  };

  outputs = { self, nixpkgs, home-manager, disko, nixos-generators, nixos-anywhere, ... }:
    let
      configtury = import ./lib {
        inherit nixpkgs home-manager disko nixos-generators nixos-anywhere;
      };
      outputs = configtury.mkOutputs { root = self; };
    in
    {
      # Drop a TOML in hosts/, get a buildable config here automatically.
      # Hosts with an [image] section also appear under packages.<system>.<name>;
      # hosts with a [disk] get a `deploy-<name>` app under apps.<system>.
      inherit (outputs) nixosConfigurations homeConfigurations packages apps;

      # The library, reusable from other flakes.
      lib = configtury;
    };
}
