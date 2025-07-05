# TODO: command to build sd image
# TODO: command to deploy nix on remote host
# build SD image: nix build path:.#images.pumpkin
# Flash image to sd card: sudo dd if=result/sd-image/nixos-image-sd-card-25.05.20250702.34627c9-aarch64-linux.img of=/dev/sdb status=progress bs=4M oflag=direct
# Print a message to remind to nixos-generate-config if haven't done so
# remote switch generation after successful boot: nh os switch --target-host pumpkin path:.#nixosConfigurations.pumpkin
