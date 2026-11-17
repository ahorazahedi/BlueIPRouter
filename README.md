# BlueIPRouter

A native macOS app for choosing how traffic leaves your Mac, one destination at a time. Send a domain or IP straight out of Wi-Fi past a full-tunnel VPN, send a network through a site VPN, and block chosen services if the VPN drops. It does this in the kernel routing table and the built-in `pf` firewall, so your VPN client's configuration is never touched.

Built with SwiftUI. Requires macOS 14 or later.

## Features

| Screen | What it does |
|---|---|
| **Dashboard** | Your public IPv4 and IPv6 with location, ISP, time zone and coordinates. The public IP each path exits with (default path, Wi-Fi, site VPN). Local IP, which interface carries internet traffic, rule health, live traffic per interface |
| **Routing Rules** | Rules made of IPv4 hosts, CIDR networks or domain names. Each rule sends traffic through an interface's router, directly on an interface, or to a specific gateway. Each is persistent or lasts until reboot. You can also mark a rule to leave its routes in place when it is removed |
| **Kill Switch** | Uses `pf` to block either the services you choose or everything except what you allow, on interfaces you choose (e.g. Wi-Fi). Traffic can then only leave through the VPN tunnel. Includes a Telegram preset you can update from its source, custom lists, and detection of VPN servers (xray, sing-box, OpenVPN, …) |
| **Routing Table** | The live kernel routing table (IPv4 and IPv6), filters, the owner of each route, a legend for route flags, delete a route, add a one-off route, import static routes created elsewhere as rules |
| **Path Check** | Enter an IP or domain to see the DNS answers, the route the kernel uses, the interface and gateway, why that route matched, whether the kill switch blocks it, a TCP test and a live traceroute |
| **Network Adapters** | Addresses, MAC, router, DNS, traffic counters and aliases per interface. Turn an interface up or down, Wi-Fi power, renew DHCP, set the MTU, set DNS servers, flush the DNS cache |
| **Persistence** | A background LaunchDaemon that re-applies everything at boot and on a schedule: it re-resolves domains, follows router changes and repairs missing routes |
| **Backup & Restore** | Export and import JSON, automatic snapshots (after every Apply and before every restore or reset), and reset to default |

## Install

```sh
git clone https://github.com/ahorazahedi/BlueIPRouter.git && cd BlueIPRouter
sh scripts/build.sh --install     # builds and copies BlueIPRouter.app to ~/Applications
```

You need the Xcode command-line tools (Swift 5.10 or newer). Other build options:

```sh
sh scripts/build.sh                              # build/BlueIPRouter.app only
sh scripts/build.sh --zip                        # also build/BlueIPRouter-<version>.zip
BUNDLE_ID=com.example.blueiprouter sh scripts/build.sh   # use your own bundle identifier
```

The build is ad-hoc signed. If you download a build from Releases, macOS Gatekeeper may block it. Right-click the app and choose **Open**, or build it yourself.

## How it works

```
BlueIPRouter.app (runs as you)          blueiprouter-helper (runs as root)
 ├─ edits rules as a draft               ├─ resolves domains, finds interface routers
 ├─ Apply → admin prompt ───────────────►├─ adds / repairs / removes its own routes
 │   copies rules to root-owned files    ├─ loads the kill switch into pf anchor com.apple/blueiprouter
 └─ reads status back                    └─ writes status JSON
                                          ▲
     LaunchDaemon com.blueiprouter.helper ┘ (optional: at boot + every N seconds)
```

* **Apply** (⌘↩) asks for your administrator password through the standard macOS prompt. macOS reuses that approval for a few minutes.
* The helper only removes routes it installed itself. Routes from VPN clients and the system are never removed.
* Persistent rules are stored in `/Library/Application Support/BlueIPRouter/`. Until-reboot rules are stored in `/var/run/blueiprouter/`, which macOS clears at boot.
* The kill switch lives in its own `pf` anchor (`com.apple/blueiprouter`), which the stock `/etc/pf.conf` already evaluates. `/etc/pf.conf` is never edited.
* Helper log: `/var/log/blueiprouter.log`. App data (rule drafts, snapshots): `~/Library/Application Support/BlueIPRouter/`.

### Files on disk

| Path | Owner | Purpose |
|---|---|---|
| `/Library/PrivilegedHelperTools/com.blueiprouter.helper` | root | helper binary |
| `/Library/LaunchDaemons/com.blueiprouter.helper.plist` | root | background service (optional) |
| `/Library/Application Support/BlueIPRouter/*.json` | root | persistent rules, kill switch, DNS cache, learned VPN servers |
| `/var/run/blueiprouter/*` | root | until-reboot rules, applied state, status, pf rules |

**Reset to Default** (Backup & Restore) removes all of these.

## Security

* The helper runs every tool with an argument list. Nothing goes through a shell.
* Interface names, IPs, CIDRs and domains are validated before use.
* The helper only reads files that are owned by root and writable only by root. Changing rules always requires an administrator password.
* Public IP checks send a plain HTTPS request to `api.ipify.org` and `api6.ipify.org`. Location lookups send the IP address to `ipinfo.io` or `ipwho.is` (choose in Settings). Nothing else leaves your Mac.

## Diagnostics

Neither command changes anything, and neither needs root:

```sh
/Applications/BlueIPRouter.app/Contents/MacOS/BlueIPRouter --selftest
/Applications/BlueIPRouter.app/Contents/MacOS/blueiprouter-helper plan rules.json
```

`--selftest` prints interface detection, path analysis, a `pf` syntax check of the generated kill-switch rules, and your public IPs. Please include its output in bug reports. Remove any addresses you don't want to share first.

## Limits

* Routing rules are IPv4. The kill switch, routing table and path check also handle IPv6.
* A domain rule routes the IPs that domain resolves to. If the domain sits behind a CDN, other sites on the same IPs follow the rule too.
* Routes added with **Add Route** in the routing table are one-off and are never restored.
* Apps can't pin traffic to some tunnel interfaces, so the public IP of those paths can't be measured directly.

## License

MIT — see [LICENSE](LICENSE).
