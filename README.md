## example.com domain on Proxmox

### What?

With these scripts you can install a complete example.com domain for testing purposes on your proxmox server. This includes:

1. A client machine running a graphical MATE environment as entry point that can be accessed over RDP with the following software on it:
    - a Firefox Browser with pre-loaded certificates
    - Thunderbird Mail client, pre-loaded
2. An OpenWrt Router as exit point
3. DNS (running on dnsmasq on the OpenWrt Router) for the example.com domain
4. A Docker host (running in an unprivileged LXC Container)
5. A "fake" SMTP / IMAP Server

The environment has everything you need to run the domain, including TLS certificates and e-Mail (internal only)

### Why?

A lot of examples and samples in the internet use the "example.com" domain. Testing software and running it in a "production" environment, i.e. in your "real" network can be cumbersome, because:

- you might break something
- you jeopardize the security and/or reliability of your network
- you would have to change things and roll them back later
- in order to make the examples run in the network, you need to change a lot of config files

For all these reasons, a test environment or "Sandbox" can be extremely useful.

- apply samples as they are without too many changes (we run the example.com domain - you remember ;-) )
- No influence on the "real" world - everything is safely encapsulated
- Quick deployment of Containers or VMs into the environment - just give a machine the virtual bridge as network and it will run inside the sandbox
- The client container is lightweight, RDP makes access from Linux or Windows easy

### How? (1) - Preparation steps

Create a virtual network for your test "sandbox" that is connected nowhere (i.e. will only be visible inside the example.com). This will be the network that your example.com domain will use.

- Select the PVE Server in the Proxmox VE GUI
- Select the "Network" node
- Click on "Create" - "Linux Bridge"
- do only fill out the following fields (i.e. leave all others blank):
    - Name (e.g. "vmbr999")
    - Autostart: ticked
    - VLAN aware: ticked
    - Comment (e.g. "Virtual Sandbox Bridge")

### How? (2) - Installation

The installation can be done automatically. 
Run the following command (as root) on the PVE Server:

If you have git installed on your Proxmox Server, you can run 

```bash
git clone https://github.com/onemarcfifty/example.com-proxmox.git
```

If not, then you could download and unzip the repo by typing 

```bash
wget https://github.com/onemarcfifty/example.com-proxmox/archive/refs/heads/main.zip
unzip main.zip
```

then cd into the subfolder, review and adapt the config file and launch
```bash
./deploy-sandbox.sh
```

### More Info
AddedProxmox Network Recovery Tool on 3.29.2025
```bash

[./proxmox-3-nic-setup.sh](https://github.com/iamgrewal/po1-com-proxmox/blob/main/proxmox-3-nic-setup.sh)
```
# Proxmox Network Recovery Tool

This script (`convert_to_linux_network.sh`) is designed to assist with the migration from Open vSwitch (OVS) networking to standard Linux bridging on a Proxmox VE (PVE) system. It provides an interactive menu to configure and apply Linux-style network settings, change the hostname, restore network configurations from backups, and configure IP forwarding.

## Features

* **Interactive Configuration:** User-friendly menu for configuring network settings.
* **Linux Bridging:** Converts OVS configurations to standard Linux bridges (`vmbr0`, `vmbr1`).
* **Bonding Support:** Configures Linux bonding (`bond0`) for link aggregation.
* **VLAN Support:** Configures VLAN interfaces (`vlan50`, `vlan55`).
* **Hostname Management:** Allows changing the Proxmox node's hostname and updates related configuration files.
* **Backup and Restore:** Backs up the `/etc/network/interfaces` file before making changes and provides an option to restore from backups.
* **IP Forwarding:** Configures IP forwarding persistently.
* **Logging:** Logs all actions and errors to `/var/log/network_migration.log`.
* **Interface Checking:** Provides an option to check the currently available network interfaces and their IP addresses.

## Usage

1.  **Download the script:**
    ```bash
    wget https://raw.githubusercontent.com/iamgrewal/po1-com-proxmox/refs/heads/main/proxmox-3-nic-setup.sh
    ```
2.  **Make the script executable:**
    ```bash
    chmod +x convert_to_linux_network.sh
    ```
3.  **Run the script as root:**
    ```bash
    sudo ./proxmox-3-nic-setup.sh
    ```
4.  **Follow the interactive menu to configure your network settings.**

## Prerequisites

* Root access on a Proxmox VE system.
* Basic understanding of Linux networking concepts.
* Required packages: `ifenslave`, `bridge-utils`, `ethtool`, `iproute2`, `vlan`. The script will attempt to install these, but manual installation might be required if the system is not configured for package management.

## Script Overview

The script performs the following actions:

* **Logging:** Utilizes logging functions to record actions and errors.
* **Helper Functions:** Includes functions for user input, IP validation, interface checks, and package installation.
* **Configuration Functions:** Functions to configure loopback, bonding, bridge, and VLAN interfaces.
* **Main Configuration Function:** Applies the Linux network configuration.
* **Main Script Logic:** Presents an interactive menu to the user.

## Important Notes

* Always back up your system before making network configuration changes.
* Verify the network configuration after applying changes.
* Review the log file (`/var/log/network_migration.log`) for any errors.
* This script is designed for specific network configurations; adjust the script as needed for your environment.

## Author

Jatinder Grewal ([https://github.com/iamgrewal](https://github.com/iamgrewal//po1-com-proxmox))

