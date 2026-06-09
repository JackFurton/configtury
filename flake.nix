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
  };

  outputs = { self, nixpkgs, home-manager, disko, nixos-generators, ... }:
    let
      configtury = import ./lib { inherit nixpkgs home-manager disko nixos-generators; };
      outputs = configtury.mkOutputs { root = self; };
    in
    {
      # Drop a TOML in hosts/, get a buildable config here automatically.
      # Hosts with an [image] section also appear under packages.<system>.<name>.
      inherit (outputs) nixosConfigurations homeConfigurations packages;

      # The library, reusable from other flakes.
      lib = configtury;
    };
}
