{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-22.05";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }:
    let system = "aarch64-linux";
    in
    rec {
      packages.${system}.default = nixos-generators.nixosGenerate {
        inherit system;
        modules = [
          ./modules/apple-vm.nix
          ({...}: {
            users.users.root.password = "nixos";
            services.openssh.permitRootLogin = "yes";
            services.getty.autologinUser = "root";
          })
        ];
        format = "iso";
      };
    };
}
