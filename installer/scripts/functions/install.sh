#!/usr/bin/env bash
set -euo pipefail

generate_sops_age_key_and_secrets() {
	header "Generating the NixWall secrets key"

	age-keygen -o /root/sops-age-key.txt 2>/dev/null
	local pubkey
	pubkey="$(grep '^# public key:' /root/sops-age-key.txt | cut -d' ' -f4)"

	local hash
	hash="$(printf 'changeme\n' | mkpasswd -m sha-512 -s)"

	printf 'alice-password: %s\n' "$hash" >/root/secrets.yaml.tmp
	sops encrypt --input-type yaml --output-type yaml -a "$pubkey" /root/secrets.yaml.tmp >/root/etc/nixos/secrets.yaml
	rm /root/secrets.yaml.tmp
}

do_install() {
	generate_sops_age_key_and_secrets

	mkdir -p /mnt/var/lib/nixwall
	cp /root/sops-age-key.txt /mnt/var/lib/nixwall/sops-age-key.txt
	chmod 600 /mnt/var/lib/nixwall/sops-age-key.txt
	chown 0:0 /mnt/var/lib/nixwall/sops-age-key.txt
	rm /root/sops-age-key.txt

	header "Building system"
	local system
	system="$(nix build --no-link --print-out-paths --no-write-lock-file \
		"/root/etc/nixos#nixosConfigurations.${HOST}.config.system.build.toplevel")"

	header "Running nixos-install"
	nixos-install --no-root-passwd --system "$system"

	mkdir -p /mnt/etc/nixos
	cp -a /root/etc/nixos/* /mnt/etc/nixos/

	cd /mnt/etc/nixos

	git init -b main

	git config user.name "NixWall Installer"
	git config user.email "installer@nixwall.local"

	git add .
	git commit -m "feat(install): initial system configuration"

	echo
	echo "Install complete. You can now reboot."
}
