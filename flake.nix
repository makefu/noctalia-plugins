{
  description = "noctalia-shell plugins";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    {
      # NixOS module for the nostr-chat plugin's daemon + systemd user unit.
      #
      #   inputs.noctalia-plugins.url = "github:Mic92/noctalia-plugins";
      #   imports = [ inputs.noctalia-plugins.nixosModules.nostr-chat ];
      #   services.nostr-chat = { peerPubkey = "…"; relays = [ … ]; };
      #
      nixosModules.nostr-chat = ./nostr-chat/module.nix;
      nixosModules.default = self.nixosModules.nostr-chat;

      # Standalone daemon package, in case you want to run it without NixOS.
      packages = forAllSystems (system: {
        nostr-chatd = nixpkgs.legacyPackages.${system}.callPackage ./nostr-chat/daemon { };
        # SSH_ASKPASS stub that proxies prompts to the running noctalia shell.
        # Point your agent's SSH_ASKPASS at lib.getExe of this.
        noctalia-ssh-askpass = nixpkgs.legacyPackages.${system}.callPackage ./ssh-askpass/stub { };
        default = self.packages.${system}.nostr-chatd;
      });

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          nostr-chatd = self.packages.${system}.nostr-chatd;
          noctalia-ssh-askpass = self.packages.${system}.noctalia-ssh-askpass;

          # Composer geometry unit tests (pure Luau, no display).
          luau-geometry =
            pkgs.runCommand "nostr-chat-luau-geometry"
              {
                nativeBuildInputs = [ pkgs.luau ];
                src = ./nostr-chat;
              }
              ''
                luau $src/tests/compose_geometry_test.luau
                touch $out
              '';
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # Nested-compositor pixel E2E: weston headless + noctalia + grim.
          composer-e2e =
            pkgs.runCommand "nostr-chat-composer-e2e"
              {
                nativeBuildInputs = [
                  pkgs.noctalia
                  pkgs.weston
                  pkgs.labwc
                  pkgs.grim
                  pkgs.luau
                  pkgs.python3
                  pkgs.dbus
                  pkgs.mesa
                ];
                src = ./nostr-chat;
                NOSTR_CHATD = "${self.packages.${system}.nostr-chatd}/bin/nostr-chatd";
              }
              ''
                export NOCTALIA=${pkgs.noctalia}/bin/noctalia
                export WESTON=${pkgs.weston}/bin/weston
                export LABWC=${pkgs.labwc}/bin/labwc
                export GRIM=${pkgs.grim}/bin/grim
                export LUAU=${pkgs.luau}/bin/luau
                # noctalia's static Qt dlopens libEGL from /run/opengl-driver,
                # which only exists on a system with an OpenGL driver. Point it
                # at mesa and force the llvmpipe software rasteriser.
                export LD_LIBRARY_PATH=${pkgs.mesa}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
                export __EGL_VENDOR_LIBRARY_FILENAMES=${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json
                export GALLIUM_DRIVER=llvmpipe
                export LIBGL_ALWAYS_SOFTWARE=1
                bash $src/tests/composer-e2e.sh
                touch $out
              '';
          # Same nested chain; drives the bubble Inputs with a virtual
          # pointer and asserts clipboard contents via wl-paste.
          selection-e2e =
            pkgs.runCommand "nostr-chat-selection-e2e"
              {
                nativeBuildInputs = [
                  pkgs.noctalia
                  pkgs.weston
                  pkgs.labwc
                  pkgs.grim
                  pkgs.python3
                  pkgs.dbus
                  pkgs.wl-clipboard
                  pkgs.wtype
                  pkgs.mesa
                ];
                src = ./nostr-chat;
              }
              ''
                export NOCTALIA=${pkgs.noctalia}/bin/noctalia
                export WESTON=${pkgs.weston}/bin/weston
                export LABWC=${pkgs.labwc}/bin/labwc
                export GRIM=${pkgs.grim}/bin/grim
                export WL_PASTE=${pkgs.wl-clipboard}/bin/wl-paste
                export WTYPE=${pkgs.wtype}/bin/wtype
                # noctalia's static Qt dlopens libEGL from /run/opengl-driver,
                # which only exists on a system with an OpenGL driver. Point it
                # at mesa and force the llvmpipe software rasteriser.
                export LD_LIBRARY_PATH=${pkgs.mesa}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
                export __EGL_VENDOR_LIBRARY_FILENAMES=${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json
                export GALLIUM_DRIVER=llvmpipe
                export LIBGL_ALWAYS_SOFTWARE=1
                bash $src/tests/selection-e2e.sh
                touch $out
              '';
        }
      );
    };
}
