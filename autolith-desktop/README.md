# Autolith Desktop

Autolith Desktop attaches to an existing Autolith process through Localgroup. It reads the recent conversation and model choices from the Lisp adapter. Prompts, model changes, and approvals go through the same terminal input that the SSH client uses.

## Launch

From the dotfiles root, open the packaged app.

```sh
nix develop -c nix run .#autolith-desktop
```

The renderer uses shadcn/ui components with Tailwind and a small workspace stylesheet. For frontend development, install the locked dependencies and build from the checkout.

```sh
nix develop -c npm --prefix autolith-desktop ci
nix develop -c npm --prefix autolith-desktop start
```

After activating the Home Manager configuration, the adapter loads automatically on the pinned version. Start Autolith normally from your workspace, or start it in the background.

```sh
autolith --detached
```

To try the adapter before activation, start with `autolith --detached`, attach with `autolith lg attach SESSION-ID`, and load the checkout's adapter in the Autolith REPL.

```lisp
(load "/Users/wonrax/.dotfiles/.config/autolith/desktop.lisp")
```

Use **New session** to pick a workspace and start Autolith in the background, or select an existing session. Selecting a session starts a read-only attachment. Sending input, changing settings, or answering a prompt automatically takes control. The composer’s model menu lets you choose a model and its supported reasoning effort. The sidebar shows recent past sessions below live sessions. **Conversation history** can load older pages even when no session is running. Open a live entry to watch it, or resume a stopped entry in a new detached process. The chat uses the shadcn AI Elements Message, Reasoning, Tool, and Confirmation patterns. Authorization cards show the exact request and the choices Autolith offers. Native selection prompts, including the conversation picker, are rendered directly in the GUI.

**Settings** lists visible settings with their values, scopes, and sources. Editable controls use Autolith's validation and persistence. **Generations** lists retained images and can stage checkpoint or rollback commands. **Cmd/Ctrl+K** opens workspace search for quick actions, recent chats, and native commands, including commands registered by extensions. Start a composer entry with `(` to evaluate Lisp. Recent native command results and session notices are available in **Output** beside the composer.

The **SSH** menu copies watch, takeover, and detach commands. Raw terminal diagnostics are available for terminal-specific workflows and troubleshooting.

## SSH handoff

From an SSH shell on the host, as the same user and with the same Autolith state directory, watch the live terminal while the desktop keeps control.

```sh
autolith lg attach SESSION-ID --read-only
```

Ctrl-C closes a read-only attachment locally. A plain `attach` requests control and is rejected if the desktop already holds it. To move control to the SSH terminal, use:

```sh
autolith lg attach SESSION-ID --take-over
```

The desktop returns to watching when the terminal takes over. The next desktop action that changes the session takes control back. To release terminal control explicitly, run `autolith lg detach SESSION-ID` from a second shell. Sessions launched from the desktop stay alive across connection drops. When you quit the desktop normally, it requests graceful shutdown for sessions it started that have no other controlling terminal. Sessions started elsewhere and sessions currently controlled from SSH stay running. For terminal-launched sessions, use explicit detach or set `AUTOLITH_KEEP_ALIVE=1` at launch if you want that same lifetime policy. In a controlling terminal, Ctrl-C goes to Autolith itself and can end the shared session. Use `autolith lg kill SESSION-ID` when you intend to stop the session.

The command-line probe can inspect the same session. It takes the full canonical ID from its list output.

```sh
nix develop -c npm --prefix autolith-desktop run build
nix develop -c npm --prefix autolith-desktop run probe -- list
nix develop -c npm --prefix autolith-desktop run probe -- snapshot SESSION-ID
nix develop -c npm --prefix autolith-desktop run probe -- models SESSION-ID
nix develop -c npm --prefix autolith-desktop run probe -- commands SESSION-ID
```
