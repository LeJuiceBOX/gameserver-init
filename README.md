# gameserver-init

One script to take a fresh Ubuntu/Debian VM and turn it into a game server box, so I stop doing the same 40 commands by hand every time.

It asks before every step, shows a progress bar, and you can skip anything you don't want.

### What it does

0. Updates the system and installs SteamCMD, playit.gg, ufw and git
1. Firewall: block incoming, allow outgoing, SSH only from your LAN
2. Hardening: no root SSH, auto security updates, service sandbox and a few more (each one optional)
3. Creates a server user to own and run the server (optional)
4. Links playit.gg to your account (optional)
5. Installs the game server via **SteamCMD**, **GitHub**, or lets you do it yourself
6. SteamCMD first run: update, Steam login if the game needs it, run the server once to make its configs
7. Installs [alias-motd](https://github.com/LeJuiceBOX/alias-motd)
8. Adds `edit-alias` / `update-alias`
9. Creates `gameserver.service` so it runs in the background and on boot
10. Adds aliases for managing the service

### Run it

On the VM, as your normal sudo user:

```bash
curl -fsSLO https://raw.githubusercontent.com/LeJuiceBOX/gameserver-init/main/gameserver-setup.sh
bash gameserver-setup.sh
```

At each stage answer **Y** to run it, **s** to skip, **q** to quit. Your answers are saved in `/etc/gameserver-setup/config`, so you can re-run it any time to redo or finish a stage.

Made for Ubuntu 20.04+ and Debian 11+. SteamCMD needs an x86-64 VM.

### Aliases you get

| Alias | Does |
|---|---|
| `gameserver-start` / `-stop` / `-restart` | What it says |
| `gameserver-status` | Is it running? |
| `gameserver-logs` | Follow the server console |
| `gameserver-steamupdate` | Stop, update via SteamCMD, start again (Steam installs only) |
| `edit-service` / `update-service` | Edit the systemd service, then apply it (only for the user who ran the script) |
| `edit-alias` / `update-alias` | Edit / reload `~/.bash_aliases` |

Log out and back in (or `source ~/.bash_aliases`) after setup to load them.

### Heads up

- **Don't lock yourself out.** The firewall stage warns you if your current SSH connection is outside the LAN. If you turn on key-only login, test logging in from a new terminal before closing the old one.
- **Server acting weird after the sandbox?** Delete `/etc/systemd/system/gameserver.service.d/10-sandbox.conf`, then `update-service && gameserver-restart`.
- **Keep server files in the server user's home or `/srv`.** With private home folders on, the server user can't reach your home.

### License

MIT
