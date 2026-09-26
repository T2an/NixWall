{ pkgs, ... }:
let
  cfgs = import ../../configs { inherit pkgs; };
  testConfig = pkgs.lib.recursiveUpdate cfgs.scenarios.api {
    git.remotes = {
      backup.url = "/var/lib/nixwall-test-backup.git";
      "manual-only" = {
        url = "/var/lib/nixwall-test-manual.git";
        autoBackup = false;
      };
    };
  };
  testConfigFile = (pkgs.formats.toml { }).generate "config.toml" testConfig;
in
pkgs.testers.runNixOSTest {
  name = "integration/git-remotes";

  nodes.nixwall = { ... }: {
    imports = [
      ../../vms/firewall.nix
      ../../../modules/nixwall.nix
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
    start_all()
    nixwall.wait_for_unit("multi-user.target")
    nixwall.wait_for_unit("nixwall-tls.service")
    nixwall.wait_for_unit("nixwall-api.service")

    def write_json(path, content):
        nixwall.succeed(f"cat > {path} << 'JSONEOF'\n{content}\nJSONEOF")

    nixwall.succeed("git init -q --bare /var/lib/nixwall-test-backup.git")
    nixwall.succeed("git init -q --bare /var/lib/nixwall-test-manual.git")

    write_json("/tmp/p_legit.json", '{"remote":"backup","branch":"main"}')
    nixwall.succeed(
        "curl -sSk -u alice:changeme -X POST https://10.10.10.1:8080/git/push "
        "-H 'Content-Type: application/json' --data @/tmp/p_legit.json"
    )
    nixwall.succeed("git -C /var/lib/nixwall-test-backup.git log --oneline -1")

    write_json("/tmp/p_unknown.json", '{"remote":"/var/lib/some-other-repo.git","branch":"main"}')
    nixwall.fail(
        "curl -sSk -u alice:changeme -X POST https://10.10.10.1:8080/git/push "
        "-H 'Content-Type: application/json' --data @/tmp/p_unknown.json "
        "| grep -q '\"rc\":0'"
    )

    nixwall.succeed("rm -f /tmp/pwned-ext")
    write_json(
        "/tmp/p_ext.json",
        '{"remote":"ext::sh -c \\"touch /tmp/pwned-ext\\"","branch":"HEAD"}',
    )
    nixwall.fail(
        "curl -sSk -u alice:changeme -X POST https://10.10.10.1:8080/git/push "
        "-H 'Content-Type: application/json' --data @/tmp/p_ext.json "
        "| grep -q '\"rc\":0'"
    )
    nixwall.fail("test -e /tmp/pwned-ext")

    pid = nixwall.succeed("systemctl show nixwall-api.service -p MainPID --value").strip()
    binary = nixwall.succeed(f"readlink -f /proc/{pid}/exe").strip()

    before_snap = nixwall.succeed("git -C /etc/nixos log --oneline | wc -l").strip()
    nixwall.succeed(f"{binary} --apply-and-snapshot true")
    after_noop = nixwall.succeed("git -C /etc/nixos log --oneline | wc -l").strip()
    assert before_snap == after_noop, (
        f"snapshot committed with nothing changed: {before_snap!r} -> {after_noop!r}"
    )

    nixwall.succeed("echo '# a real config change' >> /etc/nixos/config.toml")
    nixwall.succeed(f"{binary} --apply-and-snapshot true")
    after_change = nixwall.succeed("git -C /etc/nixos log --oneline | wc -l").strip()
    assert int(after_change) == int(after_noop) + 1, (
        f"snapshot did not commit a real change: {after_noop!r} -> {after_change!r}"
    )

    local_head = nixwall.succeed("git -C /etc/nixos log --oneline -1").strip()
    backup_head = nixwall.succeed("git -C /var/lib/nixwall-test-backup.git log --oneline -1").strip()
    assert local_head == backup_head, f"backup wasn't pushed: {local_head!r} != {backup_head!r}"

    manual_status = nixwall.execute("git -C /var/lib/nixwall-test-manual.git log --oneline -1")
    assert manual_status[0] != 0, "autoBackup=false remote received an automatic push"

    nixwall.succeed("echo '# a change behind a failing wrapped command' >> /etc/nixos/config.toml")
    nixwall.fail(f"{binary} --apply-and-snapshot false")
    after_failure = nixwall.succeed("git -C /etc/nixos log --oneline | wc -l").strip()
    assert int(after_failure) == int(after_change), (
        f"snapshot ran even though the wrapped command failed: {after_change!r} -> {after_failure!r}"
    )

    nixwall.succeed("rm -rf /tmp/work && git clone -q /var/lib/nixwall-test-backup.git /tmp/work")
    nixwall.succeed(
        "cd /tmp/work && git checkout -q main "
        "&& echo x > a.txt && git -c user.email=t@t -c user.name=t add a.txt "
        "&& git -c user.email=t@t -c user.name=t commit -q -m a "
        "&& git push -q origin main"
    )
    nixwall.succeed(
        "cd /tmp/work && git reset -q --hard HEAD~1 "
        "&& echo y > b.txt && git -c user.email=t@t -c user.name=t add b.txt "
        "&& git -c user.email=t@t -c user.name=t commit -q -m diverged"
    )
    nixwall.succeed("rm -rf /etc/nixos && cp -r /tmp/work /etc/nixos")
    before_force = nixwall.succeed("git -C /var/lib/nixwall-test-backup.git log --oneline -1").strip()

    write_json("/tmp/p_force.json", '{"remote":"backup","branch":"--force"}')
    nixwall.succeed(
        "curl -sSk -u alice:changeme -X POST https://10.10.10.1:8080/git/push "
        "-H 'Content-Type: application/json' --data @/tmp/p_force.json"
    )
    after_force = nixwall.succeed("git -C /var/lib/nixwall-test-backup.git log --oneline -1").strip()
    assert before_force == after_force, (
        f"non-fast-forward protection was bypassed: {before_force!r} -> {after_force!r}"
    )
  '';
}
