{ pkgs, sops-nix, ... }:
let
  cfgs = import ../../configs { inherit pkgs; };
  testAgeKeyFile = ../../configs/fixtures/sops-test-age-key.txt;
  testSecretsFile = ../../configs/fixtures/secrets.yaml;

  testConfig = cfgs.scenarios.api // {
    users = cfgs.scenarios.api.users // {
      alice = (builtins.removeAttrs cfgs.scenarios.api.users.alice [ "passwordHash" ]) // {
        passwordHashFile = "/run/secrets/alice-password";
      };
    };
  };
  testConfigFile = (pkgs.formats.toml { }).generate "config.toml" testConfig;
in
pkgs.testers.runNixOSTest {
  name = "integration/password-change";

  nodes.nixwall = { ... }: {
    imports = [
      ../../vms/firewall.nix
      ../../../modules/nixwall.nix
      sops-nix.nixosModules.sops
    ];

    environment.etc."nixwall-test-sops-key".source = testAgeKeyFile;
    sops = {
      defaultSopsFile = testSecretsFile;
      age.keyFile = "/etc/nixwall-test-sops-key";
      secrets."alice-password".path = "/run/secrets/alice-password";
    };
    environment.systemPackages = [ pkgs.sops ];
    systemd.tmpfiles.rules = [
      "d /var/lib/nixwall 0755 root root -"
      "L+ /var/lib/nixwall/sops-age-key.txt - - - - ${testAgeKeyFile}"
    ];

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
      config = testConfig;
    };

    system.activationScripts.nixwallTestGitInit.text = ''
      set -euo pipefail
      mkdir -p /etc/nixos
      cp ${testConfigFile} /etc/nixos/config.toml
      cp ${testSecretsFile} /etc/nixos/secrets.yaml
      chmod 600 /etc/nixos/secrets.yaml
      if [ ! -d /etc/nixos/.git ]; then
        export GIT_AUTHOR_NAME='NixWall Test'
        export GIT_AUTHOR_EMAIL='test@nixwall.invalid'
        export GIT_COMMITTER_NAME='NixWall Test'
        export GIT_COMMITTER_EMAIL='test@nixwall.invalid'
        ${pkgs.git}/bin/git -C /etc/nixos init -b main
        ${pkgs.git}/bin/git -C /etc/nixos add -A
        ${pkgs.git}/bin/git -C /etc/nixos commit -m initial
      fi
    '';
  };

  testScript = ''
    import json

    start_all()
    nixwall.wait_for_unit("multi-user.target")
    nixwall.wait_for_unit("nixwall-tls.service")
    nixwall.wait_for_unit("nixwall-api.service")

    def decrypt_secret(key):
        out = nixwall.succeed(
            "SOPS_AGE_KEY_FILE=/var/lib/nixwall/sops-age-key.txt sops --decrypt /etc/nixos/secrets.yaml"
        )
        for line in out.splitlines():
            if line.startswith(f"{key}:"):
                return line.split(":", 1)[1].strip()
        raise AssertionError(f"key {key!r} not found in decrypted secrets.yaml")

    initial_secret = decrypt_secret("alice-password")
    assert initial_secret.startswith("$"), f"seeded hash looks wrong: {initial_secret!r}"

    status = nixwall.succeed(
        "curl -sSk -u bob:changeme -o /dev/null -w '%{http_code}' "
        "-X POST https://10.10.10.1:8080/users/bob/password "
        "-H 'Content-Type: application/json' --data '{\"password\":\"whatever\"}'"
    ).strip()
    assert status == "400", f"expected 400 for an unprovisioned user, got {status}"

    guard_secret = decrypt_secret("alice-password")

    status = nixwall.succeed(
        "curl -sSk -u bob:changeme -o /dev/null -w '%{http_code}' "
        "-X POST https://10.10.10.1:8080/users/alice/password "
        "-H 'Content-Type: application/json' --data '{\"password\":\"\"}'"
    ).strip()
    assert status == "400", f"expected 400 for an empty password, got {status}"
    assert decrypt_secret("alice-password") == guard_secret, (
        "an empty password should not have touched secrets.yaml"
    )

    status = nixwall.succeed(
        "curl -sSk -u bob:changeme -o /dev/null -w '%{http_code}' "
        "-X POST https://10.10.10.1:8080/users/alice/password "
        "-H 'Content-Type: application/json' --data '{\"password\":\"hello\\nworld\"}'"
    ).strip()
    assert status == "400", f"expected 400 for a password containing a newline, got {status}"
    assert decrypt_secret("alice-password") == guard_secret, (
        "a newline-containing password should not have touched secrets.yaml"
    )

    before_secret = decrypt_secret("alice-password")
    resp = nixwall.succeed(
        "curl -sSk -u bob:changeme "
        "-X POST https://10.10.10.1:8080/users/alice/password "
        "-H 'Content-Type: application/json' --data '{\"password\":\"newpassword123\"}'"
    )
    job = json.loads(resp)
    assert job["status"] == "queued", f"expected a queued apply, got {resp!r}"

    after_secret = decrypt_secret("alice-password")
    assert after_secret != before_secret, "secrets.yaml was not updated by the password change"
    assert after_secret.startswith("$"), f"new hash in secrets.yaml looks wrong: {after_secret!r}"

    nixwall.succeed(f"systemctl list-units --all | grep -q {job['unit']}")
  '';
}
