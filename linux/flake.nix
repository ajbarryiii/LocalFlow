{
  description = "LocalFlow for Linux: package and development shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      inherit (pkgs) lib;
    in
    {
      # localflowd and localflowctl. The model export is not part of the
      # package; point `export_path` in the config at it.
      packages.${system}.default = pkgs.rustPlatform.buildRustPackage {
        pname = "localflow";
        version = "0.1.0";
        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./Cargo.toml
            ./Cargo.lock
            ./crates
          ];
        };
        cargoLock.lockFile = ./Cargo.lock;
        cargoBuildFlags = [
          "-p"
          "lf-daemon"
        ];
        nativeBuildInputs = [
          pkgs.pkg-config
          pkgs.rustPlatform.bindgenHook
        ];
        buildInputs = with pkgs; [
          libxkbcommon
          pipewire
          wayland
        ];
        # The test suite needs a private sway, PipeWire and D-Bus session and
        # runs in the development shell (see AGENTS.md), not in the sandbox.
        doCheck = false;
        meta = {
          description = "Local push-to-talk dictation for Hyprland";
          license = lib.licenses.mit;
          mainProgram = "localflowd";
          platforms = [ system ];
        };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          cargo
          clippy
          rust-analyzer
          rustc
          rustfmt
          pkg-config
          # Private headless compositor for the lf-wayland end-to-end test.
          sway
          # Private session bus (dbus-daemon) for the media-pause test.
          dbus
        ];

        buildInputs = with pkgs; [
          libxkbcommon
          pipewire
          wayland
        ];

        # pipewire-sys and libspa-sys generate their bindings with bindgen;
        # the hook sets LIBCLANG_PATH and the libc include paths clang needs.
        nativeBuildInputs = [ pkgs.rustPlatform.bindgenHook ];
      };
    };
}
