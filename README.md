# MIB nProfiles

An [Omarchy](https://omarchy.org/) plugin.

> **Status:** early development. Nothing to install yet.

## Requirements

- Omarchy, with its shell

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
