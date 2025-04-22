#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# === Logging Helpers ===
log_info()  { echo -e "$(tput setaf 6)[INFO]$(tput sgr0)  $1"; }
log_ok()    { echo -e "$(tput setaf 2)[OK]$(tput sgr0)    $1"; }
log_warn()  { echo -e "$(tput setaf 3)[WARN]$(tput sgr0)  $1"; }
log_error() { echo -e "$(tput setaf 1)[ERROR]$(tput sgr0) $1"; }

# === Function to disable Proxmox subscription nag ===
disable_proxmox_subscription_nag() {
  if [[ -f /etc/apt/apt.conf.d/no-nag-script ]]; then
    log_ok "Nag script already disabled. Skipping."
    return
  fi

  local CHOICE
  CHOICE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "SUBSCRIPTION NAG" \
    --menu "This will disable the nag message reminding you to purchase a subscription every time you log in to the web interface.\n\nDisable subscription nag?" \
    14 58 2 \
    "yes" " " \
    "no" " " 3>&2 2>&1 1>&3)

  case "$CHOICE" in
    yes)
      whiptail --backtitle "Proxmox VE Helper Scripts" --msgbox \
        --title "Support Subscriptions" \
        "Supporting the software's development team is essential. Check their official website's Support Subscriptions for pricing. Without their dedicated work, we wouldn't have this exceptional software." 10 58

      log_info "Disabling subscription nag..."

      cat <<EOF > /etc/apt/apt.conf.d/no-nag-script
DPkg::Post-Invoke {
  "dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\\.js\$'; \
  if [ \$? -eq 1 ]; then { \
    echo 'Removing subscription nag from UI...'; \
    sed -i '/.*data\\.status.*{/{s/\\!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; \
  }; fi";
};
EOF

      apt --reinstall install proxmox-widget-toolkit &>/dev/null
      log_ok "Subscription nag disabled. (Clear your browser cache)"
      ;;
    no)
      whiptail --backtitle "Proxmox VE Helper Scripts" --msgbox \
        --title "Support Subscriptions" \
        "Supporting the software's development team is essential. Check their official website's Support Subscriptions for pricing. Without their dedicated work, we wouldn't have this exceptional software." 10 58

      log_warn "You chose not to disable the subscription nag."
      ;;
  esac
}

# === Run ===
disable_proxmox_subscription_nag
