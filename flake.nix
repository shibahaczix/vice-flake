{
  description = "Vice — Medal.tv-style instant-replay game clipper for Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = { pkgs, ... }:
        let
          pinnedVersion = "2.10.1";
          python = pkgs.python3;

          # Runtime tools Vice shells out to. These are NOT Python deps; they
          # have to be on PATH for the wrapped binaries.
          runtimeTools = with pkgs; [
            ffmpeg
            gpu-screen-recorder
            wf-recorder            # optional Wayland fallback backend
            wl-clipboard
            xclip
            cloudflared
            xdotool
            xprop
            wmctrl
            gst_all_1.gstreamer
            gst_all_1.gst-plugins-base
            gst_all_1.gst-plugins-good
          ];

          vice = python.pkgs.buildPythonApplication rec {
            pname = "vice";
            version = pinnedVersion;
            pyproject = true;

            src = pkgs.fetchFromGitHub {
              owner = "eklonofficial";
              repo = "Vice";
              rev = "v${version}";
              hash = "sha256-9HWlcSZyWYwiaOu0WB0uYEV63K9FhpD3tQH1OnVxGwg=";
            };

            build-system = with python.pkgs; [ setuptools wheel ];

            dependencies = with python.pkgs; [
              evdev
              aiohttp
              click
              tomli-w
              psutil
              pywebview
              # Native Qt window backend for `vice-app` (falls back to
              # WebKit2GTK if this isn't importable).
              pyqt6
              pyqt6-webengine
            ] ++ pkgs.lib.optional (python.pythonOlder "3.11") python.pkgs.tomli;

            # No test suite is wired up for a plain `pytest` run in this repo
            # (tests/ exists but relies on a live X/Wayland + input backend).
            doCheck = false;

            nativeBuildInputs = [ pkgs.makeWrapper pkgs.wrapGAppsHook3 ];
            buildInputs = [ pkgs.webkitgtk_4_1 ];

            postInstall = ''
              install -Dm644 assets/vice.svg \
                $out/share/icons/hicolor/scalable/apps/vice.svg

              install -Dm644 vice.desktop \
                $out/share/applications/vice.desktop
              substituteInPlace $out/share/applications/vice.desktop \
                --replace-fail "Exec=vice-app %u" "Exec=$out/bin/vice-app %u"

              install -Dm644 packaging/vice.rules \
                $out/lib/udev/rules.d/70-vice-input.rules
            '';

            # Make sure the CLI/daemon can always find its runtime tools,
            # even when launched from a systemd user unit with a bare PATH.
            postFixup = ''
              wrapProgram $out/bin/vice \
                --prefix PATH : ${pkgs.lib.makeBinPath runtimeTools}
              wrapProgram $out/bin/vice-app \
                --prefix PATH : ${pkgs.lib.makeBinPath runtimeTools}
            '';

            meta = with pkgs.lib; {
              description = "Instant-replay game clip recorder for Linux (Wayland + X11), Medal.tv-style";
              homepage = "https://github.com/eklonofficial/Vice";
              license = licenses.gpl3Plus;
              mainProgram = "vice-app";
              platforms = platforms.linux;
            };
          };
        in
        {
          packages = {
            default = vice;
            vice = vice;
          };

          apps = {
            default = { type = "app"; program = "${vice}/bin/vice-app"; };
            vice = { type = "app"; program = "${vice}/bin/vice"; };
            vice-app = { type = "app"; program = "${vice}/bin/vice-app"; };
          };

          devShells.default = pkgs.mkShell {
            inputsFrom = [ vice ];
            packages = [ python.pkgs.pip ] ++ runtimeTools;
          };
        };

      flake =
        {
          # NixOS module: installs the package + udev rule + an optional
          # systemd --user unit that mirrors packaging/vice.service upstream.
          nixosModules.default = { config, lib, pkgs, ... }:
            let
              cfg = config.programs.vice;
              system = pkgs.system;
              vicePkg = self.packages.${system}.default;
            in
            {
              options.programs.vice = {
                enable = lib.mkEnableOption "Vice instant-replay game clipper";

                autoStart = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = ''
                    Start the Vice recording daemon automatically as a systemd
                    user service (mirrors upstream's packaging/vice.service).
                  '';
                };
              };

              config = lib.mkIf cfg.enable {
                environment.systemPackages = [ vicePkg ];

                # Vice reads /dev/input/* via evdev for global hotkeys.
                services.udev.packages = [ vicePkg ];
                users.groups.input = { };

                # Sets up the cap_sys_admin setcap wrapper gpu-screen-recorder
                # needs to record without a polkit prompt every time.
                programs.gpu-screen-recorder.enable = true;

                systemd.user.services.vice = lib.mkIf cfg.autoStart {
                  description = "Vice game clip recorder daemon";
                  wantedBy = [ "graphical-session.target" "default.target" ];
                  after = [ "graphical-session.target" ];
                  startLimitIntervalSec = 60;
                  startLimitBurst = 3;
                  serviceConfig = {
                    Type = "simple";
                    ExecStart = "${vicePkg}/bin/vice start --no-open-ui";
                    Restart = "on-failure";
                    RestartSec = 3;
                    PassEnvironment = [
                      "WAYLAND_DISPLAY"
                      "DISPLAY"
                      "XDG_RUNTIME_DIR"
                      "DBUS_SESSION_BUS_ADDRESS"
                      "XDG_SESSION_TYPE"
                      "XDG_CURRENT_DESKTOP"
                    ];
                  };
                };
              };
            };
        };
    };
}
