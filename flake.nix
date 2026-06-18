{
  description = "corplink-rs - Feilian (VeCorplink) enterprise VPN client in Rust";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2511.tar.gz";
  };

  outputs =
    { self, nixpkgs }:
    let
      # corplink-rs only targets Linux (TUN device, /etc/resolv.conf, etc).
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        rec {
          corplink-rs = pkgs.callPackage ./nix/corplink-rs.nix {
            # Build the local checkout. Use the flake WITH submodules so the
            # bundled wireguard-go fork is present:
            #   nix build '.?submodules=1'
            # Drop this line to fall back to the pinned fetchFromGitHub source
            # in nix/corplink-rs.nix (which fetches submodules itself).
            src = self;
          };
          default = corplink-rs;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            # Everything needed to run `./libwg/build.sh && cargo build` by hand.
            nativeBuildInputs = [
              pkgs.cargo
              pkgs.rustc
              pkgs.rustfmt
              pkgs.clippy
              pkgs.go
              pkgs.gnumake
              pkgs.rustPlatform.bindgenHook
            ];
          };
        }
      );

      nixosModules.corplink-rs = ./nix/module.nix;
      nixosModules.default = self.nixosModules.corplink-rs;

      # Convenience: an overlay so `pkgs.corplink-rs` resolves in the module.
      overlays.default = final: _prev: {
        corplink-rs = final.callPackage ./nix/corplink-rs.nix { src = self; };
      };

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
