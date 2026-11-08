#!/bin/sh
# KoDNS: send all system DNS through a local dnsproxy that speaks DNS-over-HTTPS.
# POSIX sh, runs on BusyBox. Works without KOReader; the plugin is only a front end.

DIR=$(cd "$(dirname "$0")" && pwd)
BIN="$DIR/bin/dnsproxy"
LOG=/tmp/kodns.log
PIDF=/tmp/kodns.pid
PROVF=/tmp/kodns.provider
RESOLV=/tmp/kodns-resolv.conf
ISP='FPT|Viettel|VNPT'
AUTO_LIST="cloudflare google quad9"
ALL="cloudflare google quad9 adguard"

# Go needs CA roots for HTTPS; use a bundled file if the system has none.
[ -f "$DIR/bin/cacert.pem" ] && export SSL_CERT_FILE="$DIR/bin/cacert.pem"

upstreams() {
    case $1 in
        cloudflare) echo "-u https://1.1.1.1/dns-query -u https://1.0.0.1/dns-query" ;;
        google) echo "-u https://8.8.8.8/dns-query -u https://8.8.4.4/dns-query" ;;
        quad9) echo "-u https://9.9.9.9/dns-query -u https://149.112.112.112/dns-query" ;;
        # bootstrap over DoH as well: plain port 53 to 1.1.1.1 is hijacked by the ISP
        adguard) echo "-u https://dns.adguard-dns.com/dns-query -b https://1.1.1.1/dns-query" ;;
        *) return 1 ;;
    esac
}

has_curl() { command -v curl >/dev/null 2>&1; }

# Print the TLS connect time to a provider in ms; fail if unreachable.
tls_ms() {
    case $1 in
        cloudflare) set -- https://1.1.1.1/dns-query ;;
        google) set -- https://8.8.8.8/dns-query ;;
        quad9) set -- https://9.9.9.9/dns-query ;;
        # shortcut: AdGuard IP is hardcoded so the probe needs no DNS, update it if AdGuard changes it
        adguard) set -- https://dns.adguard-dns.com/dns-query --resolve dns.adguard-dns.com:443:94.140.14.14 ;;
        *) return 1 ;;
    esac
    # -k: only the handshake is timed; an old Kindle CA bundle must not make it fail
    t=$(curl -k -s -o /dev/null -m 4 -w '%{time_appconnect}' "$@") || return 1
    awk -v t="$t" 'BEGIN { if (t + 0 > 0) printf "%d\n", t * 1000 + 0.5; else exit 1 }'
}

# PID from the PID file, only if that process really is dnsproxy.
proxy_pid() {
    p=$(cat "$PIDF" 2>/dev/null)
    case $p in '' | *[!0-9]*) return 1 ;; esac
    tr '\0' ' ' 2>/dev/null <"/proc/$p/cmdline" | grep -q dnsproxy || return 1
    echo "$p"
}

# Every process started from our binary, PID file or not.
scan_pids() {
    for d in /proc/[0-9]*; do
        c=$(tr '\0' ' ' 2>/dev/null <"$d/cmdline")
        case $c in "$BIN "*) echo "${d#/proc/}" ;; esac
    done
}

target() { readlink -f /etc/resolv.conf; }

# Mount options of the top-most mount at $1; fail if nothing is mounted there.
mount_opts() { awk -v t="$1" '$2 == t { o = $4 } END { if (o) print o; else exit 1 }' /proc/mounts 2>/dev/null; }

first_ns() { awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf 2>/dev/null; }

# First IPv4 address in the answer section of nslookup output on stdin.
# Old BusyBox: "Address 1: 1.2.3.4 host". New BusyBox: "Address: 1.2.3.4".
answer_ip() {
    awk '/^Name:/ { a = 1; next }
        a && /^Address/ { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit } }'
}

lookup() { nslookup "$@" 2>&1 | answer_ip; }

owner() { curl -s -m 6 "https://ipinfo.io/$1/org"; }

bad_ip() {
    case $1 in
        '' | 0.0.0.0 | 127.* | 10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;
    esac
    return 1
}

is_on() { [ -f "$PIDF" ] || mount_opts "$(target)" >/dev/null; }

# Undo everything except the log.
cleanup() {
    T=$(target)
    # shortcut: assumes any mount on the resolv.conf target is ours (stock Kindle has none there)
    while mount_opts "$T" >/dev/null; do
        umount "$T" 2>/dev/null || umount -l "$T" 2>/dev/null || break
    done
    pids="$(proxy_pid) $(scan_pids)"
    # shellcheck disable=SC2086
    if [ -n "${pids# }" ]; then
        kill $pids 2>/dev/null
        i=0
        while [ -n "$(scan_pids)" ] && [ $i -lt 3 ]; do sleep 1; i=$((i + 1)); done
        left=$(scan_pids)
        [ -n "$left" ] && kill -9 $left 2>/dev/null
    fi
    rm -f "$PIDF" "$PROVF" "$RESOLV"
}

die() {
    echo "FAILED: $1"
    echo "--- last log lines ---"
    tail -n 5 "$LOG" 2>/dev/null
    cleanup
    exit 1
}

cmd_start() {
    want=${1:-auto}
    upstreams "$want" >/dev/null || [ "$want" = auto ] || { usage; exit 2; }
    if [ ! -x "$BIN" ]; then
        echo "FAILED: $BIN is missing or not executable"
        exit 1
    fi
    cleanup
    : >"$LOG"

    prov=$want note=
    if [ "$want" = auto ]; then
        if has_curl; then
            best='' best_ms=''
            for p in $AUTO_LIST; do
                ms=$(tls_ms "$p") || continue
                if [ -z "$best_ms" ] || [ "$ms" -lt "$best_ms" ]; then best=$p best_ms=$ms; fi
            done
            [ -n "$best" ] || die "no provider reachable over HTTPS (is wifi on?)"
            prov=$best note=" (auto, $best_ms ms)"
        else
            prov=cloudflare note=" (auto, curl missing)"
        fi
    fi

    # setsid: survive KOReader exiting; no inherited stdout so io.popen returns
    run='nohup'
    command -v setsid >/dev/null 2>&1 && run=setsid
    # shellcheck disable=SC2046
    $run "$BIN" -l 127.0.0.1 -p 53 --cache $(upstreams "$prov") </dev/null >>"$LOG" 2>&1 &

    i=0 pid='' ip=''
    while [ $i -lt 6 ]; do
        sleep 1
        i=$((i + 1))
        pid=$(scan_pids | head -n 1)
        [ -n "$pid" ] || die "dnsproxy exited right after starting"
        ip=$(lookup example.com 127.0.0.1)
        [ -n "$ip" ] && break
    done
    [ -n "$ip" ] || die "dnsproxy does not answer on 127.0.0.1:53"
    echo "$pid" >"$PIDF"
    echo "$prov" >"$PROVF"

    T=$(target)
    [ -f "$T" ] || die "resolv.conf target $T does not exist"
    echo "nameserver 127.0.0.1" >"$RESOLV"
    mount -o bind "$RESOLV" "$T" || die "bind mount over $T failed"
    mount -o remount,ro,bind "$T" || die "read-only remount of $T failed"
    case ",$(mount_opts "$T")," in *,ro,*) ;; *) die "$T is not mounted read-only" ;; esac
    [ "$(first_ns)" = 127.0.0.1 ] || die "/etc/resolv.conf does not point at 127.0.0.1"
    echo "ON via $prov$note"
}

cmd_stop() {
    cleanup
    rm -f "$LOG"
    echo "OFF"
}

cmd_status() {
    st=down
    proxy_pid >/dev/null && st=up
    echo "proxy=$st provider=$(cat "$PROVF" 2>/dev/null || echo none) dns=$(first_ns)"
}

cmd_check() {
    out=$(nslookup whoami.akamai.net 2>&1)
    printf '%s\n\n' "$out"
    ip=$(printf '%s\n' "$out" | answer_ip)
    if [ -z "$ip" ]; then
        echo "Resolver: no answer"
        return 1
    fi
    if ! has_curl; then
        echo "Resolver: $ip"
        return 0
    fi
    org=$(owner "$ip")
    echo "Resolver: $ip (${org:-owner unknown})"
    if printf '%s' "$org" | grep -qiE "$ISP"; then echo "Still using ISP DNS"; fi
    return 0
}

cmd_bench() {
    has_curl || { echo "curl not found, cannot benchmark"; return 1; }
    for p in $ALL; do
        if ms=$(tls_ms "$p"); then echo "$p: $ms ms"; else echo "$p: unreachable"; fi
    done
}

cmd_log() {
    if [ -s "$LOG" ]; then tail -n 15 "$LOG"; else echo "Log is empty"; fi
}

cmd_doctor() {
    P=0 F=0
    ok() { echo "[PASS] $1"; P=$((P + 1)); }
    bad() { echo "[FAIL] $1"; F=$((F + 1)); }
    skip() { echo "[SKIP] $1"; }

    if [ "$(id -u)" = 0 ]; then ok "Root: running as root"
    else bad "Root: running as uid $(id -u); run as root (KOReader on a jailbroken Kindle does)"; fi

    if [ -x "$BIN" ]; then ok "dnsproxy binary: $BIN"
    elif [ -f "$BIN" ]; then bad "dnsproxy binary: not executable; run chmod +x $BIN"
    else bad "dnsproxy binary: missing; put the linux-arm7 build from github.com/AdguardTeam/dnsproxy/releases at $BIN"; fi

    if [ ! -x "$BIN" ]; then bad "dnsproxy runs: binary missing, see the line above"
    elif v=$("$BIN" --version 2>&1); then ok "dnsproxy runs: $(printf '%s' "$v" | head -n 1)"
    else bad "dnsproxy runs: cannot execute on this CPU; use the dnsproxy-linux-arm7 build"; fi

    if has_curl; then ok "curl: $(command -v curl)"
    else echo "[WARN] curl: not found; auto falls back to cloudflare, check shows no owner, bench and network tests are skipped"; fi

    if ! has_curl; then skip "Network: curl missing"
    elif ms=$(tls_ms cloudflare); then ok "Network: TLS to 1.1.1.1:443 in $ms ms"
    else bad "Network: no TLS connection to 1.1.1.1:443 in 4 s; turn wifi on and check the connection"; fi

    for p in $ALL; do
        if ! has_curl; then skip "DoH $p: curl missing"
        elif ms=$(tls_ms "$p"); then ok "DoH $p: $ms ms"
        else bad "DoH $p: unreachable; pick another provider"; fi
    done

    if ! is_on; then
        for c in "dnsproxy process" "Listening 127.0.0.1:53" "dnsproxy answers" "resolv.conf mount" \
            "System resolver" "System lookup" "Resolver identity" "Blocked site"; do
            skip "$c: KoDNS is off"
        done
    else
        if pid=$(proxy_pid); then ok "dnsproxy process: PID $pid"
        else bad "dnsproxy process: not running; run stop then start and read the log"; fi

        if command -v netstat >/dev/null 2>&1; then
            netstat -lnu 2>/dev/null | grep -q '127\.0\.0\.1:53 ' && l=1 || l=
        else
            grep -qi ' 0100007F:0035 ' /proc/net/udp 2>/dev/null && l=1 || l=
        fi
        if [ -n "$l" ]; then ok "Listening 127.0.0.1:53: yes"
        else bad "Listening 127.0.0.1:53: nothing; dnsproxy failed to bind, see the log (port in use or not root)"; fi

        ip=$(lookup example.com 127.0.0.1)
        if [ -n "$ip" ]; then ok "dnsproxy answers: example.com -> $ip"
        else bad "dnsproxy answers: no answer from 127.0.0.1; see the log for upstream or certificate errors"; fi

        T=$(target)
        if ! o=$(mount_opts "$T"); then bad "resolv.conf mount: $T is not bind mounted; restart KoDNS"
        else
            case ",$o," in
                *,ro,*) ok "resolv.conf mount: $T ($o)" ;;
                *) bad "resolv.conf mount: $T is mounted but not read-only; restart KoDNS" ;;
            esac
        fi

        ns=$(first_ns)
        if [ "$ns" = 127.0.0.1 ]; then ok "System resolver: 127.0.0.1"
        else bad "System resolver: ${ns:-none}; the mount was lost, restart KoDNS"; fi

        ip=$(lookup example.com)
        if [ -n "$ip" ]; then ok "System lookup: example.com -> $ip"
        else bad "System lookup: no answer; check the two lines above"; fi

        ip=$(lookup whoami.akamai.net)
        if [ -z "$ip" ]; then bad "Resolver identity: whoami.akamai.net did not resolve"
        elif ! has_curl; then skip "Resolver identity: $ip (curl missing, owner unknown)"
        else
            org=$(owner "$ip")
            if [ -z "$org" ]; then skip "Resolver identity: $ip (ipinfo.io unreachable, owner unknown)"
            elif printf '%s' "$org" | grep -qiE "$ISP"; then bad "Resolver identity: $ip ($org); still using ISP DNS, DNS is not going through dnsproxy"
            else ok "Resolver identity: $ip ($org)"; fi
        fi

        ip=$(lookup wattpad.com)
        if bad_ip "$ip"; then bad "Blocked site: wattpad.com -> ${ip:-no address}; looks blocked, check the lines above"
        elif has_curl && owner "$ip" | grep -qiE "$ISP"; then bad "Blocked site: wattpad.com -> $ip is an ISP address (block page)"
        else ok "Blocked site: wattpad.com -> $ip"; fi
    fi

    echo "Result: $P passed, $F failed"
    [ "$F" -eq 0 ]
}

usage() {
    cat <<EOF
Usage: sh kodns.sh <command>
  start <auto|cloudflare|google|quad9|adguard>  start DNS-over-HTTPS (default auto)
  stop     stop and restore the stock DNS
  status   show proxy state, provider and current nameserver
  check    show which resolver answers your lookups
  bench    TLS connect time to each provider
  log      last 15 lines of $LOG
  doctor   run every diagnostic check
EOF
}

case $1 in
    start) cmd_start "$2" ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    check) cmd_check ;;
    bench) cmd_bench ;;
    log) cmd_log ;;
    doctor) cmd_doctor ;;
    *) usage; exit 2 ;;
esac
