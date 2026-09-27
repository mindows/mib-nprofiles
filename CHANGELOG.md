# Changelog

## 0.1.0

First working version.

- Profiles: IPv4 (as saved, DHCP or manual), DNS servers and search domains,
  IPv6 off, a Wi-Fi network to join, a VPN or WireGuard connection to bring up.
- Auto-switch rules (connected to Wi-Fi, Wi-Fi in range, Ethernet connected)
  with a fallback profile; a manual pick holds until the network changes.
- Applied as runtime-only settings through `nmcli device modify`: no root,
  saved connections untouched, re-applied after reconnects and external
  resets.
- Bar icon with a keyboard-driven popup, settings view and profile editor.
- IPC: `list`, `current`, `use`, `auto`, `state`, `refresh`.
