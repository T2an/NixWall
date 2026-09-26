{
  lib,
  pkgs,
  config,
  ...
}:
let
  remotes = config.nixwall.internal.git.remotes or { };
  etcRelPath = "nixwall/git-remotes.json";
in
{
  options.nixwall.appliance.git = {
    remotesPath = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/etc/${etcRelPath}";
      description = "Where [git.remotes] is materialized for the API. Generated, not configurable.";
    };
  };

  config = lib.mkIf (config.nixwall.enable && config.nixwall.appliance.enable) {
    programs.git = {
      enable = true;
      config = {
        user.name = "NixWall API";
        user.email = "api@nixwall.local";
        init.defaultBranch = "main";
      };
    };

    environment.etc.${etcRelPath}.source = pkgs.writeText "nixwall-git-remotes.json" (
      builtins.toJSON remotes
    );
  };
}
