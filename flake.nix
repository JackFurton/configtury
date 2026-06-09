{
  description = "configtury — describe a machine in TOML, get Nix that provisions it";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      configtury = import ./lib { inherit nixpkgs home-manager; };
      outputs = configtury.mkOutputs { root = self; };
    in
    {
      # Drop a TOML in hosts/, get a buildable config here automatically.
      inherit (outputs) nixosConfigurations homeConfigurations;

      # The library, reusable from other flakes.
      lib = configtury;
    };
}
