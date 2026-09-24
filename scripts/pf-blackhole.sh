#!/bin/sh
#
# pf-blackhole.sh — silently drop traffic to a SIP host for one observation window, then put
# pf back exactly as it was.
#
# This is the failure-injection lever for the call-lifecycle observation runs
# (`../Tests/CallLifecycleObservationTests.swift`). Those runs need a call's transport to die
# the way a real network death kills it, and nothing else on the machine to be disturbed.
# See `../docs/SIP-Test-Infrastructure.md` §7 for why pf and not the alternatives.
#
#   sudo ./pf-blackhole.sh all               # signalling AND media — a dead network
#   sudo ./pf-blackhole.sh udp               # RTP only, SIP/TCP signalling stays up
#   sudo ./pf-blackhole.sh tcp               # signalling only, RTP keeps flowing
#   sudo ./pf-blackhole.sh udp-reject        # RTP, but ICMP-unreachable back (a *loud* failure)
#   sudo ./pf-blackhole.sh all-reject        # everything, loudly
#   sudo ./pf-blackhole.sh all 1500 sip2sip.info
#
#   $1 mode     all | udp | tcp | udp-reject | all-reject   (default: all)
#   $2 seconds  hard cap on the block, always restores (default: 1500)
#   $3 host…    hostname or IP, repeatable            (default: sip.linphone.org)
#
# `block drop` is a silent discard: no RST, no ICMP unreachable. That is the point — anything
# sent back would be a notification, and the whole question is what happens when there is none.
#
# ## Choreography
#
# It does not block on launch. It waits for an *arm* file, blocks, then waits for a *release*
# file or the hard cap. So the driver (a test run, or you) controls the timing to the second,
# and you type your password once, up front, before the interesting part starts:
#
#   sudo ./pf-blackhole.sh all &      # asks for the password, then waits
#   …start the observation run, wait for its CALL-UP marker…
#   touch  /tmp/offhook-pf/arm        # block now
#   touch  /tmp/offhook-pf/release    # restore now (or let the cap do it)
#
# Arm *after* launching: startup clears any arm/release left by a previous run, so a stale file
# can never blackhole your network the moment you type the password.
#
# Override the run directory with OFFHOOK_PF_RUNDIR.
#
# ## Safety
#
# Restores on every exit path — release file, hard cap, Ctrl-C, SIGTERM. It reloads
# /etc/pf.conf and gives back the enable token it took, so pf ends disabled if it started
# disabled. If the machine dies mid-window, `sudo pfctl -f /etc/pf.conf && sudo pfctl -d`
# is the manual undo.

set -u

MODE="${1:-all}"
MAX_SECONDS="${2:-1500}"
if [ $# -gt 2 ]; then shift 2; HOSTS="$*"; else HOSTS="sip.linphone.org"; fi

RUNDIR="${OFFHOOK_PF_RUNDIR:-/tmp/offhook-pf}"
PRIV="$RUNDIR/root"
ARM="$RUNDIR/arm"
RELEASE="$RUNDIR/release"
STATE="$PRIV/state.log"
RULES="$PRIV/rules.conf"
TOKEN=""

log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$STATE"; }

restore() {
    [ -f "$RULES" ] || return 0
    log "RESTORE: reloading /etc/pf.conf"
    pfctl -f /etc/pf.conf 2>/dev/null
    if [ -n "$TOKEN" ]; then
        pfctl -X "$TOKEN" 2>/dev/null
        log "RESTORE: gave back enable token $TOKEN"
    fi
    rm -f "$RULES"
    log "RESTORE: done — $(pfctl -s info 2>/dev/null | head -1)"
    date '+%H:%M:%S' > "$PRIV/restored-at"
}

# EXIT first: any way out of the script — release, hard cap, `exit`, an untrapped signal's
# exit path — lands in restore(). The signal trap then only has to log and exit, and the
# EXIT trap does the restoring. HUP is the realistic case: launched as `sudo … &`, a dead
# terminal or parent shell is exactly how the block would otherwise outlive the run.
trap 'restore' EXIT
trap 'echo; log "INTERRUPTED"; exit 130' HUP INT TERM

[ "$(id -u)" = "0" ] || { echo "needs root: sudo $0 $MODE" >&2; exit 1; }

# `drop` discards silently — the peer's socket learns nothing, which is what a vanished network
# path looks like. `return` instead answers: TCP RST for TCP, ICMP unreachable for anything else.
# That distinction is not cosmetic. A blackholed UDP path raises **no** socket error, so pjmedia
# never generates PJMEDIA_EVENT_MEDIA_TP_ERR at all (observed 2026-08-18); the `-reject` modes
# exist to deliver an error that actually reaches pjmedia and find out what it does with one.
ACTION="drop"
case "$MODE" in
    all)        FILTER="" ;;
    udp)        FILTER="proto udp " ;;
    tcp)        FILTER="proto tcp " ;;
    udp-reject) FILTER="proto udp "; ACTION="return" ;;
    all-reject) FILTER="";           ACTION="return" ;;
    *)   echo "mode must be all | udp | tcp | udp-reject | all-reject" >&2; exit 1 ;;
esac

# World-writable on purpose: this script runs as root, but the thing that arms it is an
# unprivileged test driver. Left at root's default 0755 the driver's `touch` fails with
# EACCES — and a driver that does not check will happily report "armed" while nothing is
# blocked, which reads as a *stack* finding rather than a plumbing failure. (Cost us one
# 20-minute run, 2026-08-18.) Nothing secret lives here; it is arm/release flag files.
#
# Everything root *writes* lives one level down in a root-owned dir: predictable paths in a
# 1777 directory can be pre-created as symlinks by any local user, and root's `>`/`tee -a`
# would then truncate whatever they point at. The flags stay in $RUNDIR — being creatable by
# the unprivileged driver is their design, and a fake arm/release costs an early block or
# restore, not a file overwrite.
mkdir -p "$RUNDIR"
chmod 1777 "$RUNDIR"
if [ -e "$PRIV" ] && [ ! -O "$PRIV" ]; then
    echo "$PRIV exists and is not root-owned — refusing to use it" >&2
    exit 1
fi
mkdir -p "$PRIV"
chmod 700 "$PRIV"
rm -f "$ARM" "$RELEASE" "$PRIV/blocked-at" "$PRIV/restored-at"
: > "$STATE"

# Resolve through the *system* resolver. `dig` and `host` talk to a nameserver directly and
# time out behind a full-tunnel VPN; dscacheutil asks the same resolver the app does, so it
# returns what the stack will actually connect to.
IPS=""
for h in $HOSTS; do
    case "$h" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) resolved="$h" ;;
        *) resolved=$(dscacheutil -q host -a name "$h" | sed -n 's/^ip_address: *//p') ;;
    esac
    [ -n "$resolved" ] || { echo "cannot resolve $h" >&2; exit 1; }
    IPS="$IPS $resolved"
    log "target $h -> $resolved"
done

log "pf before: $(pfctl -s info 2>/dev/null | head -1)"
log "mode=$MODE max=${MAX_SECONDS}s"
log "waiting to be armed: touch $ARM"

# Generous: this counts from *launch*, and the driver still has to build, register, dial and
# establish a baseline before it arms. A tight window here expires mid-setup and the run silently
# becomes a no-op. The hard cap below is what bounds the actual block, so waiting long is free.
ARM_TIMEOUT="${OFFHOOK_PF_ARM_TIMEOUT:-3600}"
waited=0
while [ ! -f "$ARM" ]; do
    sleep 1
    waited=$((waited + 1))
    [ $((waited % 300)) -eq 0 ] && log "still waiting to be armed (${waited}s of ${ARM_TIMEOUT}s)"
    if [ "$waited" -gt "$ARM_TIMEOUT" ]; then
        log "never armed after ${ARM_TIMEOUT}s — exiting without touching pf"
        exit 0
    fi
done

# Keep Apple's ruleset (its anchors carry Internet Sharing / AirDrop rules) and append the
# blackhole as `quick`, so it wins wherever it is reached and restoring is just a reload of
# /etc/pf.conf. Both directions: an inbound packet from the host has *us* as its destination,
# so a `to` rule alone would let the peer keep talking to a socket we can no longer answer on.
cat /etc/pf.conf > "$RULES"
for ip in $IPS; do
    echo "block $ACTION quick ${FILTER}from $ip" >> "$RULES"
    echo "block $ACTION quick ${FILTER}to $ip"   >> "$RULES"
done

# A failed load must not print BLOCKED: `pfctl -f` failing while the script reports success
# produces a convincing *invalid* observation, which is worse than no run at all.
PFOUT=$(pfctl -f "$RULES" 2>&1)
if [ $? -ne 0 ]; then
    echo "$PFOUT" | grep -v '^$' | sed 's/^/  pf: /' | tee -a "$STATE"
    log "FATAL: pfctl -f failed — nothing is blocked; aborting before the driver can arm a no-op"
    exit 1
fi
[ -n "$PFOUT" ] && echo "$PFOUT" | grep -v '^$' | sed 's/^/  pf: /' | tee -a "$STATE"
TOKEN=$(pfctl -E 2>&1 | sed -n 's/.*Token : *\([0-9]*\).*/\1/p')
log "BLOCKED mode=$MODE token=${TOKEN:-none}"
date '+%H:%M:%S' > "$PRIV/blocked-at"

# Prove the block bit. pf must see the packets *before* they enter a VPN's utun interface,
# which is not obvious a priori — verified working through a full-tunnel VPN 2026-08-18, but
# re-check rather than assume: a reachable port here means the experiment is invalid, not that
# the stack under test is interesting.
for ip in $IPS; do
    if [ "$MODE" = "udp" ] || [ "$MODE" = "udp-reject" ]; then
        log "mode=$MODE: SIP/TCP to $ip left up by design (not probed)"
    elif nc -z -G 3 "$ip" 5060 2>/dev/null; then
        log "WARNING: $ip:5060 still reachable — THE BLOCK IS NOT WORKING, results are invalid"
    else
        log "verified: $ip:5060 unreachable from the host"
    fi
done

# Reachability can't verify a UDP-mode block (nc tests TCP), so verify the rules themselves:
# pf must show the two `quick` rules per target that the load was asked for.
for ip in $IPS; do
    LOADED=$(pfctl -s rules 2>/dev/null | grep -c " $ip ")
    if [ "$LOADED" -lt 2 ]; then
        log "WARNING: pf shows $LOADED block rule(s) for $ip, expected 2 — THE BLOCK IS NOT LOADED, results are invalid"
    fi
done

elapsed=0
while [ ! -f "$RELEASE" ] && [ "$elapsed" -lt "$MAX_SECONDS" ]; do
    sleep 5
    elapsed=$((elapsed + 5))
    [ $((elapsed % 60)) -eq 0 ] && log "still blocked, ${elapsed}s"
done
[ -f "$RELEASE" ] && log "released by driver after ${elapsed}s" \
                  || log "hard cap reached (${MAX_SECONDS}s)"

restore
