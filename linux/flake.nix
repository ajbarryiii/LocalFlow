{
  description = "LocalFlow for Linux: package and development shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      inherit (pkgs) lib;

      # localflowd and localflowctl, the systemd user unit, the desktop file
      # for the portal trigger, and the compositor binds as examples. The
      # model export is a separate package (below) or any export directory;
      # `export_path` in the config points at it.
      localflow = pkgs.rustPlatform.buildRustPackage {
        pname = "localflow";
        version = "0.1.0";
        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./Cargo.toml
            ./Cargo.lock
            ./crates
            ./models.json
            ./packaging/localflowd.service
            ./packaging/com.ajbarryiii.localflow.desktop
            ./packaging/hyprland.conf
            ./packaging/sway.conf
            ./packaging/niri.kdl
            ./packaging/river-init.sh
          ];
        };
        cargoLock.lockFile = ./Cargo.lock;
        cargoBuildFlags = [
          "-p"
          "lf-daemon"
        ];
        # localflow-t3-bridge.service is left out: the T3 Code bridge is for
        # manual setups only.
        postInstall = ''
          # stdenv moves user units to share/systemd/user (for Home Manager)
          # and links lib/systemd/user (for NixOS) to it.
          unit=$out/lib/systemd/user/localflowd.service
          install -D -m 644 packaging/localflowd.service $unit
          # --replace-fail stops the build if the unit's ExecStart line changes.
          substituteInPlace $unit \
            --replace-fail 'ExecStart=%h/.local/bin/localflowd' "ExecStart=$out/bin/localflowd"

          # The file name is the app ID the portal trigger registers. The
          # file only names the app (it is hidden), and Exec stays a bare
          # `localflowd`: desktops find the file through the same profile
          # that puts localflowd on PATH, and a copy made outside the store
          # keeps working after an upgrade.
          install -D -m 644 -t $out/share/applications packaging/com.ajbarryiii.localflow.desktop

          install -D -m 644 -t $out/share/doc/localflow/examples \
            packaging/hyprland.conf packaging/sway.conf packaging/niri.kdl packaging/river-init.sh
        '';
        nativeBuildInputs = [
          pkgs.makeBinaryWrapper
          pkgs.pkg-config
          pkgs.rustPlatform.bindgenHook
        ];
        buildInputs = with pkgs; [
          libxkbcommon
          pipewire
          wayland
        ];
        # `localflowctl fetch-model` downloads with curl. A compiled wrapper,
        # because key binds run localflowctl on every press and release.
        postFixup = ''
          wrapProgram $out/bin/localflowctl --prefix PATH : ${lib.makeBinPath [ pkgs.curl ]}
        '';
        # The test suite needs a private sway, PipeWire and D-Bus session and
        # runs in the development shell (see AGENTS.md), not in the sandbox.
        doCheck = false;
        meta = {
          description = "Local push-to-talk dictation for Wayland and X11 desktops";
          homepage = "https://github.com/ajbarryiii/LocalFlow";
          license = lib.licenses.mit;
          mainProgram = "localflowd";
          platforms = [ system ];
        };
      };

      # The published model exports, pinned to a Hugging Face revision in
      # models.json (`localflowctl fetch-model` reads the same pins). The
      # export files' hashes are the ones in each export's manifest.json,
      # which the daemon checks again when it loads the model. Both models
      # are derived from NVIDIA's parakeet-tdt-0.6b-v2 and licensed
      # CC-BY-4.0 (see LICENSE and NOTICE in the export). kea-b has 1-bit
      # weights (parakeet-binary-v1) and is the recommended model; kea-t has
      # ternary weights (parakeet-ternary-v1): slightly lower WER, twice the
      # weight memory, a little slower.
      models = lib.importJSON ./models.json;

      # An export directory in the store. Files are copied, not linked: the
      # daemon refuses export files that resolve outside the directory.
      model =
        name: m:
        pkgs.runCommand "localflow-model-${name}"
          {
            meta = {
              description = "LocalFlow speech model export (${m.repo})";
              homepage = "https://huggingface.co/${m.repo}";
              license = lib.licenses.cc-by-40;
            };
          }
          (
            lib.concatStrings (
              lib.mapAttrsToList (path: sha256: ''
                install -D -m 444 ${
                  pkgs.fetchurl {
                    url = "https://huggingface.co/${m.repo}/resolve/${m.rev}/${path}";
                    name = "${name}-${baseNameOf path}";
                    inherit sha256;
                  }
                } "$out/${path}"
              '') m.files
            )
          );
    in
    {
      # `default` is the program. `kea-b` and `kea-t` are model exports:
      # `export_path` can be "${localflow.packages.<system>.kea-b}".
      packages.${system} = lib.mapAttrs model models // {
        default = localflow;
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
