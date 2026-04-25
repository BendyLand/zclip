let
  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-25.11.tar.gz";
  pkgs = import nixpkgs {};
in
pkgs.mkShell {
  buildInputs = [
    pkgs.zig_0_14
    pkgs.zls
    pkgs.pkg-config
    pkgs.xorg.libX11
    pkgs.xorg.libXfixes
  ];

  shellHook = ''
    echo "--- zclip development environment (Zig 0.14.1) ---"
  '';
}

