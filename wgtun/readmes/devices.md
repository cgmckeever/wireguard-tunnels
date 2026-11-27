# devices/ (wireguard-tunnels)

One folder per device that runs tunnels: this Mac, or a sing-box device such
as an iPhone. [wireguard-tunnels](https://github.com/cgmckeever/wireguard-tunnels)
reads them (`tunnel.sh` for this Mac, `singbox.sh` for the others):

- `<device>/carriers/`: carrier configs from your provider or server; each
  becomes a warped tunnel (WARP inside it) in `config/`.
- `<device>/config/`: every tunnel, one `.conf` each.
- `<device>/warp/`: the device's own WARP account.
- `<device>/exports/`, `<device>/sing-box/`: WireGuard app zips, and the
  sing-box profiles built for the device.
- `.default`: this Mac's device name.

They hold private keys. `check.sh` checks them and changes nothing.

wireguard-tunnels writes this file when it's missing, and never changes it.
