{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.utils.url = "github:numtide/flake-utils";

  outputs =
    { nixpkgs, utils, ... }:
    utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.zig
            pkgs.zls
            pkgs.nixd
            pkgs.nixfmt
            pkgs.wayland
            pkgs.wayland-protocols
            pkgs.wayland-scanner
            pkgs.pkg-config
            pkgs.libxkbcommon
          ];
        };
      }
    );
}
