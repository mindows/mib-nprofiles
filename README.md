# MIB nProfiles

An [Omarchy](https://omarchy.org/) bar widget for switching network profiles,
like Locations on macOS. A profile is a named set of network settings (DHCP or
a static IP, DNS servers, IPv6 on or off, a VPN to bring up), and one click
applies it to whatever network you are on. Rules can switch profiles for you:
"on Wi-Fi *mk*, use Home; when *work* is in range, use Work".

> **Status:** early development. Nothing to install yet. See
> [docs/design.md](docs/design.md) for what is planned and why.

## What it does

- A network-adapter icon in the bar. Click it to see your profiles and which
  one is active, and switch with a click or the keyboard.
- **Profiles** can set any of the following, and leave the rest as the network
  provides it:
  - IPv4: automatic (DHCP) or a manual address and gateway
  - DNS servers and search domains
  - IPv6 on or off
  - a saved Wi-Fi network to join
  - a NetworkManager VPN or WireGuard connection to bring up
- **Auto-switch rules**: "connected to Wi-Fi X", "Wi-Fi X in range" or
  "Ethernet connected" picks a profile. The first matching rule wins, and a
  fallback covers everywhere else. A profile you pick by hand stays until the
  network changes.
- A built-in **Automatic** profile that changes nothing.

## How it changes your network

Profiles are applied as **temporary** settings on the active device through
NetworkManager (`nmcli device modify`):

- no root, no password prompt, nothing extra to install
- your saved Wi-Fi and Ethernet connections are never edited
- switching back to Automatic restores them exactly

If you've set a system-wide DNS provider with `omarchy dns`, it overrides the
DNS in a profile. The widget will tell you when that's the case.

## Requirements

- Omarchy, with its shell (NetworkManager and `nmcli` are part of it)

## Install

```bash
omarchy plugin add https://github.com/mindows/mib-nprofiles.git --enable
```

## Update

```bash
omarchy plugin update io.github.mindows.mib-nprofiles
```

## Remove

```bash
omarchy plugin remove io.github.mindows.mib-nprofiles
```

## Privacy

The widget makes no network requests. It only reads NetworkManager state and
runs `nmcli`. Profiles and rules are stored in the widget's entry in
`~/.config/omarchy/shell.json`.

## Development

Link your checkout into the plugins folder so the shell loads it straight from
the working tree:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.mindows.mib-nprofiles
omarchy plugin enable io.github.mindows.mib-nprofiles
omarchy restart shell
```

## License

[MIT](LICENSE)
