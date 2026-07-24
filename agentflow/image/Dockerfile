# Agent task container: nix-native environment with jj, gh, and claude code.
# Built identically on macOS (orbstack) and NixOS hosts.
FROM nixos/nix:latest

RUN mkdir -p /etc/nix && \
    echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf && \
    echo "filter-syscalls = false" >> /etc/nix/nix.conf

# nixpkgs#git is omitted: the base image's profile already carries git-minimal,
# and adding full git causes a nix profile file conflict.
RUN nix profile add \
    nixpkgs#jujutsu \
    nixpkgs#gh \
    nixpkgs#nodejs_22 \
    nixpkgs#ripgrep \
    nixpkgs#python3 \
    nixpkgs#docker \
    && nix-collect-garbage -d

# claude-code from nixpkgs, not npm: the npm package ships a native binary
# that expects /lib64/ld-linux, which doesn't exist in a nix-based image.
RUN NIXPKGS_ALLOW_UNFREE=1 nix profile add --impure nixpkgs#claude-code && nix-collect-garbage -d

# Keep npm globals out of the nix store: the store path is writable at build
# time so npm would silently install there, but profile bin symlinks won't see it.
ENV NPM_CONFIG_PREFIX=/opt/npm
ENV PATH=/opt/npm/bin:$PATH

# jj inside the container commits as the agent; identity is overridable per task
RUN mkdir -p /root/.config/jj && printf '[user]\nname = "agentflow"\nemail = "agent@agentflow.local"\n' > /root/.config/jj/config.toml

# The base image symlinks /etc/passwd and /etc/group into /nix/store; runc's
# secure path join refuses those during `docker exec` user lookup
# ("path escapes from parent"). Materialize them as regular files.
RUN for f in passwd group; do \
      if [ -L /etc/$f ]; then cp -L /etc/$f /tmp/$f && rm /etc/$f && mv /tmp/$f /etc/$f; fi; \
    done

WORKDIR /ws
CMD ["sleep", "infinity"]
