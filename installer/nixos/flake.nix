{
  description = "Your NixWall flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixwall = {
      url = "github:MattiasKockum/NixWall";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixwall,
      disko,
      sops-nix,
      ...
    }@inputs:
    {

      nixosConfigurations.nixwall = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs self; };
        modules = [
          disko.nixosModules.disko
          nixwall.nixosModules.nixwall
          sops-nix.nixosModules.sops
          ./disko.nix
          ./configuration.nix
        ];
      };
    };
}
