# KoDNS

Get past ISP DNS blocking in KOReader with DNS-over-HTTPS.

## Why you need this

Before your device can open a site, it asks a DNS server for the site's IP address. Many ISPs block sites at that step: their DNS server gives back a block page address, or no answer at all, for any domain on the block list.

The usual fix is to change the DNS server to 1.1.1.1 or 8.8.8.8. That does not work on some networks, for example FPT in Vietnam. FPT intercepts all DNS traffic on port 53, whatever server it is addressed to, and answers it with its own resolver. You can see this on a Kindle without KoDNS:

```
nslookup whoami.akamai.net
```

`whoami.akamai.net` returns the IP of the resolver that really asked for it. On FPT this is `118.70.115.58`, FPT's own resolver, even if you set another DNS server. As long as DNS goes out as plain port 53 traffic, the ISP can see it and answer it.

DNS-over-HTTPS (DoH) sends the same queries inside an encrypted HTTPS connection on port 443. The ISP sees only an HTTPS connection to 1.1.1.1 (or Google, or Quad9). It cannot read or rewrite the queries inside, so it cannot block them that way.

A Kindle has no DNS settings, no DoH support and no VPN app, so the stock firmware cannot do this. KoDNS adds it, using the root access a jailbreak gives you.

KoDNS fixes DNS blocking only. If the ISP blocks a site by its IP address or by inspecting the HTTPS connection, KoDNS cannot help.

## What it does

KoDNS runs AdGuard dnsproxy on the device, listening on 127.0.0.1:53, and sends every query over HTTPS to Cloudflare, Google, Quad9 or AdGuard. The ISP only sees HTTPS traffic to those servers.

- The DoH servers are given by IP address, so no plain DNS lookup is needed to find them.
- `/etc/resolv.conf` is pointed at 127.0.0.1 with a read-only bind mount of `/tmp/kodns-resolv.conf`, so the wifi scripts cannot overwrite it.
- The change is system-wide: the Kindle browser and other apps keep using it after you leave KOReader.
- Nothing is written to the root filesystem and no startup jobs are added. A reboot restores the stock DNS.
- All logic is in `kodns.sh`, a POSIX shell script that runs without KOReader. The KOReader plugin is only a menu on top of it.

Temp files: `/tmp/kodns.log`, `/tmp/kodns.pid`, `/tmp/kodns.provider`, `/tmp/kodns-resolv.conf`.

Providers:

| Name       | DoH endpoints                                                 |
|------------|---------------------------------------------------------------|
| auto       | fastest of cloudflare, google and quad9 (default)             |
| cloudflare | https://1.1.1.1/dns-query, https://1.0.0.1/dns-query          |
| google     | https://8.8.8.8/dns-query, https://8.8.4.4/dns-query          |
| quad9      | https://9.9.9.9/dns-query, https://149.112.112.112/dns-query  |
| adguard    | https://dns.adguard-dns.com/dns-query, bootstrap over DoH to 1.1.1.1 (blocks ads) |

## Install

You need:

- A jailbroken Kindle with KOReader installed and working.
- A computer and a USB cable.
- Optional: kterm or SSH access, for the terminal tests below.

### Easy way: download the ready-made zip

Download **https://github.com/whooslizi/KoDNS/releases/latest/download/kodns.koplugin.zip** (no GitHub account needed).

It is built automatically and already contains the latest dnsproxy arm7 binary, so you do not need to download dnsproxy yourself. Unzip it and continue from step 5 of the manual way below.

### Manual way

1. Download this repository (on GitHub: Code, then Download ZIP) and unzip it. You need the `kodns.koplugin` folder from it.
2. Open https://github.com/AdguardTeam/dnsproxy/releases and download `dnsproxy-linux-arm7-vX.Y.Z.tar.gz` from the latest release. Use the arm7 build, not arm64 or arm6.
3. Extract the archive (7-Zip on Windows, double click on macOS, `tar xzf` on Linux). Inside is a `linux-arm7` folder with a file named `dnsproxy`.
4. Put that file into `kodns.koplugin/bin/` so the path is `kodns.koplugin/bin/dnsproxy`. Keep the name exactly `dnsproxy`, with no extension.
5. Connect the Kindle over USB. Copy the whole `kodns.koplugin` folder into `koreader/plugins/` on the Kindle drive (`/mnt/us/koreader/plugins/` on the device). It should look like this:

   ```
   koreader/plugins/kodns.koplugin/
       _meta.lua
       main.lua
       kodns.sh
       README.md
       bin/dnsproxy
   ```

6. Eject the Kindle safely and unplug it.
7. Start KOReader, or restart it if it was running. Open the top menu, then the tools (wrench) tab. KoDNS is listed in the Network section, in both the file manager and the reader.
8. Optional: run Run diagnostics once with KoDNS off. Checks 1 to 6 should pass. If `dnsproxy runs` fails, you have the wrong build.
9. Tap Enable KoDNS and choose a provider (Auto is a good default). Then tap Check: the owner should be Cloudflare, Google or Quad9, not your ISP.

If the log shows certificate errors (`x509: certificate signed by unknown authority`), download `cacert.pem` from https://curl.se/docs/caextract.html and put it at `kodns.koplugin/bin/cacert.pem`. KoDNS uses it automatically when it is there.

## How the automatic build works

`.github/workflows/build.yml` does the dnsproxy download for you:

1. Finds the latest release of AdguardTeam/dnsproxy and downloads `dnsproxy-linux-arm7-vX.Y.Z.tar.gz`.
2. Checks that the binary is a 32-bit ARM executable and stops if it is not.
3. Copies `kodns.koplugin`, puts the binary at `bin/dnsproxy` and this README inside, and zips it as `kodns.koplugin.zip`.
4. On every push it uploads the zip as a build artifact (for testing, sign-in required, deleted after 90 days).
5. When a version tag is pushed, it publishes the zip as a GitHub Release, which is what the download link above points to.

To publish a new version (for example after a new dnsproxy release):

```
git tag v1.0.1
git push origin v1.0.1
```

Do not commit `bin/dnsproxy` to the repository; the build adds it.

## Menu

- **Enable KoDNS**: turns KoDNS on or off. When on, the label shows the provider in use, for example "Enable KoDNS (cloudflare)". If no provider is saved, or "Ask which provider every time" is on, you are asked to choose one first.
- **Provider**: Auto, Cloudflare, Google, Quad9 or AdGuard. Changing it while KoDNS is on restarts KoDNS with the new provider.
- **Ask which provider every time**: show the provider list every time you enable KoDNS.
- **Start with KOReader**: start KoDNS 3 seconds after KOReader starts, once per session, if it is not already running. Uses Auto if no provider is saved.
- **Check**: shows which resolver really answers your lookups and who owns it. "Still using ISP DNS" means the ISP is still answering.
- **Run diagnostics**: runs every check and lists PASS, FAIL or SKIP for each.
- **Benchmark providers**: TLS connect time to each provider in ms.
- **Show log**: the last lines of the dnsproxy log.

## Uninstall

1. Turn KoDNS off in the menu (or reboot the Kindle).
2. Delete `/mnt/us/koreader/plugins/kodns.koplugin`.
3. Restart KOReader.

## Testing from the terminal

Run these in kterm or over SSH, as root.

```
sh /mnt/us/koreader/plugins/kodns.koplugin/kodns.sh doctor
```
One line per check. With KoDNS off, checks 1 to 6 should be `[PASS]` (curl may be `[WARN]`), the rest `[SKIP] KoDNS is off`. With KoDNS on, all lines should be `[PASS]` and the last line is `Result: N passed, 0 failed`.

```
sh /mnt/us/koreader/plugins/kodns.koplugin/kodns.sh start auto
```
`ON via cloudflare (auto, 42 ms)` or similar. On failure it prints `FAILED: <reason>` and the last log lines, undoes everything and exits non-zero.

```
sh /mnt/us/koreader/plugins/kodns.koplugin/kodns.sh status
```
`proxy=up provider=cloudflare dns=127.0.0.1`. When off: `proxy=down provider=none dns=<ISP or router address>`.

```
sh /mnt/us/koreader/plugins/kodns.koplugin/kodns.sh check
```
The raw nslookup output, then `Resolver: <ip> (AS13335 Cloudflare, Inc.)` or the Google (AS15169) or Quad9 (AS19281) equivalent. Wrong: `Resolver: 118.70.115.58 (AS18403 FPT Telecom Company)` followed by `Still using ISP DNS`.

```
sh /mnt/us/koreader/plugins/kodns.koplugin/kodns.sh bench
```
```
cloudflare: 38 ms
google: 45 ms
quad9: 120 ms
adguard: 90 ms
```
`unreachable` means that provider could not be reached within 4 seconds.

```
sh /mnt/us/koreader/plugins/kodns.koplugin/kodns.sh stop
```
`OFF`. `/etc/resolv.conf` is back to the stock nameserver.

### Manual checks without the script

| Command | Correct result |
|---------|----------------|
| `cat /etc/resolv.conf` | `nameserver 127.0.0.1` |
| `grep resolv /proc/mounts` | one line for the resolv.conf target with `ro` in its options |
| `pgrep -f dnsproxy` | a PID |
| `nslookup example.com 127.0.0.1` | an address for example.com |
| `nslookup whoami.akamai.net` | a Cloudflare, Google or Quad9 resolver IP, not 118.70.115.58 (FPT) |
| `nslookup wattpad.com` | a real public address, not 0.0.0.0, 127.x, 10.x or 192.168.x |
| `tail /tmp/kodns.log` | no errors |

## Troubleshooting

| Doctor FAIL line | Meaning | Fix |
|------------------|---------|-----|
| `Root: running as uid N` | Not root, cannot mount or bind port 53 | Run as root. KOReader on a jailbroken Kindle already is. |
| `dnsproxy binary: missing` | `bin/dnsproxy` not found | Download the linux-arm7 build and put it at `kodns.koplugin/bin/dnsproxy`. |
| `dnsproxy binary: not executable` | File has no execute bit | `chmod +x bin/dnsproxy` |
| `dnsproxy runs: cannot execute on this CPU` | Wrong build (arm64, amd64, or a corrupt download) | Use `dnsproxy-linux-arm7`, take `linux-arm7/dnsproxy` from the archive. |
| `Network: no TLS connection to 1.1.1.1:443` | No internet, or HTTPS to 1.1.1.1 is blocked | Turn wifi on, check the connection, try again. |
| `DoH <provider>: unreachable` | That provider cannot be reached | Pick another provider or use Auto. |
| `dnsproxy process: not running` | dnsproxy died after start | Run `stop` then `start`, read `log`. |
| `Listening 127.0.0.1:53: nothing` | dnsproxy could not bind port 53 | Check the log for "address already in use" or permission errors. |
| `dnsproxy answers: no answer from 127.0.0.1` | dnsproxy runs but cannot reach its upstream | Check the log. For `x509` errors add `bin/cacert.pem` (see Install). Otherwise try another provider. |
| `resolv.conf mount: ... not bind mounted` | The mount was removed | Turn KoDNS off and on again. |
| `resolv.conf mount: ... not read-only` | The read-only remount failed | Turn KoDNS off and on again. |
| `System resolver: <ip>` | `/etc/resolv.conf` does not point at 127.0.0.1 | Turn KoDNS off and on again. |
| `System lookup: no answer` | Normal lookups fail | Fix the failing lines above it first. |
| `Resolver identity: ... still using ISP DNS` | Lookups still reach the ISP resolver | Check `System resolver` and `resolv.conf mount`; restart KoDNS. |
| `Resolver identity: whoami.akamai.net did not resolve` | Lookups fail entirely | Fix the failing lines above it first. |
| `Blocked site: wattpad.com -> ...` | Blocked or no answer, or the ISP block page | Make sure every line above passes; try another provider. |

## Compatibility

Tested on a jailbroken Kindle only. It might work on other KOReader devices with the matching dnsproxy binary for their CPU.
