{
  description = "LocalFlow for Linux: package and development shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      inherit (pkgs) lib;
      # PyTorch's CUDA wheels are unfree. Only the training shell uses this
      # import; the package and the default shell stay on the free `pkgs`.
      # CUDA libraries nixpkgs builds from source (NCCL) target only the
      # training GPU, an RTX 5090 (Blackwell, sm_120).
      trainPkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          cudaCapabilities = [ "12.0" ];
        };
      };
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

      devShells.${system} = {
        default = pkgs.mkShell {
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

        # Training-only shell for the word-boosting experiment
        # (tools/learned-bias). Never used at runtime or by the package.
        train = trainPkgs.mkShell {
          packages = [
            (trainPkgs.python3.withPackages (
              ps:
              let
                # nixpkgs' triton-bin patches libcuda_dirs() to return the
                # string ".../lib/libcuda.so"; Triton then splats it into
                # per-character -L flags and its runtime build of
                # cuda_utils.c fails to link libcuda.so.1. Return the driver
                # directory as a list instead (a wheel, so no source build).
                driverLib = "${trainPkgs.addDriverRunpath.driverLink}/lib";
                broken = "return '${driverLib}/libcuda.so'";
                triton = ps.triton-bin.overridePythonAttrs (old: {
                  postFixup =
                    assert trainPkgs.lib.hasInfix broken old.postFixup;
                    builtins.replaceStrings [ broken ] [ "return ['${driverLib}']" ] old.postFixup;
                });
              in
              [
                # The torch-bin wheel targets CUDA 13.0 (cu130); the default
                # cudaPackages is 12.x, which nixpkgs marks as broken for it.
                (ps.torch-bin.override {
                  cudaPackages = trainPkgs.cudaPackages_13_0;
                  inherit triton;
                })
                ps.safetensors
                ps.numpy
              ]
            ))
          ];
          # libcuda comes from the NixOS driver (/run/opengl-driver/lib),
          # which torch-bin's runpath already includes.
        };
      };
    };
}
