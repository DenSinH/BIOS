{
  description = "GBA replacement BIOS dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    devkitNix = {
      url = "github:bandithedoge/devkitNix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      devkitNix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ devkitNix.overlays.default ];
        };
      in
      {
        # stdenvARM sets DEVKITPRO and DEVKITARM and adds devkitARM to the shell
        devShells.default = pkgs.mkShell.override { stdenv = pkgs.devkitNix.stdenvARM; } {
          shellHook = ''
            echo "DEVKITARM=$DEVKITARM"
          '';
        };

        packages.default = pkgs.devkitNix.stdenvARM.mkDerivation {
          name = "gba-bios";
          src = ./.;
          buildPhase = ''
            runHook preBuild
            sh ./make.sh
            runHook postBuild
          '';
          installPhase = ''
            install -Dm644 bios.bin $out/bios.bin
          '';
        };
        formatter = pkgs.nixfmt-tree;
      }
    );
}
