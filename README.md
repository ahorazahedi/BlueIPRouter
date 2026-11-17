# BlueIPRouter

A native macOS app for choosing how traffic leaves your Mac, one destination at a time. Send a domain or IP straight out of Wi-Fi past a full-tunnel VPN, send a network through a site VPN, and block chosen services if the VPN drops. It does this in the kernel routing table and the built-in `pf` firewall, so your VPN client's configuration is never touched.

Built with SwiftUI. Requires macOS 14 or later.

## Features

| Screen | What it does |
|---|---|
| **Dashboard** | Your public IPv4 and IPv6 with location, ISP, time zone and coordinates. The public IP each path exits with (default path, Wi-Fi, site VPN). Local IP, which interface carries internet traffic, rule health, live traffic per interface |
| **Routing Rules** | Rules made of IPv4 hosts, CIDR networks or domain names. Each rule sends traffic through an interface's router, directly on an interface, or to a specific gateway. Each is persistent or lasts until reboot. You can also mark a rule to leave its routes in place when it is removed |
| **Kill Switch** | Uses `pf` to block either the services you choose or everything except what you allow, on interfaces you choose (e.g. Wi-Fi). Traffic can then only leave through the VPN tunnel. Includes a Telegram preset you can update from its source, custom lists, and detection of VPN servers (xray, sing-box, OpenVPN, …) |
| **Block List** | Blocks IPs, networks (IPv4/IPv6) or domains completely, on every interface, the VPN tunnel included. Connections are refused immediately. You can block straight from Connections or Path Check. Enforced with `pf` and kept across reboots |
| **Routing Table** | The live kernel routing table (IPv4 and IPv6), filters, the owner of each route, a legend for route flags, delete a route, add a one-off route, import static routes created elsewhere as rules |
| **Path Check** | Enter an IP or domain to see the DNS answers, the route the kernel uses, the interface and gateway, why that route matched, whether the kill switch blocks it, a TCP test and a live traceroute |
| **Network Adapters** | Addresses, MAC, router, DNS, traffic counters and aliases per interface. Turn an interface up or down, Wi-Fi power, renew DHCP, set the MTU, set DNS servers, flush the DNS cache |
| **Persistence** | A background service that re-applies everything at boot and on a schedule: it re-resolves domains, follows router changes and repairs missing routes. Startup switches for the service, Open at Login and the menu bar icon |
| **Menu bar** | Public IPv4/IPv6 with flag, location and ISP, live download/upload speed, egress interface, profile, kill switch and Apply, without opening the window. The bar can show an icon, the country flag, flag + IP, or live speed. The app keeps running there when its window is closed |
| **Speed Test** | Download, upload, ping, jitter and latency under load (bufferbloat) against Cloudflare (default) or LibreSpeed servers. Runs on the connection you pick: directly over Wi-Fi/Ethernet past the VPN (default), the system default path (e.g. through the VPN), or another interface. Shows the public IP of the tested path and keeps a history chart. Uses roughly 100–300 MB of data per test, and the app warns you first |
| **Connections** | Live list of which app talks to which address and through which interface, with a filter for traffic leaving outside the VPN tunnel |
| **Traffic** | Per-interface throughput charts (15 min to 7 days) and totals: how much goes through the VPN tunnel, Wi-Fi and other links |
| **Profiles** | Named sets of active rules (e.g. Home, Office, Travel), chosen by hand or automatically by the network you join (recognised by the router, no location permission needed), with an optional kill-switch setting per profile |
| **Automation** | Triggers that run in the background service when a full-tunnel VPN connects or drops, an interface goes up or down, internet traffic switches interface or you join another network: switch profile, force the kill switch, re-learn VPN servers, notify. Includes an event history |
| **DNS** | DNS leak test, the resolvers macOS uses and whether they are reached outside the VPN tunnel, and per-domain resolvers (`/etc/resolver`) |
| **Notifications** | Public IP/country changes, VPN drops and reconnects, kill switch changes, failing rules, network changes and new versions |
| **Updates** | Checks GitHub Releases once a day (or on demand) and offers the download |
| **Setup Assistant** | A first-run checklist: install the background service, open at login, menu bar icon, import existing static routes, create the first rule |
| **Backup & Restore** | Export and import JSON, automatic snapshots (after every Apply and before every restore or reset), and reset to default |

## Install

No Terminal needed.

1. Download `BlueIPRouter-<version>.zip` from the [latest release] (Apple Silicon; Intel Macs see *Build from source*)(https://github.com/ahorazahedi/BlueIPRouter/releases/latest) and unzip it.
2. Drag **BlueIPRouter.app** into **Applications**.
3. Open it. The first time, macOS may say it cannot verify the developer, because the app is not notarized. Click **Done**, then open **System Settings › Privacy & Security**, scroll down and click **Open Anyway** next to BlueIPRouter.
4. The **Setup Assistant** opens. Install the background service (one administrator password), choose whether the app opens at login, and import any static routes you already have.

From then on, everything is controlled from the app:

* **At boot:** the background service applies your rules and kill switch, even before you log in and when the app is closed. Switch it under **Persistence › Startup**.
* **At login:** turn on **Open BlueIPRouter at login** in the same place. If macOS asks for approval, it opens **System Settings › General › Login Items** for you.
* **Menu bar:** the icon shows status and quick actions. Closing the window keeps the app running there. You can turn the icon off.

To uninstall, open **Backup & Restore › Reset to Default**, turn on **Uninstall the background service and helper**, then delete the app.

### Build from source

You need the Xcode command-line tools (Swift 5.10 or newer).

```sh
git clone https://github.com/ahorazahedi/BlueIPRouter.git && cd BlueIPRouter
sh scripts/build.sh --install                     # builds and copies BlueIPRouter.app to ~/Applications
sh scripts/build.sh --zip                         # also creates build/BlueIPRouter-<version>.zip
BUNDLE_ID=com.example.blueiprouter sh scripts/build.sh   # use your own bundle identifier
UNIVERSAL=1 sh scripts/build.sh                  # Apple Silicon + Intel (Intel Macs: build it yourself)
```

Every push to `main` makes GitHub Actions build the app for Apple Silicon and publish it on the release named after the version in `Sources/BlueIPRouterCore/Models.swift`. If you bump that version, a new release is created. Otherwise the zip on the current release is replaced with the newest build.

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

## Author

Created by **Ahora Zahedi** · [GitHub](https://github.com/ahorazahedi) · [Website](https://ahora.bluedopmaine.io/)

## License

MIT — see [LICENSE](LICENSE).
