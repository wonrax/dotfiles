#!/usr/bin/env nu

# Build SD image command
def "nix build-sd" [host: string = "pumpkin"] {
    nix build path:.#images.($host)

    if ($env.LAST_EXIT_CODE == 0) {
        ls result/sd-image/ | where name =~ ".img$" | get name | first
    } else {
        exit 1
    }
}

# Flash SD image to card
def "nix flash-sd" [device: string = "/dev/sdb"] {
    let image_files = (ls result/sd-image/ | where name =~ ".img$" | get name)

    if ($image_files | length) == 0 {
        print "No SD image found. Run 'nix build-sd' first."
        exit 1
    }

    let image_path = ($image_files | first)

    print $"⚠️  About to flash ($image_path) to ($device)"
    print "This will DESTROY all data on the target device!"
    input "Type 'yes' to continue: " | if $in != "yes" {
        print "Aborted."
        exit 0
    }

    print $"Flashing ($image_path) to ($device)..."
    sudo dd $"if=($image_path)" $"of=($device)" status=progress bs=4M oflag=direct

    if ($env.LAST_EXIT_CODE == 0) {
        print "💡 Remember to run 'nixos-generate-config' on first boot if you haven't done so already."
    } else {
        exit 1
    }
}

# Deploy nix configuration to remote host
def "nix deploy" [host: string = "pumpkin"] {
    nix run .#deploy.($host)
    # TODO: for building directly on target host, we need to use nixos-rebuild
    # since nh currently has a bug where it doesn't build on --build-host
    # properly
    # https://github.com/nix-community/nh/issues/308
    # nixos-rebuild switch --flake path:.#pumpkin --target-host pumpkin --build-host pumpkin --fast --sudo
}

