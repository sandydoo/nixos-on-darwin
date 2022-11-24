{
  inputs = {
    nixpkgs.url = "github:sandydoo/nixpkgs/feature/support-rosetta";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }:
    let
      system = "aarch64-linux";
      pkgs = import nixpkgs { inherit system; };
      x86Pkgs = import nixpkgs { system = "x86_64-linux"; };
    in
    rec {
      packages.${system}.default = nixos-generators.nixosGenerate {
        inherit system pkgs;

        modules = [
          ({ pkgs, modulesPath, ... }: {
            boot.loader.timeout = 0;

            virtualisation.rosetta.enable = true;

            environment.systemPackages = [
              pkgs.file
              x86Pkgs.bottom
            ];

            users.users.root.password = "nixos";
            services.openssh.permitRootLogin = "yes";
            services.getty.autologinUser = "root";
          })
        ];
        format = "iso";
      };
    };
}
