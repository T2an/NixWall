{
  pkgs,
  lib,
  config,
  ...
}:

{
  assertions = [
    {
      assertion = lib.all (
        u:
        !(u ? passwordHashFile)
        ||
          ((config.sops.secrets.${baseNameOf u.passwordHashFile} or { }).path or null) == u.passwordHashFile
      ) (lib.attrValues (config.nixwall.internal.users or { }));
      message = "nixwall: a user's passwordHashFile must match a sops.secrets.<name> whose name and path both agree with it (name = basename of the path) -- the API derives the sops key to update from that basename.";
    }
  ];

  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."alice-password".path = "/run/secrets/alice-password";
  };

  systemd = {
    tmpfiles.rules = [ "d /var/lib/nixwall 0750 root root - -" ];

    services = {
      nixwall-sops-age-key = {
        description = "Derive an age key from the host SSH key for NixWall's sops CLI calls";
        wantedBy = [ "multi-user.target" ];
        after = [ "sshd-keygen.service" ];
        before = [ "nixwall-api.service" ];
        path = [ pkgs.ssh-to-age ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = [ "/var/lib/nixwall" ];
        };
        script = ''
          set -euo pipefail
          if [ ! -s /var/lib/nixwall/sops-age-key.txt ]; then
            ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key > /var/lib/nixwall/sops-age-key.txt
            chmod 600 /var/lib/nixwall/sops-age-key.txt
          fi
        '';
      };
      nixwall-api = {
        wants = [ "nixwall-sops-age-key.service" ];
        after = [ "nixwall-sops-age-key.service" ];
      };
    };
  };

  nixwall = {
    enable = true;
    appliance = {
      enable = true;
      tls.enable = true;
      tls.generateSelfSigned = true;
      auth.enable = true;
      api.enable = true;
      seedEtc.enable = false;
    };
    configFile = ./config.toml;
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  system.stateVersion = "25.05";
}
