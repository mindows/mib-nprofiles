# Design notes

Why the widget behaves the way it does. The [README](../README.md) covers how
to use it. This page is the reasoning behind it, for contributors and the
curious.

## What other platforms do

- **macOS Network Locations** keep one full set of network settings per
  network port (DHCP or manual IP, DNS servers, search domains, proxies,
  802.1X). The Automatic location takes whatever each network hands out. The
  user switches locations by hand. macOS never switches on its own, which is
  the gap tools such as wifi-loc-control, location-switch and
  wifi-location-changer fill with one rule: "connected to SSID X → location X".
- **NetSetMan (Windows)** is the maximal version. A profile can also carry
  routes, the MAC address, proxies, hosts-file entries, mapped drives, the
  default printer, wallpaper, power plan and scripts. It auto-switches on
  nearby Wi-Fi, gateway MAC, ping replies, NIC state and time of day.
- **NetworkManager** already stores settings per connection, and a Wi-Fi
  connection is per SSID, so "this network always uses this DNS" is already
  possible. What it lacks is a *named set of settings, independent of the
  network*, that one click (or one rule) applies to whatever you are on.

We take the macOS model and the auto-switch rules people actually use, and
leave the NetSetMan long tail out.

## Scope

A **profile** holds, each part optional (unset = keep what the network gives):

| Part | Values |
|---|---|
| IPv4 | Automatic (DHCP), or Manual: address/prefix and gateway, for Wi-Fi or Ethernet |
| DNS | server list, search domains. When set, DNS from the network is ignored |
| IPv6 | Automatic, or Off |
| Wi-Fi | join one of your saved Wi-Fi networks on switch |
| VPN | bring up one of your NetworkManager VPN / WireGuard connections |

**Automatic** is a built-in profile that changes nothing, as on macOS. It
can't be edited or deleted.

**Auto-switch** is an ordered list of rules, plus a fallback profile (Automatic
by default). The first rule that matches wins. Conditions:

- *Wi-Fi connected to* SSID
- *Wi-Fi in range* SSID
- *Ethernet connected*

Each auto-switch sends one notification. Auto-switch has a global on/off
switch.

**Manual picks win until the network changes.** When you choose a profile by
hand, rules stay quiet until the set of connected networks changes (a
different SSID, a cable plugged or pulled). This matches what people expect
from a location switcher: it shouldn't fight you, but it should follow you to
the next place.

### Left out on purpose

Proxies (few Linux apps read one system proxy), hosts file, MAC address
spoofing, static routes, hostname, time- and ping-based triggers, gateway-MAC
rules and running scripts. They are rarely used, and most need root.

## How settings are applied

Everything goes through `nmcli`, which ships with Omarchy. Omarchy moved from
iwd and systemd-networkd to NetworkManager, so no extra packages are needed.

Profiles are applied with **`nmcli device modify`**, which changes the
settings *active on a device* and nothing else:

- **No root, no password.** It needs NetworkManager's `network-control`
  permission, which polkit grants to the user of an active local session. No
  sudoers entry, no polkit rule, no install step.
- **Your saved connections are never edited.** Nothing is written to
  `/etc/NetworkManager`. Switching to Automatic is `nmcli device reapply`,
  which restores the saved connection exactly.
- **No reconnect.** DNS and IPv6 changes are applied in place in under 100 ms,
  and the link stays up (measured on Wi-Fi).

The price of runtime-only changes: they last until the device reconnects. So
the widget keeps one `nmcli monitor` running and, when a device (re)connects,
re-evaluates the rules and applies the chosen profile again. If the shell
isn't running (before login, say), your saved connection settings apply, which
is a safe default.

A profile's DNS and IPv6 parts apply to every connected Wi-Fi and Ethernet
device. A Manual IPv4 address applies only to the device type it was entered
for, since one address on two links would be wrong.

VPNs and Wi-Fi joins use `nmcli connection up`. On a switch away, the widget
takes down only a VPN it brought up itself.

### Loops

A profile that joins a Wi-Fi network changes the connected SSID, which can
match a different rule. So a switch performs **at most one join**: the rules
are evaluated again once the join finishes, and the result is applied without
any further join.

### "In range" rules

In-range rules read NetworkManager's scan list (`nmcli device wifi list
--rescan no`), which is cached and flickers at the edge of reception. A
network has to be seen, or missing, in two consecutive reads before an
in-range rule changes its mind. The widget only asks for a rescan (every two
minutes) while at least one in-range rule exists.

## Known conflicts

- **`omarchy dns`**: choosing Cloudflare or Google there writes a global DNS
  override for NetworkManager, which beats any per-device DNS. The widget
  detects that and says so, instead of silently showing DNS that isn't in use.
- **Tailscale and other VPNs** set DNS on their own link through
  systemd-resolved. That coexists with a profile's DNS, which is set on the
  Wi-Fi or Ethernet link.

## Privacy and security

- The widget makes **no network requests** of its own. It reads NetworkManager
  state and runs `nmcli`.
- SSIDs, addresses and DNS servers are passed to `nmcli` as arguments, so they
  show up in the process list. Any local user can already read the same values
  from NetworkManager over D-Bus (`nmcli device show`), so this discloses
  nothing new.
- Profiles and rules live in the widget's entry in
  `~/.config/omarchy/shell.json`. Nothing else is written to disk.
