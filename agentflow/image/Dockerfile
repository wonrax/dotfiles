# Agent task container: nix-native environment with jj, gh, and claude code.
# Built identically on macOS (orbstack) and NixOS hosts.
FROM nixos/nix:latest

RUN mkdir -p /etc/nix && \
    echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf && \
    echo "filter-syscalls = false" >> /etc/nix/nix.conf

# nixpkgs#git is omitted: the base image's profile already carries git-minimal,
# and adding full git causes a nix profile file conflict.
#
# sed, awk, jq and diff are here because the base profile has most of coreutils
# but not those, and an agent that reaches for one gets `nix shell nixpkgs#…`
# instead — which on a cold store blocks on fetching the nixpkgs tarball, in the
# middle of a turn, for a one-line text substitution. Observed on the PR
# babysitter: `waiting for another Nix process to finish fetching input
# 'https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz'`.
RUN nix profile add \
    nixpkgs#jujutsu \
    nixpkgs#gh \
    nixpkgs#nodejs_22 \
    nixpkgs#ripgrep \
    nixpkgs#python3 \
    nixpkgs#docker \
    nixpkgs#procps \
    nixpkgs#gnused \
    nixpkgs#gawk \
    nixpkgs#jq \
    nixpkgs#diffutils \
    && nix-collect-garbage -d

# The coding agents, from nixpkgs rather than npm: the npm packages ship native
# binaries that expect /lib64/ld-linux, which doesn't exist in a nix-based image.
#
# The version is whatever the build host's registry resolves to, and this layer
# caches — so once built it never moves again, however old it gets. That is not
# cosmetic: claude-code 2.1.218 sat here for months against a much newer host
# claude, and its skill listing dropped the descriptions off a subset of skills,
# which is why agents never once loaded the writing skill they were being
# offered. Bump the date to rebuild this layer and take newer agents.
ARG AGENT_CLI_REFRESH=2026-08-11
RUN echo "agent CLIs refreshed ${AGENT_CLI_REFRESH}" && \
    NIXPKGS_ALLOW_UNFREE=1 nix profile add --impure nixpkgs#claude-code nixpkgs#codex && \
    nix-collect-garbage -d

# Keep npm globals out of the nix store: the store path is writable at build
# time so npm would silently install there, but profile bin symlinks won't see it.
ENV NPM_CONFIG_PREFIX=/opt/npm
ENV PATH=/opt/npm/bin:$PATH

# Fallback jj identity only — the engine overwrites this at task setup with
# the host operator's `jj config get user.name/user.email`.
RUN mkdir -p /root/.config/jj && printf '[user]\nname = "agentflow"\nemail = "agent@agentflow.local"\n' > /root/.config/jj/config.toml

# No AI attribution on commits made inside task containers.
RUN mkdir -p /root/.claude && printf '{"includeCoAuthoredBy": false}\n' > /root/.claude/settings.json

# The base image symlinks /etc/passwd and /etc/group into /nix/store; runc's
# secure path join refuses those during `docker exec` user lookup
# ("path escapes from parent"). Materialize them as regular files.
RUN for f in passwd group; do \
      if [ -L /etc/$f ]; then cp -L /etc/$f /tmp/$f && rm /etc/$f && mv /tmp/$f /etc/$f; fi; \
    done

# The base image puts only `sh` in /bin, so `#!/bin/bash` shebangs and
# `SHELL := /bin/bash` makefiles fail inside task containers even though bash is
# on PATH. /bin/sh already points at a full bash; give /bin/bash the same target.
RUN ln -s "$(readlink /bin/sh)" /bin/bash

# Headless chromium in this image renders every string as NOTHING — not tofu
# boxes, invisible — so a screenshot of a working page comes back blank and
# reads as a data-loading bug rather than a missing font. Installing the fonts
# is not enough on its own: `fc-list` finds them from the profile but chromium
# does not consult it, and only stops erroring once a config names the
# directory. Verified with chromium 150 — 194 harfbuzz errors and a 2.3K blank
# PNG before, 0 errors and a correct 17.9K render after.
RUN nix profile add nixpkgs#fontconfig nixpkgs#dejavu_fonts && nix-collect-garbage -d
RUN mkdir -p /etc/fonts /var/cache/fontconfig && printf '%s\n' \
      '<?xml version="1.0"?>' \
      '<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">' \
      '<fontconfig>' \
      '  <dir>/root/.nix-profile/share/fonts</dir>' \
      '  <cachedir>/var/cache/fontconfig</cachedir>' \
      '</fontconfig>' > /etc/fonts/fonts.conf \
    && fc-cache -f > /dev/null

# A floor under the shared /nix volume, which grows without bound on its own:
# every gate run realises a fresh source snapshot of the workspace tree and
# nothing ever roots those. Once free space drops under min-free, nix collects
# dead paths mid-build until max-free is free again, never touching live paths
# or in-flight builds. Only a partial backstop — it fires during builds, so a
# run that hits an entirely cached devshell still adds garbage and collects
# none. `af volumes --gc` is the deliberate version.
RUN printf 'min-free = 21474836480\nmax-free = 64424509440\n' >> /etc/nix/nix.conf

WORKDIR /ws
CMD ["sleep", "infinity"]
