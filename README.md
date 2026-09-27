# MIB nProfiles

An [Omarchy](https://omarchy.org/) bar widget for switching network profiles,
like Locations on macOS. A profile is a named set of network settings (DHCP or
a static IP, DNS servers, IPv6 on or off, a Wi-Fi network to join, a VPN to
bring up), and one click applies it to whatever network you are on. Rules can
switch profiles for you: "on Wi-Fi *mk*, use Home; when *work* is in range,
use Work".

> **Status:** 0.1.0, early. It works day to day, but expect rough edges. See
> [docs/design.md](docs/design.md) for how it works and why.

## What it does

- A network-card icon in the bar. Click it to see your profiles and which one
  is active, and switch with a click or a number key.
- **Profiles** can set any of the following, and leave the rest as the network
  provides it:
  - IPv4: DHCP, or a manual address and gateway (for Wi-Fi or Ethernet)
  - DNS servers and search domains
  - IPv6 off
  - a saved Wi-Fi network to join
  - a NetworkManager VPN or WireGuard connection to bring up
- **Auto-switch rules**: "connected to Wi-Fi X", "Wi-Fi X in range" or
  "Ethernet connected" picks a profile. The first matching rule wins, and a
  fallback profile covers everywhere else. A profile you pick by hand stays
  until you move to a different network.
- A built-in **Automatic** profile that changes nothing.

## How it changes your network

Profiles are applied as **temporary** settings on the active device through
NetworkManager (`nmcli device modify`):

- no root, no password prompt, nothing extra to install
- your saved Wi-Fi and Ethernet connections are never edited
- switching back to Automatic restores them exactly

Temporary settings end when the device reconnects, so the widget applies the
profile again after every reconnect (within a couple of seconds), and again
if something else resets the device.

If you've set a system-wide DNS provider with `omarchy dns`, it overrides the
DNS in a profile. The popup tells you when that's the case, and
`omarchy dns DHCP` hands DNS back to the profiles.

## Requirements

- Omarchy, with its shell (NetworkManager and `nmcli` are part of it)

## Install

```bash
omarchy plugin add https://github.com/mindows/mib-nprofiles.git --enable
```

The icon goes on the right of the bar. Middle-click it, or press `s` in the
popup, to open settings and make your first profile.

## Usage

| Input | Effect |
|---|---|
| left click the icon | toggle the popup |
| middle click the icon | open settings |
| click a profile | switch to it |
| `1` … `9` | switch to that profile |
| `j` / `k`, arrows, `Enter` | move through the list and switch |
| `s` | toggle the settings view |
| `n` (in settings) | new profile |
| `a` | toggle auto-switch |
| `Esc` | back, or close the popup |

To open the popup from a keybinding:

```bash
omarchy-shell shell toggle io.github.mindows.mib-nprofiles '{}'
```

### Rules

Rules are checked top to bottom, and the first one that matches picks the
profile. When none match, the "Anywhere else" profile is used. While you're
offline (lid closed, say), rules only switch if one of them matches, so
sleeping doesn't bounce you to the fallback and back.

- **Connected to Wi-Fi** matches the network you're connected to.
- **Wi-Fi in range** matches a network that's merely nearby. It's rechecked
  every 30 seconds and needs two scans in a row to agree, so it reacts in
  about a minute. Anyone can broadcast any network name, so don't use an
  in-range rule for a profile that would be unsafe on the wrong network (a
  DNS server that only exists at home, say).
- **Ethernet connected** matches any wired connection.

A profile that joins a Wi-Fi network only tries when that network is in range,
so switching to it elsewhere never drops your current connection.

## Scripting

The service registers an IPC target:

```bash
omarchy-shell io.github.mindows.mib-nprofiles list          # profiles, * marks the active one
omarchy-shell io.github.mindows.mib-nprofiles current       # active profile name
omarchy-shell io.github.mindows.mib-nprofiles use Home      # switch, like a click
omarchy-shell io.github.mindows.mib-nprofiles auto on       # on | off | resume
omarchy-shell io.github.mindows.mib-nprofiles state         # what's applied where, and the last error
omarchy-shell io.github.mindows.mib-nprofiles refresh       # re-read NetworkManager now
```

## Settings

Everything is managed in the popup and stored on the widget's entry in
`~/.config/omarchy/shell.json`:

```json
{
  "id": "io.github.mindows.mib-nprofiles",
  "autoSwitch": true,
  "notify": true,
  "fallbackProfile": "automatic",
  "profiles": [
    {
      "id": "p1a2b3c",
      "name": "Home",
      "ipv4": { "mode": "", "address": "", "gateway": "", "device": "wifi" },
      "dns": ["192.168.1.2"],
      "search": ["lan"],
      "ipv6": "",
      "wifi": null,
      "vpn": null
    }
  ],
  "rules": [
    { "when": "wifi", "ssid": "mk", "profile": "p1a2b3c" }
  ]
}
```

Hand-editing is safe: the entry is re-validated on load, and anything
malformed (a bad address, a rule pointing at a missing profile) is dropped
rather than passed to NetworkManager. `ipv4.mode` is `""` (as saved), `dhcp`
or `manual`; `ipv6` is `""` or `off`; `when` is `wifi`, `inrange` or
`ethernet`. The widget also keeps `activeProfile` and `pinnedNetwork` there
so the active profile survives a restart.

## Privacy

- The widget makes **no network requests**. It reads NetworkManager state and
  runs `nmcli`.
- Addresses, DNS servers and connection IDs are passed to `nmcli` as
  arguments, so they appear in the process list for a moment. Any local user
  can already read the same values from NetworkManager, so nothing new is
  disclosed. Notifications name the Wi-Fi network that triggered a switch.
- Profiles and rules live only in `~/.config/omarchy/shell.json`.

## Update

```bash
omarchy plugin update io.github.mindows.mib-nprofiles
```

## Remove

Switch to **Automatic** first, then:

```bash
omarchy plugin remove io.github.mindows.mib-nprofiles
```

Removing deletes the widget's settings with its bar entry. Settings a profile
had applied last until the device next reconnects.

## Troubleshooting

- **DNS doesn't change:** check for an `omarchy dns` override (the popup warns
  about it), and run `resolvectl dns` to see what each link uses.
- **A switch failed:** the popup shows the last error, and `state` (above)
  prints it with what's applied to each device.
- **The icon doesn't appear:** `omarchy plugin list` to check it's enabled,
  then `omarchy restart shell`.

## Development

```bash
git clone https://github.com/mindows/mib-nprofiles.git ~/dev/mib-nprofiles
ln -s ~/dev/mib-nprofiles ~/.config/omarchy/plugins/io.github.mindows.mib-nprofiles
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.mindows.mib-nprofiles
```

After changing `Service.qml`, run `omarchy restart shell`: a running service
is kept across plugin reloads. `Model.js` holds all the logic that doesn't
need QML, and has tests:

```bash
node --test tests/
omarchy plugin validate .
```

| File | Role |
|---|---|
| `manifest.json` | plugin declaration |
| `Service.qml` | the single engine: watches NetworkManager, evaluates rules, applies profiles, IPC |
| `Panel.qml` | bar icon and popup (list, settings, editor); one per monitor |
| `Runner.qml` | runs `nmcli` commands one at a time |
| `Model.js` | parsing, validation, settings shape, nmcli arguments, rules |
| `tests/` | node tests for `Model.js` |

## License

[MIT](LICENSE)
