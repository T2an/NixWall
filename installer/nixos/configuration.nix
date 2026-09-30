{
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
    age.keyFile = "/var/lib/nixwall/sops-age-key.txt";
    secrets."alice-password" = {
      path = "/run/secrets/alice-password";
      neededForUsers = true;
    };
  };

  systemd.tmpfiles.rules = [ "d /var/lib/nixwall 0750 root root - -" ];

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

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    flake-registry = "";
  };

  system.stateVersion = "25.05";
}
