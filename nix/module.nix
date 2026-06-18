# NixOS module for corplink-rs.
#
# Provides a systemd service modelled on systemd/corplink-rs.service. The client
# needs to create a TUN device and edit the routing table, so the unit runs with
# CAP_NET_ADMIN (it does not need full root that way). Because corplink-rs
# rewrites its config file in place (persisting the generated wg keypair,
# device_id, resolved server and login state) and writes a sibling cookies.json,
# the service uses a writable StateDirectory rather than the read-only Nix store.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.corplink-rs;
in
{
  options.services.corplink-rs = {
    enable = lib.mkEnableOption "corplink-rs Feilian VPN client";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.corplink-rs;
      defaultText = lib.literalExpression "pkgs.corplink-rs";
      description = "The corplink-rs package to use.";
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the corplink-rs config.json. It is copied into the service's
        StateDirectory on start (the binary rewrites it in place, so the
        original is left untouched). Keep secrets out of the Nix store: point
        this at a path provided via sops/agenix or a plain /etc file.
      '';
      example = "/etc/corplink/config.json";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments appended to the corplink-rs invocation.";
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "RUST_LOG value for the service (e.g. info, debug).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.corplink-rs = {
      description = "Corplink client written in Rust";
      documentation = [ "https://github.com/PinkD/corplink-rs" ];
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment.RUST_LOG = cfg.logLevel;

      # Seed a writable config from the (possibly store-path/secret) source.
      # corplink-rs persists generated fields back into this file at runtime.
      preStart = ''
        if [ ! -e "$STATE_DIRECTORY/config.json" ]; then
          install -m600 ${lib.escapeShellArg (toString cfg.configFile)} "$STATE_DIRECTORY/config.json"
        fi
      '';

      serviceConfig = {
        Type = "simple";
        StateDirectory = "corplink";
        WorkingDirectory = "/var/lib/corplink";
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe cfg.package)
            "/var/lib/corplink/config.json"
          ]
          ++ cfg.extraArgs
        );
        # Graceful shutdown path (disconnect, restore DNS, logout) runs on
        # SIGINT/SIGTERM; main.rs handles both.
        KillSignal = "SIGINT";
        Restart = "on-failure";
        RestartSec = "60s";

        # Enough privilege to manage the TUN device + routes, without full root.
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        # tun device
        DeviceAllow = [ "/dev/net/tun rw" ];

        # Hardening (kept permissive enough for TUN + /etc/resolv.conf rewrite).
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
      };
    };
  };
}
