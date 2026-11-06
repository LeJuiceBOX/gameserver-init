#!/usr/bin/env bash
# =============================================================================
#  gameserver-setup.sh — interactive setup for game server VMs
#  Ubuntu & Debian (auto-detected)
#
#  Usage:  bash gameserver-setup.sh          (re-runs itself with sudo)
#
#  Asks before every stage and shows how many steps are left. Your answers are
#  saved in /etc/gameserver-setup/config, so you can re-run the script later to
#  redo or finish any stage.
# =============================================================================
set -uo pipefail

TOTAL_STEPS=11
CONF_DIR=/etc/gameserver-setup
CONF_FILE=$CONF_DIR/config
SERVICE_NAME=gameserver.service
SERVICE_FILE=/etc/systemd/system/$SERVICE_NAME
SANDBOX_DROPIN=/etc/systemd/system/$SERVICE_NAME.d/10-sandbox.conf
SUDOERS_FILE=/etc/sudoers.d/gameserver
UPDATE_SCRIPT=/usr/local/bin/gameserver-steamupdate
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-gameserver-hardening.conf   # "10-" so it wins over cloud-init's 50-
SYSCTL_FILE=/etc/sysctl.d/90-gameserver-hardening.conf
UNATTENDED_FILE=/etc/apt/apt.conf.d/52gameserver-unattended
ALIAS_MOTD_REPO=https://github.com/LeJuiceBOX/alias-motd.git

TITLES=("Initial installs" "UFW firewall" "Hardening" "Server user" "playit.gg setup"
        "Game server install" "SteamCMD first-run" "alias-motd"
        "Alias helpers" "systemd service" "Service aliases")
RESULT=()
RESULT_NOTE=()

# Answers remembered between runs
CONF_VARS=(GS_USER GS_DIR INSTALL_METHOD STEAM_APPID STEAM_BETA STEAM_LOGIN
           STEAM_INSTALL_OK GH_REPO START_CMD LAN_CIDRS SSH_PORT
           H_ROOT_SSH H_DENY_GS_SSH H_KEY_ONLY H_AUTOUPDATES H_AUTOREBOOT
           H_SYSCTL H_PRIVATE_HOMES H_SANDBOX)
for _v in "${CONF_VARS[@]}"; do printf -v "$_v" '%s' ""; done
unset _v

APT_GET=(apt-get -y -o DPkg::Lock::Timeout=300
         -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ── Look & feel ──────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_B=$'\e[1m' C_D=$'\e[2m' C_R=$'\e[0m' C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_CYN=$'\e[36m'
else
  C_B="" C_D="" C_R="" C_RED="" C_GRN="" C_YEL="" C_CYN=""
fi
if [[ $(locale charmap 2>/dev/null) == UTF-8 ]]; then
  G_FULL="█" G_EMPTY="░" G_LINE="─" G_OK="✔" G_BAD="✖" G_SKIP="–" G_ARROW="›" G_DOT="·"
else
  G_FULL="#" G_EMPTY="." G_LINE="-" G_OK="+" G_BAD="x" G_SKIP="-" G_ARROW=">" G_DOT="|"
fi

info() { printf '  %s%s%s %s\n' "$C_CYN" "$G_ARROW" "$C_R" "$*"; }
ok()   { printf '  %s%s%s %s\n' "$C_GRN" "$G_OK" "$C_R" "$*"; }
warn() { printf '  %s! %s%s\n' "$C_YEL" "$*" "$C_R"; }
err()  { printf '  %s%s %s%s\n' "$C_RED" "$G_BAD" "$*" "$C_R" >&2; }
note() { printf '  %s%s%s\n' "$C_D" "$*" "$C_R"; }
rule() { local l; printf -v l '%*s' 66 ''; printf '%s%s%s\n' "$C_D" "${l// /$G_LINE}" "$C_R"; }

progress_bar() { # progress_bar STEPS_DONE
  local n=$1 width=32 filled bar_done bar_todo
  filled=$(( n * width / TOTAL_STEPS ))
  printf -v bar_done '%*s' "$filled" '';             bar_done=${bar_done// /$G_FULL}
  printf -v bar_todo '%*s' $(( width - filled )) ''; bar_todo=${bar_todo// /$G_EMPTY}
  printf '  %s%s%s%s%s %3d%%' "$C_GRN" "$bar_done" "$C_D" "$bar_todo" "$C_R" $(( n * 100 / TOTAL_STEPS ))
}

stage_header() { # stage_header INDEX TITLE
  local i=$1
  echo; rule
  progress_bar "$i"
  printf '   Step %d of %d %s %s%d left%s\n' $(( i + 1 )) "$TOTAL_STEPS" "$G_DOT" "$C_B" $(( TOTAL_STEPS - i )) "$C_R"
  printf '  %s%s%s\n' "$C_B" "$2" "$C_R"
  rule
}

# ── Input ────────────────────────────────────────────────────────────────────
prompt() { # prompt VAR "Question" [default]
  local __var=$1 __q=$2 __def=${3-} __ans
  if [[ -n $__def ]]; then
    read -erp "  $__q [$__def]: " __ans || quit_now 1
  else
    read -erp "  $__q: " __ans || quit_now 1
  fi
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

prompt_required() { # same as prompt, but won't accept blank
  local __rv=$1
  while true; do
    prompt "$@"
    [[ -n ${!__rv} ]] && return 0
    warn "This one can't be blank."
  done
}

ask_yn() { # ask_yn "Question" [Y|N]
  local q=$1 def=${2:-Y} hint ans
  [[ $def == Y ]] && hint="Y/n" || hint="y/N"
  while true; do
    read -rp "  $q [$hint] " ans || quit_now 1
    case ${ans:-$def} in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo])     return 1 ;;
    esac
    echo "  Please answer y or n."
  done
}

confirm_stage() { # 0 = run, 1 = skip (q quits)
  local ans
  while true; do
    read -rp "  Run this stage? [Y]es / [s]kip / [q]uit: " ans || quit_now 1
    case ${ans,,} in
      ""|y|yes)     return 0 ;;
      s|skip|n|no)  return 1 ;;
      q|quit)       quit_now 0 ;;
    esac
  done
}

# ── Running things ───────────────────────────────────────────────────────────
run()        { printf '  %s$ %s%s\n' "$C_D" "$*" "$C_R"; "$@"; }
user_home()  { getent passwd "$1" | cut -d: -f6; }
user_group() { id -gn "$1"; }
as_user()    { # as_user USER CMD... — run a command as USER with their HOME
  local u=$1; shift
  runuser -u "$u" -- env HOME="$(user_home "$u")" USER="$u" LOGNAME="$u" "$@"
}
run_as()     { local u=$1; shift; printf '  %s[%s] $ %s%s\n' "$C_D" "$u" "$*" "$C_R"; as_user "$u" "$@"; }

# Let Ctrl+C stop a long-running child (game server, playit setup) without
# killing this script.
interruptible() { local rc; trap ':' INT; "$@"; rc=$?; trap on_int INT; return "$rc"; }
on_int() { echo; warn "Interrupted."; quit_now 130; }

find_steamcmd() {
  local p
  for p in /usr/games/steamcmd /usr/bin/steamcmd; do
    [[ -x $p ]] && { echo "$p"; return 0; }
  done
  return 1
}

# ── Saved answers ────────────────────────────────────────────────────────────
load_config() {
  # shellcheck source=/dev/null
  [[ -r $CONF_FILE ]] && source "$CONF_FILE"
  return 0
}

save_config() {
  local v
  mkdir -p "$CONF_DIR" && chmod 700 "$CONF_DIR"
  {
    echo "# gameserver-setup answers — safe to edit or delete"
    for v in "${CONF_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v-}"; done
  } > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
}

# ── Users & shell files ──────────────────────────────────────────────────────
alias_users() { # fills ALIAS_USERS: you, plus the server user if it's someone else
  ALIAS_USERS=("$ADMIN_USER")
  [[ $GS_USER != "$ADMIN_USER" ]] && ALIAS_USERS+=("$GS_USER")
  return 0
}
alias_users_text() {
  alias_users
  if (( ${#ALIAS_USERS[@]} == 2 )); then echo "${ALIAS_USERS[0]} and ${ALIAS_USERS[1]}"; else echo "${ALIAS_USERS[0]}"; fi
}

ensure_user_file() { # ensure_user_file USER PATH — create it owned by USER if missing
  [[ -e $2 ]] || install -m 644 -o "$1" -g "$(user_group "$1")" /dev/null "$2"
}

ensure_aliases_sourced() { # make sure ~/.bashrc loads ~/.bash_aliases
  local rc; rc="$(user_home "$1")/.bashrc"
  ensure_user_file "$1" "$rc"
  grep -qE '^[^#]*(\.|source)[[:space:]]+[^#]*\.bash_aliases' "$rc" && return 0
  cat >> "$rc" <<'EOF'

# Load aliases (added by gameserver-setup)
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi
EOF
}

remove_alias_block() { # remove_alias_block USER BLOCK — also drops the blank line above it
  local f s e
  f="$(user_home "$1")/.bash_aliases"
  [[ -f $f ]] || return 0
  s="# >>> gameserver-setup: $2 >>>" e="# <<< gameserver-setup: $2 <<<"
  grep -qxF "$s" "$f" || return 0
  awk -v s="$s" -v e="$e" '
    skip      { if ($0 == e) skip = 0; next }
    $0 == s   { pend = 0; skip = 1; next }
              { if (pend) print ""; pend = 0 }
    $0 == ""  { pend = 1; next }
              { print }
    END       { if (pend) print "" }' "$f" > "$f.gs-tmp" && cat "$f.gs-tmp" > "$f"
  rm -f "$f.gs-tmp"
}

# write_alias_block USER BLOCK  NAME DESC CMD  [NAME DESC CMD ...]
# Writes a managed block to ~/.bash_aliases; a re-run updates it in place.
# "## desc" lines are what alias-motd shows in its Description column.
write_alias_block() {
  local u=$1 block=$2 f s e name desc cmd tmp skipped=()
  shift 2
  f="$(user_home "$u")/.bash_aliases"
  s="# >>> gameserver-setup: $block >>>" e="# <<< gameserver-setup: $block <<<"
  ensure_user_file "$u" "$f"
  ensure_aliases_sourced "$u"

  tmp=$(mktemp)
  echo "$s" > "$tmp"
  while (( $# >= 3 )); do
    name=$1 desc=$2 cmd=$3; shift 3
    # Keep the user's own definition if they already have one outside our block
    if sed "\|^$s\$|,\|^$e\$|d" "$f" | grep -qE "^[[:space:]]*alias[[:space:]]+${name}="; then
      skipped+=("$name"); continue
    fi
    printf '## %s\nalias %s=%s\n' "$desc" "$name" "'${cmd//\'/\'\\\'\'}'" >> "$tmp"
  done
  echo "$e" >> "$tmp"

  if grep -qxF "$s" "$f"; then   # replace the existing block where it is
    awk -v s="$s" -v e="$e" -v blk="$tmp" '
      $0 == s { while ((getline l < blk) > 0) print l; skip = 1; next }
      skip    { if ($0 == e) skip = 0; next }
              { print }' "$f" > "$f.gs-tmp" && cat "$f.gs-tmp" > "$f"
    rm -f "$f.gs-tmp"
  else                           # append, separated by one blank line
    [[ -s $f && -n $(tail -n1 "$f") ]] && echo >> "$f"
    cat "$tmp" >> "$f"
  fi
  rm -f "$tmp"

  ok "$u: aliases written to ~/.bash_aliases"
  (( ${#skipped[@]} )) && warn "$u: kept your own existing definition of: ${skipped[*]}"
  return 0
}

# ── Network helpers ──────────────────────────────────────────────────────────
ip2int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

valid_ipv4_cidr() {
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]{1,2}))?$ ]] || return 1
  local o
  for o in "${BASH_REMATCH[@]:1:4}"; do (( 10#$o <= 255 )) || return 1; done
  [[ -z ${BASH_REMATCH[6]} ]] || (( 10#${BASH_REMATCH[6]} <= 32 ))
}

ip_in_cidr() { # ip_in_cidr IP CIDR
  local net=${2%/*} bits=32 mask
  [[ $2 == */* ]] && bits=${2#*/}
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( ($(ip2int "$1") & mask) == ($(ip2int "$net") & mask) ))
}

detect_lan_cidr() { # the subnet of the interface that has the default route
  local dev
  dev=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  [[ -n $dev ]] || return 0
  ip -4 route show dev "$dev" scope link proto kernel 2>/dev/null | awk '$1 ~ /\// {print $1; exit}'
}

# ── Folder helpers ───────────────────────────────────────────────────────────
prepare_dir() { # create $GS_DIR owned by $GS_USER and make sure that user can reach it
  local owner
  if [[ ! -d $GS_DIR ]]; then
    mkdir -p "$GS_DIR" || return 1
    chown "$GS_USER:$(user_group "$GS_USER")" "$GS_DIR"
  fi
  owner=$(stat -c %U "$GS_DIR")
  if [[ $owner != "$GS_USER" ]]; then
    if ask_yn "$GS_DIR belongs to $owner. Give it (and everything in it) to $GS_USER?" Y; then
      chown -R "$GS_USER:$(user_group "$GS_USER")" "$GS_DIR"
    fi
  fi
  if ! as_user "$GS_USER" test -w "$GS_DIR"; then
    err "$GS_USER can't write to $GS_DIR (a parent folder blocks it). Pick a folder under $(user_home "$GS_USER") or /srv."
    return 1
  fi
}

suggest_executables() {
  [[ -d $GS_DIR ]] || return 0
  local found
  found=$(find "$GS_DIR" -maxdepth 2 -type f \( -perm -u+x -o -name '*.sh' -o -name '*.jar' \) -printf '%P\n' 2>/dev/null \
          | grep -vE '\.(so(\.[0-9.]+)?|dll|txt|dylib)$' | sort | head -15)
  if [[ -n $found ]]; then
    info "Files in $GS_DIR that look launchable:"
    sed 's/^/      /' <<< "$found"
  fi
}

# ── Install helpers ──────────────────────────────────────────────────────────
enable_debian_nonfree() {
  local f changed=0
  f=/etc/apt/sources.list.d/debian.sources            # deb822 format (Debian 12+)
  if [[ -f $f ]]; then
    cp -n "$f" "$f.bak-gameserver-setup"
    sed -i -E '/^Components:/{/[[:space:]]non-free([[:space:]]|$)/!s/[[:space:]]*$/ non-free/}' "$f" && changed=1
  fi
  f=/etc/apt/sources.list                             # classic format
  if [[ -f $f ]] && grep -qE '^[[:space:]]*deb(-src)?[[:space:]].*debian' "$f"; then
    cp -n "$f" "$f.bak-gameserver-setup"
    sed -i -E '/^[[:space:]]*deb(-src)?[[:space:]].*debian/{/[[:space:]]non-free([[:space:]]|$)/!s/[[:space:]]*$/ non-free/}' "$f" && changed=1
  fi
  (( changed )) || { err "Couldn't find Debian's apt sources to enable 'non-free'."; return 1; }
  ok "Enabled Debian's non-free component (needed for SteamCMD)"
}

install_steamcmd() {
  local owner arch
  if find_steamcmd >/dev/null; then ok "SteamCMD already installed"; return 0; fi
  arch=$(dpkg --print-architecture)
  if [[ $arch != amd64 ]]; then
    warn "SteamCMD only runs on x86-64 and this VM is $arch — skipping SteamCMD."
    return 0
  fi
  info "Installing SteamCMD (this accepts the Steam Subscriber Agreement for you)"
  case $OS_FAMILY in
    ubuntu) run "${APT_GET[@]}" install software-properties-common || return 1
            run add-apt-repository -y multiverse || return 1 ;;
    debian) enable_debian_nonfree || return 1 ;;
  esac
  run dpkg --add-architecture i386 || return 1
  run apt-get -o DPkg::Lock::Timeout=300 update || return 1
  for owner in steam steamcmd; do
    echo "$owner steam/question select I AGREE" | debconf-set-selections
    echo "$owner steam/license note " | debconf-set-selections
  done
  run "${APT_GET[@]}" install steamcmd || return 1
  ok "SteamCMD installed ($(find_steamcmd))"
}

install_playit() {
  if command -v playit >/dev/null 2>&1; then ok "playit already installed"; return 0; fi
  info "Adding the official playit.gg apt repository"
  run bash -c 'curl -fsSL https://packages.playit.gg/keys/playit.gpg | gpg --dearmor --yes -o /usr/share/keyrings/playit.gpg' || return 1
  chmod 0644 /usr/share/keyrings/playit.gpg
  run curl -fsSL -o /etc/apt/sources.list.d/playit.list https://packages.playit.gg/repo-files/playit-debian.list || return 1
  run apt-get -o DPkg::Lock::Timeout=300 update || return 1
  run "${APT_GET[@]}" install playit || return 1
  ok "playit installed"
}

steam_app_update() { # install/update $STEAM_APPID into $GS_DIR as $GS_USER
  local steamcmd log attempt
  steamcmd=$(find_steamcmd) || { err "SteamCMD isn't installed — run Stage 0 first."; return 1; }
  local args=(+force_install_dir "$GS_DIR" +login "$STEAM_LOGIN" +app_update "$STEAM_APPID")
  [[ -n $STEAM_BETA ]] && args+=(-beta "$STEAM_BETA")
  args+=(validate +quit)

  if [[ $STEAM_LOGIN != anonymous ]]; then
    # Real account: keep the terminal untouched so password / Steam Guard prompts show
    if run_as "$GS_USER" "$steamcmd" "${args[@]}"; then STEAM_INSTALL_OK=yes; return 0; fi
    return 1
  fi

  log=$(mktemp)
  for attempt in 1 2 3; do
    run_as "$GS_USER" "$steamcmd" "${args[@]}" 2>&1 | tee "$log"
    if grep -q "Success! App '$STEAM_APPID'" "$log"; then
      rm -f "$log"; STEAM_INSTALL_OK=yes; return 0
    fi
    (( attempt < 3 )) && warn "SteamCMD didn't finish (common on its first run) — retrying ($attempt/3)…"
  done
  rm -f "$log"
  return 1
}

first_run() { # start the server once (as the service would) so it writes its configs
  local secs launcher
  suggest_executables
  note "Examples:  ./start_server.sh   ·   ./valheim_server.x86_64 -name MyServer -port 2456"
  prompt_required START_CMD "Start command (runs inside $GS_DIR)" "$START_CMD"
  save_config
  prompt secs "Stop it automatically after how many seconds?" "90"
  [[ $secs =~ ^[0-9]+$ ]] || secs=90

  launcher=$(mktemp /tmp/gameserver-firstrun.XXXXXX)
  printf '#!/bin/bash\ncd %q || exit 1\nexec %s\n' "$GS_DIR" "$START_CMD" > "$launcher"
  chmod 755 "$launcher"
  systemctl stop gameserver-firstrun.service 2>/dev/null
  systemctl reset-failed gameserver-firstrun.service 2>/dev/null

  info "Starting it as $GS_USER. Ctrl+C stops it early; otherwise it stops after ${secs}s."
  interruptible systemd-run --pty --quiet --collect --unit=gameserver-firstrun \
    --uid="$GS_USER" --gid="$(user_group "$GS_USER")" --working-directory="$GS_DIR" \
    -p RuntimeMaxSec="$secs" -p KillSignal=SIGINT -p TimeoutStopSec=30 "$launcher"
  rm -f "$launcher"
  ok "Test run over — any generated config files are now in $GS_DIR"
  return 0
}

systemd_escape() { # make a command safe inside ExecStart="..."
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//\$/\$\$}
  s=${s//%/%%}
  printf '%s' "$s"
}

write_update_script() {
  local steamcmd
  steamcmd=$(find_steamcmd) || { err "SteamCMD isn't installed — can't create gameserver-steamupdate."; return 1; }
  {
    cat <<'EOF'
#!/usr/bin/env bash
# gameserver-steamupdate — generated by gameserver-setup.
# Stops the server, updates it with SteamCMD, then starts it again if it was running.
#   gameserver-steamupdate            normal update
#   gameserver-steamupdate validate   also re-check every file (can undo edits to stock config files)
set -uo pipefail
EOF
    printf 'GS_USER=%q\nGS_DIR=%q\nAPP_ID=%q\nSTEAM_LOGIN=%q\nSTEAM_BETA=%q\nSTEAMCMD=%q\nSERVICE=%q\n' \
      "$GS_USER" "$GS_DIR" "$STEAM_APPID" "$STEAM_LOGIN" "$STEAM_BETA" "$steamcmd" "$SERVICE_NAME"
    cat <<'EOF'

args=(+force_install_dir "$GS_DIR" +login "$STEAM_LOGIN" +app_update "$APP_ID")
[[ -n $STEAM_BETA ]] && args+=(-beta "$STEAM_BETA")
[[ ${1:-} == validate ]] && args+=(validate)
args+=(+quit)

was_running=no
if systemctl is-active --quiet "$SERVICE"; then
  was_running=yes
  echo "Stopping $SERVICE…"
  sudo systemctl stop "$SERVICE" || exit 1
fi

if [[ $(id -un) == "$GS_USER" ]]; then
  "$STEAMCMD" "${args[@]}"
else
  sudo -u "$GS_USER" -H "$STEAMCMD" "${args[@]}"
fi
rc=$?
if (( rc == 0 )); then echo "Update finished."; else echo "SteamCMD exited with code $rc." >&2; fi

if [[ $was_running == yes ]]; then
  echo "Starting $SERVICE…"
  sudo systemctl start "$SERVICE"
fi
exit "$rc"
EOF
  } > "$UPDATE_SCRIPT"
  chown root:root "$UPDATE_SCRIPT"
  chmod 755 "$UPDATE_SCRIPT"
  ok "Created $UPDATE_SCRIPT"
}

write_sudoers() { # narrow passwordless rule: the server user can control the service, nothing else
  local sc jc tmp
  sc=$(command -v systemctl); jc=$(command -v journalctl)
  tmp=$(mktemp)
  {
    echo "# Managed by gameserver-setup — lets $GS_USER control $SERVICE_NAME and nothing else"
    echo "Cmnd_Alias GAMESERVER_CTL = $sc start $SERVICE_NAME, $sc stop $SERVICE_NAME, \\"
    echo "    $sc restart $SERVICE_NAME, $sc status $SERVICE_NAME --no-pager, \\"
    echo "    $jc -u $SERVICE_NAME -f -n 100 --no-pager"
    echo "$GS_USER ALL=(root) NOPASSWD: GAMESERVER_CTL"
  } > "$tmp"
  if visudo -cqf "$tmp"; then
    install -m 440 -o root -g root "$tmp" "$SUDOERS_FILE"
    rm -f "$tmp"
    ok "Added sudo rule $SUDOERS_FILE"
  else
    rm -f "$tmp"
    err "The sudo rule didn't pass validation, so it wasn't installed."
    return 1
  fi
}

# ── Hardening helpers ────────────────────────────────────────────────────────
ask_flag() { # ask_flag VAR "Question" DEFAULT(Y|N) — stores yes/no, remembers last answer
  local __fv=$1 q=$2 def=$3
  [[ ${!__fv} == yes ]] && def=Y
  [[ ${!__fv} == no ]]  && def=N
  if ask_yn "$q" "$def"; then printf -v "$__fv" yes; else printf -v "$__fv" no; fi
}

ssh_effective() { sshd -T 2>/dev/null | awk -v k="$1" '$1 == k {print $2; exit}'; }

apply_ssh_hardening() { # (re)write the sshd drop-in from the H_* answers
  local lines=() l
  [[ $H_ROOT_SSH == yes ]] && lines+=("PermitRootLogin no")
  if [[ $H_KEY_ONLY == yes ]]; then
    lines+=("PasswordAuthentication no")
    if sshd -T 2>/dev/null | grep -q '^kbdinteractiveauthentication '; then
      lines+=("KbdInteractiveAuthentication no")
    else
      lines+=("ChallengeResponseAuthentication no")   # older OpenSSH name
    fi
  fi
  [[ $H_DENY_GS_SSH == yes && $GS_USER != "$ADMIN_USER" ]] && lines+=("DenyUsers $GS_USER")

  if (( ${#lines[@]} == 0 )); then
    if [[ -f $SSHD_DROPIN ]]; then
      rm -f "$SSHD_DROPIN"
      run systemctl try-reload-or-restart ssh
      ok "SSH hardening removed"
    fi
    return 0
  fi
  if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
    err "This SSH server doesn't read /etc/ssh/sshd_config.d/, so the SSH settings were skipped."
    return 1
  fi
  mkdir -p "${SSHD_DROPIN%/*}"
  {
    echo "# Managed by gameserver-setup — re-run the script to change these"
    printf '%s\n' "${lines[@]}"
  } > "$SSHD_DROPIN"
  chmod 644 "$SSHD_DROPIN"
  if ! sshd -t; then
    rm -f "$SSHD_DROPIN"
    err "sshd rejected the new settings, so they were removed again."
    return 1
  fi
  run systemctl try-reload-or-restart ssh || return 1
  for l in "${lines[@]}"; do ok "SSH: $l"; done

  # Make sure nothing else overrides us
  [[ $H_ROOT_SSH == yes && $(ssh_effective permitrootlogin) != no ]] && \
    warn "Another sshd setting still allows root login — check /etc/ssh/sshd_config.d/."
  if [[ $H_KEY_ONLY == yes ]]; then
    [[ $(ssh_effective passwordauthentication) != no ]] && \
      warn "Another sshd setting still allows passwords — check /etc/ssh/sshd_config.d/."
    warn "Keep this session open and test logging in from a NEW terminal before you disconnect."
  fi
}

apply_autoupdates() {
  local reboot=false
  run "${APT_GET[@]}" install unattended-upgrades || return 1
  ask_flag H_AUTOREBOOT "Reboot automatically at 04:00 when an update needs it? (players get kicked; the server starts again on boot)" N
  [[ $H_AUTOREBOOT == yes ]] && reboot=true
  cat > "$UNATTENDED_FILE" <<EOF
// Managed by gameserver-setup — daily automatic security updates
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Automatic-Reboot "$reboot";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
  run systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
  ok "Security updates install automatically every day (reboots: $([[ $reboot == true ]] && echo "at 04:00 when needed" || echo off))"
}

apply_sysctl() {
  cat > "$SYSCTL_FILE" <<'EOF'
# Managed by gameserver-setup — kernel network hardening.
# Safe for playit.gg: it only makes outgoing connections and forwards to local ports.

# Ignore ICMP redirects (blocks route hijacking) and never send them
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Refuse source-routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Loose reverse-path filtering: drops spoofed packets, still fine with VPNs/tunnels
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# SYN-flood protection, ignore broadcast pings and bogus ICMP errors
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Hide kernel addresses and the kernel log from normal users
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
EOF
  if sysctl -q -p "$SYSCTL_FILE"; then
    ok "Kernel network hardening applied ($SYSCTL_FILE)"
  else
    warn "Some settings couldn't be applied right now (normal inside some containers); the rest are active."
  fi
}

apply_private_homes() {
  local cur name uid home
  # New users: useradd's HOME_MODE (only tightened, never loosened)
  cur=$(awk '$1 == "HOME_MODE" {m = $2} END {print m}' /etc/login.defs 2>/dev/null)
  if [[ -z $cur || ${cur: -1} != 0 ]]; then
    if [[ -n $cur ]]; then
      sed -i -E 's/^HOME_MODE[[:space:]].*/HOME_MODE\t0750/' /etc/login.defs
    else
      printf '\n# Added by gameserver-setup: new home folders are private\nHOME_MODE\t0750\n' >> /etc/login.defs
    fi
  fi
  [[ -f /etc/adduser.conf ]] && sed -i -E 's/^DIR_MODE=0?7[57]5$/DIR_MODE=0750/' /etc/adduser.conf
  # Existing users
  while IFS=: read -r name _ uid _ _ home _; do
    (( uid >= 1000 && uid < 60000 )) || continue
    [[ $home == /home/* && -d $home ]] || continue
    if [[ $(stat -c %a "$home") != *0 ]]; then
      chmod o-rwx "$home" && ok "$home is now private"
    fi
  done < <(getent passwd)
  ok "Home folders are private (new users too)"
}

apply_service_sandbox() { # write or remove the sandbox drop-in for gameserver.service
  local home extra=""
  if [[ $H_SANDBOX != yes ]]; then
    if [[ -f $SANDBOX_DROPIN ]]; then
      rm -f "$SANDBOX_DROPIN"; rmdir "${SANDBOX_DROPIN%/*}" 2>/dev/null
      ok "Service sandbox removed"
    fi
    return 0
  fi
  home=$(user_home "$GS_USER")
  # Server folder outside the server user's home needs its own write access
  if [[ -n $GS_DIR && $GS_DIR != "$home" && $GS_DIR != "$home"/* ]]; then
    case $GS_DIR in
      /home/*|/root/*) extra="BindPaths=-$GS_DIR" ;;
      *)               extra="ReadWritePaths=-$GS_DIR" ;;
    esac
  fi
  mkdir -p "${SANDBOX_DROPIN%/*}"
  cat > "$SANDBOX_DROPIN" <<EOF
# Created by gameserver-setup — limits what the game server can touch if it's ever hacked.
# If the server misbehaves after this, delete this file, then: update-service && gameserver-restart
[Service]
# Can't gain extra privileges (setuid, file capabilities)
NoNewPrivileges=yes
RestrictSUIDSGID=yes
# Whole filesystem read-only, except the server user's home
ProtectSystem=strict
ProtectHome=tmpfs
BindPaths=-$home
${extra}
# Own private /tmp
PrivateTmp=yes
# No poking at the kernel, clock, hostname or cgroups
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictRealtime=yes
EOF
  chmod 644 "$SANDBOX_DROPIN"
  ok "Service sandbox written ($SANDBOX_DROPIN)"
}

# ═════════════════════════════════════════════════════════════════════════════
#  Stages
# ═════════════════════════════════════════════════════════════════════════════

stage_installs() { # Stage 0 · Initial installs
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  run apt-get -o DPkg::Lock::Timeout=300 update || return 1
  run "${APT_GET[@]}" upgrade || return 1
  run "${APT_GET[@]}" install ufw git curl ca-certificates gnupg jq unzip nano sudo || return 1
  install_steamcmd || return 1
  install_playit || return 1
  ok "Base packages installed"
}

stage_firewall() { # Stage 1 · UFW firewall
  command -v ufw >/dev/null 2>&1 || { err "ufw isn't installed — run Stage 0 first."; return 1; }
  local lan port extra c p pnum proto inside line rest
  lan=$(detect_lan_cidr)
  port=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')

  prompt_required LAN_CIDRS "Local network(s) allowed to SSH in (space-separated)" "${LAN_CIDRS:-$lan}"
  for c in $LAN_CIDRS; do
    valid_ipv4_cidr "$c" || { err "'$c' isn't a valid IPv4 network like 192.168.1.0/24"; return 1; }
  done
  prompt_required SSH_PORT "SSH port" "${SSH_PORT:-${port:-22}}"
  [[ $SSH_PORT =~ ^[0-9]+$ ]] || { err "Port must be a number."; return 1; }

  # Don't lock you out of your current session
  if [[ $SSH_CLIENT_IP =~ ^[0-9.]+$ ]]; then
    inside=no
    for c in $LAN_CIDRS; do ip_in_cidr "$SSH_CLIENT_IP" "$c" && inside=yes; done
    if [[ $inside == yes ]]; then
      ok "Your current SSH session ($SSH_CLIENT_IP) is inside the allowed network"
    else
      warn "You're connected from $SSH_CLIENT_IP, which is outside $LAN_CIDRS — this would lock you out."
      if ask_yn "Also allow SSH from $SSH_CLIENT_IP?" Y; then
        LAN_CIDRS+=" $SSH_CLIENT_IP/32"
      else
        ask_yn "Enable the firewall anyway?" N || return 1
      fi
    fi
  elif [[ -n $SSH_CLIENT_IP ]]; then
    warn "You're connected over IPv6 ($SSH_CLIENT_IP); only IPv4 LAN rules are added — make sure you can still get in."
  fi

  prompt extra "Game ports to open to the LAN for direct play, e.g. 2456:2458/udp 27015/tcp (blank = none)" ""
  for p in $extra; do
    [[ $p =~ ^[0-9]+(:[0-9]+)?(/(tcp|udp))?$ ]] || { err "'$p' should look like 27015, 27015/udp or 2456:2458/udp"; return 1; }
  done
  save_config

  # Rules that expose SSH to the whole world defeat the point — offer to drop them
  while IFS= read -r line; do
    [[ $line =~ ^ufw\ (allow|limit)\ (22|ssh|OpenSSH|$SSH_PORT)(/tcp)?(\ comment\ .*)?$ ]] || continue
    rest=${line#ufw }; rest=${rest%% comment *}
    warn "Existing rule opens SSH to everyone: $line"
    # shellcheck disable=SC2086  # $rest is a rule spec that must split into words
    ask_yn "Remove it?" Y && run ufw --force delete $rest
  done < <(ufw show added 2>/dev/null)

  run ufw default deny incoming || return 1
  run ufw default allow outgoing || return 1
  for c in $LAN_CIDRS; do
    run ufw allow from "$c" to any port "$SSH_PORT" proto tcp comment "SSH from LAN" || return 1
  done
  for p in $extra; do
    pnum=${p%/*}; proto=""; [[ $p == */* ]] && proto=${p#*/}
    for c in $LAN_CIDRS; do
      if [[ -n $proto ]]; then
        run ufw allow from "$c" to any port "$pnum" proto "$proto" comment "Game server (LAN)" || return 1
      else
        run ufw allow from "$c" to any port "$pnum" proto tcp comment "Game server (LAN)" || return 1
        run ufw allow from "$c" to any port "$pnum" proto udp comment "Game server (LAN)" || return 1
      fi
    done
  done
  run ufw --force enable || return 1
  ufw status verbose
  note "playit.gg tunnels connect outward, so they don't need any incoming ports."
}

stage_hardening() { # Stage 2 · Hardening — each item is its own yes/no
  local keys failed=0 later=no
  [[ $GS_USER == "$ADMIN_USER" ]] && later=yes   # server user not created yet

  echo "  ${C_B}2a. Block root SSH login${C_R}"
  if [[ $ADMIN_USER == root ]]; then
    warn "You're running this as root, so this would lock you out. Create a normal sudo user first — skipping."
    H_ROOT_SSH=no
  else
    ask_flag H_ROOT_SSH "Stop root from logging in over SSH? (you keep using sudo)" Y
  fi

  echo; echo "  ${C_B}2b. Block the server user from SSH${C_R}"
  ask_flag H_DENY_GS_SSH "Stop the server user from ever logging in over SSH?" Y
  [[ $H_DENY_GS_SSH == yes && $later == yes ]] && note "Applied when the server user is created in Stage 3."

  echo; echo "  ${C_B}2c. Key-only SSH login${C_R}"
  keys=$(grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$(user_home "$ADMIN_USER")/.ssh/authorized_keys" 2>/dev/null)
  if (( ${keys:-0} > 0 )); then
    ask_flag H_KEY_ONLY "Turn off password logins? ($ADMIN_USER has $keys SSH key(s) set up)" N
  else
    H_KEY_ONLY=no
    note "Not available: $ADMIN_USER has no SSH key yet, so this would lock you out."
    note "Add one from your PC with ssh-copy-id $ADMIN_USER@<this-vm>, then re-run this stage."
  fi
  apply_ssh_hardening || failed=1
  save_config

  echo; echo "  ${C_B}2d. Automatic security updates${C_R}"
  ask_flag H_AUTOUPDATES "Install security updates automatically every day?" Y
  if [[ $H_AUTOUPDATES == yes ]]; then
    apply_autoupdates || failed=1
  elif [[ -f $UNATTENDED_FILE ]]; then
    rm -f "$UNATTENDED_FILE"; ok "Removed this script's automatic-update settings"
  fi
  save_config

  echo; echo "  ${C_B}2e. Kernel network hardening${C_R}"
  ask_flag H_SYSCTL "Apply kernel network hardening (sysctl)?" Y
  if [[ $H_SYSCTL == yes ]]; then
    apply_sysctl
  elif [[ -f $SYSCTL_FILE ]]; then
    rm -f "$SYSCTL_FILE"; ok "Removed $SYSCTL_FILE (old values stay until the next reboot)"
  fi
  save_config

  echo; echo "  ${C_B}2f. Private home folders${C_R}"
  ask_flag H_PRIVATE_HOMES "Make home folders private, so users can't read each other's files?" Y
  [[ $H_PRIVATE_HOMES == yes ]] && apply_private_homes
  save_config

  echo; echo "  ${C_B}2g. Sandbox the game server service${C_R}"
  ask_flag H_SANDBOX "Limit what the game server can touch if it's ever hacked?" Y
  if [[ -f $SERVICE_FILE ]]; then
    apply_service_sandbox && run systemctl daemon-reload
    systemctl is-active --quiet "$SERVICE_NAME" && note "Restart the server to apply it: gameserver-restart"
  elif [[ $H_SANDBOX == yes ]]; then
    note "Applied when the service is created in Stage 9."
  fi
  save_config

  (( failed == 0 ))
}

stage_server_user() { # Stage 3 · Server user
  local name def=gameserver
  [[ $GS_USER != "$ADMIN_USER" ]] && def=$GS_USER
  prompt_required name "Server user name" "$def"
  [[ $name =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { err "Use lowercase letters, digits, - or _ (max 32 characters)."; return 1; }
  if id "$name" >/dev/null 2>&1; then
    ok "User $name already exists — using it"
  else
    run useradd --create-home --shell /bin/bash --comment "Game server" "$name" || return 1
    ok "Created $name (no password; open a shell as it with: sudo -iu $name)"
  fi
  GS_USER=$name
  save_config

  # Apply Stage 2 choices that depend on the server user
  if [[ $H_PRIVATE_HOMES == yes ]]; then
    chmod o-rwx "$(user_home "$GS_USER")" && ok "$GS_USER's home folder is private"
  fi
  if [[ $H_DENY_GS_SSH == yes && $GS_USER != "$ADMIN_USER" ]]; then
    apply_ssh_hardening || warn "Couldn't block SSH for $GS_USER."
  fi
  return 0
}

stage_playit() { # Stage 4 · playit.gg setup
  command -v playit >/dev/null 2>&1 || { err "playit isn't installed — run Stage 0 first."; return 1; }
  run systemctl enable --now playit || return 1
  info "Claiming this agent: playit prints a link — open it, log in to playit.gg and approve."
  info "Once it says the agent is set up you're done (Ctrl+C brings you back here if it hangs)."
  interruptible playit setup
  systemctl is-active --quiet playit || run systemctl restart playit
  ok "playit runs as a service and starts on boot"
  note "Next: in the playit.gg dashboard, add a tunnel for your game's port to this agent."
  note "If no link appeared: journalctl -u playit -n 50 --no-pager | grep -i claim"
}

stage_install_steam() { # Stage 5.1
  find_steamcmd >/dev/null || { err "SteamCMD isn't installed — run Stage 0 first."; return 1; }
  note "Find the App ID on steamdb.info (search \"<game> dedicated server\"), e.g. Valheim 896660, Palworld 2394010."
  prompt_required STEAM_APPID "Dedicated server App ID" "$STEAM_APPID"
  [[ $STEAM_APPID =~ ^[0-9]+$ ]] || { err "App IDs are numbers."; return 1; }
  prompt_required GS_DIR "Install folder" "${GS_DIR:-$(user_home "$GS_USER")/serverfiles}"
  prompt STEAM_BETA "Beta branch (blank = normal release)" ""
  [[ -n $STEAM_LOGIN ]] || STEAM_LOGIN=anonymous
  INSTALL_METHOD=steam STEAM_INSTALL_OK=no
  save_config
  prepare_dir || return 1

  info "Downloading as $GS_USER (login: $STEAM_LOGIN) — big servers can take a while."
  if steam_app_update; then
    save_config
    ok "Installed into $GS_DIR"
  else
    save_config
    err "SteamCMD couldn't finish. If this game needs a real Steam account, log in during Stage 6 and it will retry."
    return 1
  fi
}

stage_install_github() { # Stage 5.2
  local repo mode
  prompt_required repo "GitHub repo (owner/name or URL)" "$GH_REPO"
  repo=${repo#git@github.com:}; repo=${repo#https://}; repo=${repo#http://}; repo=${repo#github.com/}
  repo=$(cut -d/ -f1-2 <<< "$repo"); repo=${repo%.git}
  [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { err "That doesn't look like owner/name."; return 1; }
  GH_REPO=$repo
  prompt_required GS_DIR "Install folder" "${GS_DIR:-$(user_home "$GS_USER")/serverfiles}"
  echo "    1) git clone the repository"
  echo "    2) Download a file from the latest release"
  prompt mode "Choose 1 or 2" "1"
  case $mode in
    1) github_clone   || return 1 ;;
    2) github_release || return 1 ;;
    *) err "Please choose 1 or 2."; return 1 ;;
  esac
  INSTALL_METHOD=github
  save_config
}

github_clone() {
  local branch args=(clone)
  prepare_dir || return 1
  if [[ -d $GS_DIR/.git ]]; then
    ask_yn "$GS_DIR is already a git checkout — pull the latest changes instead?" Y || return 1
    run_as "$GS_USER" git -C "$GS_DIR" pull --ff-only
    return
  fi
  if [[ -n $(ls -A "$GS_DIR") ]]; then err "$GS_DIR isn't empty — pick an empty folder."; return 1; fi
  prompt branch "Branch or tag (blank = default branch)" ""
  [[ -n $branch ]] && args+=(--branch "$branch")
  run_as "$GS_USER" git "${args[@]}" "https://github.com/$GH_REPO.git" "$GS_DIR" || return 1
  ok "Cloned $GH_REPO into $GS_DIR"
}

github_release() {
  local json tag pick name url i names=() urls=() sizes=()
  info "Looking up the latest release of $GH_REPO"
  json=$(curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$GH_REPO/releases/latest") \
    || { err "No release found (the repo may have no releases, be private, or you hit GitHub's rate limit)."; return 1; }
  tag=$(jq -r '.tag_name' <<< "$json")
  mapfile -t names < <(jq -r '.assets[].name' <<< "$json")
  mapfile -t urls  < <(jq -r '.assets[].browser_download_url' <<< "$json")
  mapfile -t sizes < <(jq -r '.assets[].size' <<< "$json")
  names+=("Source code (tar.gz)"); urls+=("$(jq -r '.tarball_url' <<< "$json")"); sizes+=("")

  echo "  Release $tag:"
  for i in "${!names[@]}"; do
    printf '    %2d) %s %s\n' $(( i + 1 )) "${names[i]}" \
      "${sizes[i]:+${C_D}($(numfmt --to=iec --suffix=B "${sizes[i]}"))${C_R}}"
  done
  prompt_required pick "Which file?" ""
  [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#names[@]} )) || { err "Pick a number from the list."; return 1; }
  name=${names[pick-1]} url=${urls[pick-1]}
  [[ $name == "Source code (tar.gz)" ]] && name="${GH_REPO#*/}-$tag.tar.gz"

  prepare_dir || return 1
  run_as "$GS_USER" curl -fL --progress-bar -o "$GS_DIR/$name" "$url" || return 1
  case ${name,,} in
    *.zip)
      if ask_yn "Extract $name here?" Y; then
        run_as "$GS_USER" unzip -oq "$GS_DIR/$name" -d "$GS_DIR" && rm -f "$GS_DIR/$name"
      fi ;;
    *.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tar)
      if ask_yn "Extract $name here?" Y; then
        run_as "$GS_USER" tar -xf "$GS_DIR/$name" -C "$GS_DIR" && rm -f "$GS_DIR/$name"
      fi ;;
    *.jar|*.deb|*.rpm|*.txt|*.md) ;;
    *)
      ask_yn "Make $name executable?" Y && chmod +x "$GS_DIR/$name" ;;
  esac
  ok "Release $tag is in $GS_DIR:"
  ls -la "$GS_DIR" | sed 's/^/      /' | head -20
}

stage_install_manual() { # Stage 5.3
  prompt_required GS_DIR "Folder you'll install the server into" "${GS_DIR:-$(user_home "$GS_USER")/serverfiles}"
  prepare_dir || return 1
  INSTALL_METHOD=manual
  save_config
  ok "Folder ready: $GS_DIR (owned by $GS_USER)"
  [[ $GS_USER != "$ADMIN_USER" ]] && info "Install as the server user so file ownership stays right:  sudo -iu $GS_USER"
  info "Stage 9 will ask for the command that starts it."
}

stage_steam_firstrun() { # Stage 6 · SteamCMD first-run: self-update, optional account login, optional test run
  local steamcmd user def=N
  steamcmd=$(find_steamcmd) || { err "SteamCMD isn't installed — run Stage 0 first."; return 1; }

  echo "  ${C_B}6a. Update SteamCMD${C_R}"
  if ask_yn "Let SteamCMD update itself now?" Y; then
    run_as "$GS_USER" "$steamcmd" +quit || warn "SteamCMD reported an error while updating."
  fi

  echo; echo "  ${C_B}6b. Steam account login${C_R}"
  note "Most servers download anonymously. Some games need a Steam account that owns them."
  if [[ $STEAM_INSTALL_OK != yes ]]; then
    warn "The Stage 5.1 download didn't finish — a Steam login may be what it needs."
    def=Y
  fi
  if ask_yn "Log in with a Steam account?" "$def"; then
    [[ $STEAM_LOGIN != anonymous ]] && user=$STEAM_LOGIN || user=""
    prompt_required user "Steam username" "$user"
    note "Tip: use a separate Steam account for servers, not your main one."
    info "SteamCMD asks for the password and Steam Guard code itself — this script never sees or stores them."
    if interruptible run_as "$GS_USER" "$steamcmd" +login "$user" +quit; then
      STEAM_LOGIN=$user
      save_config
      ok "Logged in. SteamCMD remembers it for $GS_USER, and updates will use '$user'."
    else
      err "Login failed."
      return 1
    fi
  fi
  if [[ $STEAM_INSTALL_OK != yes ]]; then
    if ask_yn "Retry the server download now (login: $STEAM_LOGIN)?" Y; then
      steam_app_update || { save_config; err "Download still failing."; return 1; }
      save_config
      ok "Installed into $GS_DIR"
    fi
  fi

  echo; echo "  ${C_B}6c. First run${C_R}"
  if [[ $STEAM_INSTALL_OK != yes ]]; then
    warn "Server files aren't installed yet, so skipping the test run."
    return 1
  fi
  if ask_yn "Run the server once now so it creates its config files?" Y; then
    first_run || return 1
  fi
}

stage_alias_motd() { # Stage 7 · alias-motd
  command -v git >/dev/null 2>&1 || { err "git isn't installed — run Stage 0 first."; return 1; }
  local tmp u h
  alias_users
  tmp=$(mktemp -d)
  run git clone --quiet --depth 1 "$ALIAS_MOTD_REPO" "$tmp/alias-motd" || { rm -rf "$tmp"; return 1; }
  for u in "${ALIAS_USERS[@]}"; do
    h=$(user_home "$u")
    as_user "$u" mkdir -p "$h/.local/bin"
    install -m 755 -o "$u" -g "$(user_group "$u")" "$tmp/alias-motd/alias-motd.sh" "$h/.local/bin/alias-motd.sh"
    ensure_user_file "$u" "$h/.bashrc"
    if ! grep -qF 'alias-motd.sh' "$h/.bashrc"; then
      # Same hook the alias-motd README installs (so its uninstall steps still work)
      cat >> "$h/.bashrc" <<'EOF'

# Show my aliases whenever a new terminal opens
if [[ $- == *i* && -x $HOME/.local/bin/alias-motd.sh ]]; then
    "$HOME/.local/bin/alias-motd.sh"
fi
EOF
    fi
    ok "$u: alias-motd installed"
  done
  rm -rf "$tmp"
}

stage_alias_helpers() { # Stage 8 · edit-alias / update-alias
  local u
  alias_users
  for u in "${ALIAS_USERS[@]}"; do
    write_alias_block "$u" base \
      edit-alias   "Edit your aliases"           'nano ~/.bash_aliases' \
      update-alias "Reload your aliases"         'source ~/.bash_aliases'
  done
}

stage_service() { # Stage 9 · systemd service
  local desc group
  prompt_required GS_DIR "Server folder (WorkingDirectory)" "${GS_DIR:-$(user_home "$GS_USER")/serverfiles}"
  [[ -d $GS_DIR ]] || warn "$GS_DIR doesn't exist yet — make sure the server ends up there."
  suggest_executables
  note "Examples:  ./start_server.sh   ·   ./srcds_run -game csgo +map de_dust2   ·   java -Xmx4G -jar server.jar nogui"
  prompt_required START_CMD "Start command (runs inside that folder)" "$START_CMD"
  prompt desc "Service description" "Game server"
  save_config

  if [[ -f $SERVICE_FILE ]]; then
    ask_yn "$SERVICE_NAME already exists — replace it? (old one is kept as .bak)" Y || return 0
    cp "$SERVICE_FILE" "$SERVICE_FILE.bak"
  fi
  group=$(user_group "$GS_USER")
  cat > "$SERVICE_FILE" <<EOF
# Created by gameserver-setup.  Change it with: edit-service, then update-service && gameserver-restart
$([[ $H_SANDBOX == yes ]] && echo "# Sandbox rules from Stage 2 are in $SANDBOX_DROPIN")
[Unit]
Description=${desc//%/%%}
Wants=network-online.target
After=network-online.target
# Give up after 5 crashes in 10 minutes instead of restarting forever
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
User=$GS_USER
Group=$group
WorkingDirectory=$GS_DIR
# The command between the quotes starts the server. Write \$\$ for a literal \$ and %% for a literal %.
ExecStart=/bin/bash -c "exec $(systemd_escape "$START_CMD")"
Restart=on-failure
RestartSec=10
# Most dedicated servers save and shut down cleanly on Ctrl+C (SIGINT)
KillSignal=SIGINT
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SERVICE_FILE"
  ok "Created $SERVICE_FILE"
  apply_service_sandbox            # adds or removes the Stage 2 sandbox drop-in
  run systemctl daemon-reload || return 1

  if ask_yn "Start the server automatically on boot?" Y; then
    run systemctl enable "$SERVICE_NAME"
  else
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
  fi
  if ask_yn "Start it now?" N; then
    run systemctl restart "$SERVICE_NAME"
    sleep 3
    systemctl --no-pager --lines=10 status "$SERVICE_NAME"
  fi
  return 0
}

stage_service_aliases() { # Stage 10 · aliases for the service
  local svc ctl upd=()
  [[ -f $SERVICE_FILE ]] || warn "$SERVICE_NAME doesn't exist yet (Stage 9) — adding the aliases anyway."
  alias_users

  svc=(edit-service       "Edit the gameserver systemd service"      "SUDO_EDITOR=nano sudoedit $SERVICE_FILE"
       update-service     "Apply service edits (then gameserver-restart)" "sudo systemctl daemon-reload")
  ctl=(gameserver-start   "Start the game server"                    "sudo systemctl start $SERVICE_NAME"
       gameserver-stop    "Stop the game server"                     "sudo systemctl stop $SERVICE_NAME"
       gameserver-restart "Restart the game server"                  "sudo systemctl restart $SERVICE_NAME"
       gameserver-status  "Is the game server running?"              "sudo systemctl status $SERVICE_NAME --no-pager"
       gameserver-logs    "Follow the game server's console log"     "sudo journalctl -u $SERVICE_NAME -f -n 100 --no-pager")
  if [[ $INSTALL_METHOD == steam ]]; then
    write_update_script || return 1
    upd=(gameserver-steamupdate "Stop, update via SteamCMD, start again" "$UPDATE_SCRIPT")
  fi

  # edit-service / update-service only go to you (the user who ran this script)
  write_alias_block "$ADMIN_USER" service "${svc[@]}" "${ctl[@]}" "${upd[@]}"

  if [[ $GS_USER != "$ADMIN_USER" ]]; then
    echo
    info "$GS_USER has no sudo rights, so its aliases need a small, specific sudo rule."
    note "It never gets edit-service/update-service — those stay on $ADMIN_USER."
    if ask_yn "Let $GS_USER start/stop/restart/view the server (and update it) without a password?" Y; then
      write_sudoers || return 1
      write_alias_block "$GS_USER" service "${ctl[@]}" "${upd[@]}"
    else
      rm -f "$SUDOERS_FILE"
      remove_alias_block "$GS_USER" service
      info "No service aliases for $GS_USER — manage the server from your own account."
    fi
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  Flow
# ═════════════════════════════════════════════════════════════════════════════

exec_stage() { # exec_stage INDEX FUNCTION
  if "$2"; then
    RESULT[$1]=done
  else
    RESULT[$1]=failed
    err "Stage $1 didn't finish."
    ask_yn "Continue with the next stage anyway?" Y || quit_now 1
  fi
}

run_stage() { # run_stage INDEX DESCRIPTION FUNCTION [GUARD_FUNCTION "why it's skipped"]
  local i=$1 desc=$2 fn=$3 guard=${4-} reason=${5-}
  stage_header "$i" "Stage $i ${G_DOT} ${TITLES[i]}"
  if [[ -n $guard ]] && ! "$guard"; then
    info "Skipped automatically — $reason."
    RESULT[i]="n/a"
    return
  fi
  printf '  %s\n\n' "$desc"
  if confirm_stage; then
    exec_stage "$i" "$fn"
  else
    RESULT[i]=skipped
    info "Skipped."
  fi
}

stage_install_menu() {
  local choice
  stage_header 5 "Stage 5 ${G_DOT} ${TITLES[5]}"
  echo "  Pick one (the other options are skipped):"
  echo "    1) Stage 5.1 — Install via SteamCMD"
  echo "    2) Stage 5.2 — Install from GitHub"
  echo "    3) Stage 5.3 — I'll install it myself"
  echo "    s) Skip    q) Quit"
  echo
  while true; do
    read -rp "  Choice: " choice || quit_now 1
    case ${choice,,} in
      1) RESULT_NOTE[5]="SteamCMD";          exec_stage 5 stage_install_steam;  return ;;
      2) RESULT_NOTE[5]="GitHub";            exec_stage 5 stage_install_github; return ;;
      3) RESULT_NOTE[5]="installing myself"; exec_stage 5 stage_install_manual; return ;;
      s|skip) RESULT[5]=skipped; info "Skipped."; return ;;
      q|quit) quit_now 0 ;;
    esac
  done
}

needs_steam() { [[ $INSTALL_METHOD == steam ]]; }

summary() {
  local i status icon processed=0
  for i in $(seq 0 $(( TOTAL_STEPS - 1 ))); do [[ -n ${RESULT[i]:-} ]] && processed=$(( processed + 1 )); done
  echo; rule
  progress_bar "$processed"
  printf '   %d of %d steps processed\n' "$processed" "$TOTAL_STEPS"
  rule
  for i in $(seq 0 $(( TOTAL_STEPS - 1 ))); do
    status=${RESULT[i]:-not reached}
    case $status in
      done)   icon="$C_GRN$G_OK$C_R" ;;
      failed) icon="$C_RED$G_BAD$C_R" ;;
      *)      icon="$C_D$G_SKIP$C_R" ;;
    esac
    printf '   %s  Stage %-2d %-20s %s%s\n' "$icon" "$i" "${TITLES[i]}" "$status" "${RESULT_NOTE[i]:+ — ${RESULT_NOTE[i]}}"
  done
  echo
  printf '   %-14s %s\n' "Server user:" "$GS_USER"
  [[ -n $GS_DIR ]] && printf '   %-14s %s\n' "Server files:" "$GS_DIR"
  [[ -f $SERVICE_FILE ]] && printf '   %-14s %s (%s, %s on boot)\n' "Service:" "$SERVICE_NAME" \
    "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)" "$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null)"
  command -v playit >/dev/null 2>&1 && printf '   %-14s %s\n' "playit:" "$(systemctl is-active playit 2>/dev/null)"
  local h=()
  [[ $H_ROOT_SSH == yes ]]      && h+=("no root SSH")
  [[ $H_DENY_GS_SSH == yes ]]   && h+=("no server-user SSH")
  [[ $H_KEY_ONLY == yes ]]      && h+=("key-only SSH")
  [[ $H_AUTOUPDATES == yes ]]   && h+=("auto updates")
  [[ $H_SYSCTL == yes ]]        && h+=("sysctl")
  [[ $H_PRIVATE_HOMES == yes ]] && h+=("private homes")
  [[ $H_SANDBOX == yes ]]       && h+=("service sandbox")
  (( ${#h[@]} )) && printf '   %-14s %s\n' "Hardening:" "$(printf '%s, ' "${h[@]}" | sed 's/, $//')"
  echo
  info "Log out and back in (or run: source ~/.bash_aliases) to load new aliases."
  [[ -f /var/run/reboot-required ]] && warn "The system upgrade asks for a reboot: sudo reboot"
  note "Answers are saved in $CONF_FILE — re-run this script any time to redo a stage."
  echo
}

quit_now() {
  local code=${1:-0}
  trap - INT
  echo; warn "Stopping here."
  summary
  exit "$code"
}

preflight() {
  if [[ ! -r /etc/os-release ]]; then err "Can't read /etc/os-release."; exit 1; fi
  OS_NAME=$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")
  case " $(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}") " in
    *" ubuntu "*) OS_FAMILY=ubuntu ;;
    *" debian "*) OS_FAMILY=debian ;;
    *)            OS_FAMILY=unknown ;;
  esac
  if [[ $OS_FAMILY == unknown ]]; then
    warn "This script is made for Ubuntu and Debian; found $OS_NAME."
    ask_yn "Continue anyway?" N || exit 1
  fi
  command -v systemctl >/dev/null 2>&1 || { err "systemd is required."; exit 1; }

  ADMIN_USER=${SUDO_USER:-$(logname 2>/dev/null || true)}
  [[ -n $ADMIN_USER ]] || ADMIN_USER=root
  SSH_CLIENT_IP=${SETUP_SSH_CLIENT:-}
  [[ -n $SSH_CLIENT_IP ]] || SSH_CLIENT_IP=$(who -m 2>/dev/null | sed -n 's/.*(\([0-9.]*\)).*/\1/p')

  load_config
  [[ -n $STEAM_LOGIN ]] || STEAM_LOGIN=anonymous
  if [[ -z $GS_USER ]] || ! id "$GS_USER" >/dev/null 2>&1; then GS_USER=$ADMIN_USER; fi
}

banner() {
  echo
  printf '  %sGame server VM setup%s\n' "$C_B" "$C_R"
  printf '  %s%s  %s  you: %s  %s  server user: %s%s\n' "$C_D" "$OS_NAME" "$G_DOT" "$ADMIN_USER" "$G_DOT" "$GS_USER" "$C_R"
  [[ -s $CONF_FILE ]] && note "Using saved answers from $CONF_FILE"
  echo "  You'll be asked before every stage — answer s to skip one, q to quit."
}

main() {
  # Re-launch as root, remembering who ran it and where they SSH'd in from
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || { echo "Run this as root (su -), or install sudo first." >&2; exit 1; }
    [[ -f $0 ]] || { echo "Save this script to a file and run it from there." >&2; exit 1; }
    local ssh=${SSH_CONNECTION:-}
    exec sudo env SETUP_SSH_CLIENT="${ssh%% *}" bash "$(readlink -f "$0")" "$@"
  fi

  trap on_int INT
  preflight
  banner

  run_stage 0  "apt update + upgrade, then install SteamCMD, playit.gg, ufw and git (plus curl, jq, unzip, nano, sudo)." stage_installs
  run_stage 1  "Deny incoming, allow outgoing, and only allow SSH from your local network." stage_firewall
  run_stage 2  "Security hardening — you'll be asked about each item separately." stage_hardening
  run_stage 3  "Create a dedicated user (no password) that owns and runs the server. Skip to use $ADMIN_USER." stage_server_user
  run_stage 4  "Turn on the playit.gg service and link this VM to your playit account." stage_playit
  stage_install_menu
  run_stage 6  "Update SteamCMD, log in with a Steam account if the game needs one, and run the server once to create its configs." \
               stage_steam_firstrun needs_steam "only applies when the server was installed with SteamCMD (Stage 5.1)"
  run_stage 7  "Install alias-motd (shows your aliases on login) for $(alias_users_text)." stage_alias_motd
  run_stage 8  "Add edit-alias and update-alias to ~/.bash_aliases for $(alias_users_text)." stage_alias_helpers
  run_stage 9  "Create $SERVICE_NAME so the server runs in the background (as $GS_USER) and restarts if it crashes." stage_service
  run_stage 10 "Add edit-service and update-service (for $ADMIN_USER only), plus gameserver-start/stop/restart/status/logs$([[ $INSTALL_METHOD == steam ]] && echo "/steamupdate")." stage_service_aliases

  summary
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
