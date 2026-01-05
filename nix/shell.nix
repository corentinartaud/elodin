{
  config,
  pkgs,
  rustToolchain,
  ...
}:
with pkgs; let
  # Import shared configuration
  common = pkgs.callPackage ./pkgs/common.nix {};
  xla_ext = pkgs.callPackage ./pkgs/xla-ext.nix {system = pkgs.stdenv.hostPlatform.system;};
  llvm = llvmPackages_latest;

  # Import shared JAX overrides
  jaxOverrides = pkgs.callPackage ./pkgs/jax-overrides.nix {inherit pkgs;};

  # Create a Python environment with the same JAX version as our pyproject.toml
  pythonWithJax = let
    python3' = python3.override {
      packageOverrides = jaxOverrides;
    };
  in
    python3'.withPackages (ps:
      with ps; [
        jax
        jaxlib
        typing-extensions
        pytest
        pytest-json-report
        matplotlib
        polars
        numpy
      ]);
in {
  # Unified shell that combines all development environments
  elodin = mkShell (
    {
      name = "elo-unified-shell";

      # Force CMake/Cargo to use the correct Nix compilers
      FC = "${pkgs.gfortran}/bin/gfortran";
      F77 = "${pkgs.gfortran}/bin/gfortran";
      F90 = "${pkgs.gfortran}/bin/gfortran";
      CC = "${pkgs.gcc}/bin/gcc";
      CXX = "${pkgs.gcc}/bin/g++";
      
      buildInputs =
        [
          # Interactive bash (required for nix develop to work properly)
          bashInteractive

          # Shell stack
          zsh
          oh-my-zsh
          zsh-powerlevel10k
          zsh-completions

          # Enhanced CLI tools
          eza # Better ls
          bat # Better cat
          delta # Better git diff
          fzf # Fuzzy finder
          fd # Better find
          ripgrep # Better grep
          zoxide # Smart cd
          direnv # Directory environments
          nix-direnv # Nix integration for direnv
          vim # Editor
          less # Pager

          # Fonts for terminal (MesloLGS for p10k)
          (nerd-fonts.meslo-lg)

          # Rust toolchain and tools
          buildkite-test-collector-rust
          (rustToolchain pkgs)
          cargo-nextest
          # Use our custom Python with JAX 0.4.31
          pythonWithJax
          clang
          maturin
          bzip2
          libclang
          ffmpeg-full
          ffmpeg-full.dev
          gst_all_1.gstreamer
          gst_all_1.gst-plugins-base
          gst_all_1.gst-plugins-good
          flip-link

          # Python tools
          ruff
          uv

          # Operations tools
          skopeo
          gettext
          just
          docker
          kubectl
          jq
          yq
          git-filter-repo
          git-lfs
          (google-cloud-sdk.withExtraComponents (
            with google-cloud-sdk.components; [gke-gcloud-auth-plugin]
          ))
          azure-cli

          # Documentation and quality tools
          alejandra
          typos
          zola
          rav1e

          # FIX: Add a consistent C/Fortran toolchain
          gcc
          gfortran
          binutils
          openblas
        ]
        ++ common.commonNativeBuildInputs
        ++ common.commonBuildInputs
        # Linux-specific dependencies
        ++ lib.optionals pkgs.stdenv.isLinux (
          common.linuxGraphicsAudioDeps
          ++ [
            # Additional Linux-specific tools not in common
            alsa-oss
            alsa-utils
            gtk3
            fontconfig
            lldb
            autoPatchelfHook
            config.packages.elodin-py.py
          ]
        )
        # macOS-specific dependencies
        ++ lib.optionals pkgs.stdenv.isDarwin (
          common.darwinDeps
          ++ [
            fixDarwinDylibNames
          ]
        );

      nativeBuildInputs = with pkgs; (
        lib.optionals pkgs.stdenv.isLinux [autoPatchelfHook]
        ++ lib.optionals pkgs.stdenv.isDarwin [fixDarwinDylibNames]
      );

      # Environment variables
      LIBCLANG_PATH = "${libclang.lib}/lib";
      XLA_EXTENSION_DIR = "${xla_ext}";

      # Workaround for netlib-src 0.8.0 incompatibility with GCC 14+
      # GCC 14 treats -Wincompatible-pointer-types as error by default
      NIX_CFLAGS_COMPILE = common.netlibWorkaround;

      LLDB_DEBUGSERVER_PATH = lib.optionalString pkgs.stdenv.isDarwin "/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver";

      # Set up library paths for Linux graphics/audio
      LD_LIBRARY_PATH = lib.optionalString pkgs.stdenv.isLinux (
        common.makeLinuxLibraryPath {inherit pkgs;}
      );

      doCheck = false;

      shellHook = ''
        # For NVIDIA users on non-NixOS: build nixGL wrapper on first use
        _build_nixgl_nvidia() {
          local version="$1"
          local nixgl_dir="$HOME/.cache/nixgl-nvidia-$version"
          if [ ! -d "$nixgl_dir" ]; then
            echo "Building nixGL for NVIDIA driver $version (first time only)..."
            nix build --builders "" --impure --expr "
              let 
                pkgs = import (builtins.getFlake \"github:NixOS/nixpkgs/nixos-25.05\").outPath { 
                  system = \"x86_64-linux\"; 
                  config.allowUnfree = true; 
                };
                nixGL = import (builtins.getFlake \"github:nix-community/nixGL\").outPath {
                  inherit pkgs;
                  nvidiaVersion = \"$version\";
                  enable32bits = false;
                };
              in nixGL.nixVulkanNvidia
            " -o "$nixgl_dir" 2>&1
          fi
          echo "$nixgl_dir/bin/nixVulkanNvidia-$version"
        }

        # Wrapper function for running elodin with NVIDIA on non-NixOS
        elodin-nvidia() {
          if [ -f /proc/driver/nvidia/version ]; then
            local nvidia_version=$(grep -oP '(?<=Module  )[0-9.]+' /proc/driver/nvidia/version 2>/dev/null || echo "")
            if [ -n "$nvidia_version" ]; then
              local wrapper=$(_build_nixgl_nvidia "$nvidia_version")
              if [ -x "$wrapper" ]; then
                exec "$wrapper" elodin "$@"
              else
                echo "Error: Failed to build nixGL wrapper"
                return 1
              fi
            fi
          fi
          echo "Error: NVIDIA driver not detected. Use 'elodin' directly for non-NVIDIA systems."
          return 1
        }
        export -f _build_nixgl_nvidia elodin-nvidia 2>/dev/null || true

        # start the shell if we're in an interactive shell
        if [[ $- == *i* ]]; then
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "🚀 Elodin Development Shell (Nix)"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo ""
          echo "Environment ready:"
          echo "  • Rust: cargo, clippy, nextest"
          echo "  • Tools: uv, maturin, ruff, just, kubectl, gcloud"
          echo "  • Shell tools: eza, bat, delta, fzf, ripgrep, zoxide"
          echo ""
          if [ -f /proc/driver/nvidia/version ]; then
            echo "NVIDIA GPU detected! Use 'elodin-nvidia editor' for GPU acceleration."
          fi
          echo ""
          echo "SDK Development (if needed):"
          echo "  "
          echo "uv venv --python 3.12"
          echo "source .venv/bin/activate"
          echo "uvx maturin develop --uv --manifest-path=libs/nox-py/Cargo.toml"
          echo ""

          exec ${pkgs.zsh}/bin/zsh
        fi
      '';
    }
    // lib.optionalAttrs pkgs.stdenv.isLinux (
      common.linuxGraphicsEnv {inherit pkgs;}
    )
  );
}
