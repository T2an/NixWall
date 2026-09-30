{ pkgs, ... }:
let
  cfgs = import ../../configs { inherit pkgs; };
in
pkgs.testers.runNixOSTest {
  name = "unit/dns-setting";

  nodes.nixwall = { ... }: {
    imports = [
      ../../vms/firewall.nix
      ../../../modules/nixwall.nix
    ];
    environment.systemPackages = [ pkgs.dig ];
    nixwall = {
      enable = true;
      config = cfgs.mk [ { zones.WAN.dns = [ "10.100.100.101" ]; } ];
    };
  };

  nodes.dns = { ... }: {
    imports = [
      ../../vms/dns.nix
      ../../helpers/dns.nix
    ];
  };

  testScript = ''
    start_all()
    nixwall.wait_for_unit("multi-user.target")
    dns.wait_for_unit("multi-user.target")
    # wait_for_unit only guarantees the systemd unit started, not that
    # CoreDNS's UDP listener is actually accepting queries yet (Go runtime
    # init + plugin chain setup takes a moment) -- without this the dig
    # calls below are flaky, racing that startup.
    dns.wait_for_open_port(53, "udp")

    nixwall.succeed("resolvectl dns | grep 10.100.100.101")

    nixwall.succeed("dig +short website.net @10.100.100.101 | grep 10.100.100.100")

    nixwall.succeed("dig +short website.net | grep 10.100.100.100")
  '';
}
