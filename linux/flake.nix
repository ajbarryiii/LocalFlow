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
          description = "Local push-to-talk dictation for Wayland and X11 desktops";
          homepage = "https://github.com/ajbarryiii/LocalFlow";
          license = lib.licenses.mit;
          mainProgram = "localflowd";
          platforms = [ system ];
        };
      };

      # The published model exports, pinned to a Hugging Face revision. The
      # export files' hashes are the ones in each export's manifest.json,
      # which the daemon checks again when it loads the model. Both models
      # are derived from NVIDIA's parakeet-tdt-0.6b-v2 and licensed
      # CC-BY-4.0 (see LICENSE and NOTICE in the export).
      tokenizer = {
        "tokenizer/tokenizer.model" = "5a3a82c48998709f9bc9f5db2924d99a899d20bf82550ca52272da7c7557b0a0";
        "tokenizer/tokenizer.vocab" = "dbe7ec6bd066c4526080940e1614e6582b9161515e856c2c39a1d49267c88cbc";
        "tokenizer/vocab.txt" = "70b25deed256d79365a3c290d6191c31cc2315d952faf18d5c3a334f46e4866e";
      };
      models = {
        # 1-bit weights (parakeet-binary-v1): the recommended model.
        kea-b = {
          repo = "rajb3/kea-b";
          rev = "cfb1353488655282683ba699c402ae3b16b6de30";
          files = tokenizer // {
            "export.safetensors" = "9873d2f1a53127c673d0201db98cd3ba859ba432f334fef55e9e24fd057b9651";
            "manifest.json" = "f3737a538da81939aabe04acd5334afd0e3cd4160ec113bd889e771b67991dbd";
            "LICENSE" = "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411";
            "NOTICE" = "314119184052a636e9002f69dd36a2077d32d5e487bbe5ba958da9f646ede56a";
          };
        };
        # Ternary weights (parakeet-ternary-v1): slightly lower WER, twice
        # the weight memory, a little slower.
        kea-t = {
          repo = "rajb3/kea-t";
          rev = "c4a1f10ad23015ea43e8fa0802c30795e0442c4f";
          files = tokenizer // {
            "export.safetensors" = "a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503";
            "manifest.json" = "5c8b4bea0393db4072351e07b0d2206079373ca52646efdec4bb30876e0c8c61";
            "LICENSE" = "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411";
            "NOTICE" = "a63eeea2b250401da1b54679221d096f9fd188c354817740639c1da4cf4cddc0";
          };
        };
      };

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
