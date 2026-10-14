# Mac Hermes worker

Pumpkin is the always-on Hermes gateway and coordinator. Chauffeur runs its
own Hermes 0.21.7 backend, agent loop, model calls, sessions, and memory.
Pumpkin delegates Mac tasks using the authenticated A2A peer `chauffeur`.
Delegated conversations retain their A2A context ID; memory and session
databases remain separate on the two machines.

Both agents import `home/hermes/common.nix` for the model, web backend,
MCP servers, enabled skills, toolsets, memory settings, daily session reset,
and idle compaction. They also share `home/hermes/SOUL.md`; each host appends
its own role. The Mac adds Cua computer use and the desktop launcher.

The shared skill policy disables unselected skills in the pinned upstream
bundled and optional catalogs, plus retired bundled skills retained in the
configuration. It matches directory names, declared names, and path aliases
used when Hermes finds duplicate skill names.
Agent-created and separately installed skills stay available; Hermes's
required `hermes-agent` manual also stays enabled. Disabled skills remain on
disk.

The Mac's A2A server binds its Tailscale address, 100.65.46.20:9900.
Pumpkin connects directly to `http://chauffeur:9900` over the tailnet.
A per-peer A2A token authenticates Pumpkin; the worker checks the trusted
identity `pumpkin` before accepting tasks.

Pumpkin is also explicitly configured as an owner peer with
`A2A_OWNER_PEERS=pumpkin`. The shared runtime patch treats its authenticated
delegations as operator-authorized requests, preserves task text, and permits
unredacted replies. Pumpkin's `chauffeur` peer has `owner_trusted: true` so
outgoing tasks are preserved too. Owner access requires a named per-peer
token and admission allowlist; the default policy for other peers remains
upstream's external-agent filtering and redaction.
Ordinary tool approvals and tool-level secret scrubbing remain the same as
direct Mac sessions; the owner policy removes the extra A2A restrictions.

## Install and configure

`services.hermes-mac.enable` is enabled for chauffeur in flake.nix.
`hermes-mac-install` installs the signed Cua Driver app and merges the
worker settings into `~/.hermes/config.yaml`. Existing credentials,
sessions, memory, and other settings are preserved.

The Affine, TickTick, Money Lover, Firecrawl, and OpenRouter credentials
belong in the Mac's private `~/.hermes/.env`. Each host keeps its own Codex
OAuth credential and Telegram bot token.

The A2A credential lives in the Mac's private `~/.hermes/.env` and Pumpkin's
`/var/lib/hermes/mac-node.env`; neither belongs in version control.
The Mac allows only the authenticated peer identity `pumpkin`.

The model is `gpt-6.1-sol` through `openai-codex`, matching Pumpkin.
Give the Mac its own OAuth session:

```sh
hermes auth add openai-codex --no-browser
```

Use the device-code URL from a phone or browser. A separate login avoids
sharing a rotating refresh token with Pumpkin or another client.

Grant desktop permissions when at the Mac:

```sh
~/Applications/CuaDriver.app/Contents/MacOS/cua-driver permissions grant
```

Enable CuaDriver in macOS Accessibility and Screen Recording settings.
Hermes and Cua retain their normal approval gates. A2A does not provide
Telegram approval buttons; unattended desktop writes require an explicit
operator-approved policy or an interactive session that can handle approvals.

## Use and inspect

Run `hermes` for a terminal conversation or `hermes desktop` for the GUI.
The desktop launcher uses the same wrapped Hermes backend and `~/.hermes`
as the Mac gateway.

Pumpkin's Telegram bot handles topic 1 in group `-1003508166716`. The Mac's
separate bot handles topic 3 in that group, with user `653083546` allowed.
Telegram conversations on the Mac use its own agent loop directly.
There is no Telegram proxy over A2A. Pumpkin can still delegate Mac tasks
to `chauffeur` from its own conversations.

Create the Mac bot with BotFather, add it to that group, and disable its
group privacy or make it an admin so it receives ordinary topic messages.
Configure its token on the Mac with `hermes gateway setup`, then restart
the existing LaunchAgent:

```sh
launchctl kickstart -k gui/$(id -u)/org.nixos.hermes-mac-gateway
```

The Mac gateway is already supervised; installing another gateway service
would create a second polling process. Use different bot tokens on the two
hosts because Telegram polling does not partition one bot by forum topic.

The Mac must be awake, connected to Tailscale, and logged into its desktop
for computer use. The worker runs as a user LaunchAgent:

```sh
launchctl print gui/$(id -u)/org.nixos.hermes-mac-gateway
hermes computer-use permissions status --json
hermes computer-use doctor --json
launchctl bootout gui/$(id -u)/org.nixos.hermes-mac-gateway
```

Logs are `~/.local/state/hermes-mac/gateway.log`.
Launchd restarts the worker after failures. Remove the A2A peer entry from
Pumpkin and rotate the worker's token to revoke this connection.
