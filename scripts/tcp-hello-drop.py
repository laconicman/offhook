#!/usr/bin/env python3
#
# tcp-hello-drop.py — a TCP proxy that injects TLS-handshake stalls. This is the
# payload-level counterpart to pf-blackhole.sh: pf acts on packet headers, so it cannot cut
# a stream after N bytes, delay it, or fault the first connection after a pause and spare
# the retry. Those failures have to live in userspace. See docs/SIP-Test-Infrastructure.md §7.6.
#
# Faults (pick one):
#   --truncate N    forward the first N client bytes, swallow the rest. With N inside the
#                   ClientHello the server holds a partial record forever: a receiver that
#                   lost the tail of a hello split across TCP segments.
#   --truncate 0    forward nothing. The connection is up and the client's bytes go
#                   nowhere: the application-level view of a connection that a SYN proxy
#                   accepted with a zero window and never opened.
#   --rst-after N   forward the first N client bytes, then reset both sides.
#   --delay-ms N    delay every relayed chunk by N ms (a slow but honest path).
#   --pass          clean relay (control).
#
# Selection (optional, with a fault): which connections get it.
#   --first-after-idle S   only a connection that arrives at least S seconds after the
#                          previous one (the first one always qualifies). Models a box that
#                          treats the first contact from a source differently.
#   --fail-prob P          a qualifying connection gets the fault with probability P.
# Connections that are not selected are relayed cleanly.
#
#   python3 tcp-hello-drop.py --target sbc.example:5061 --truncate 0 --first-after-idle 300
#   python3 tcp-hello-drop.py --target sbc.example:5061 --truncate 1400 --fail-prob 0.3
#   python3 tcp-hello-drop.py --target 127.0.0.1:1443 --pass          # control
#
# Then point an account's registrar URI at `sip:<this-host>:15061;transport=tls`.
#
# Readout: each connection logs whether the fault was applied and how many bytes were
# forwarded and swallowed client→server.
#
# Semantics, honestly: the proxy ACKs the client's bytes locally before deciding their
# fate, so the client's TCP believes everything was delivered. A real middlebox drops or
# withholds at the packet level, where the client retransmits or sits in a zero window.
# At the TLS layer the result is the same stall — no ServerHello until the client's own
# handshake timeout — and that is the layer this script tests. Packet-level behaviour
# needs a packet-level emulator.

import argparse
import asyncio
import logging
import random
import socket
import sys
import time

CHUNK = 16384
DRAIN_TIMEOUT_S = 30  # bound on the surviving direction after a half-close
log = logging.getLogger("tcp-hello-drop")


class Policy:
    """Fault for one connection; an unselected one relays cleanly, like --pass."""
    def __init__(self, args, fault):
        self.truncate = args.truncate if fault else -1
        self.rst_after = args.rst_after if fault else -1
        self.delay_ms = args.delay_ms if fault else 0
        self.quota = (self.truncate if self.truncate >= 0 else
                      self.rst_after if self.rst_after >= 0 else -1)
        self.active = self.quota >= 0 or self.delay_ms > 0


async def relay(reader, writer, direction, quota, policy, conn_id):
    """Forward bytes. quota<0 = unlimited (server->client is always so)."""
    forwarded = 0
    dropped = 0
    announced = False
    try:
        while True:
            data = await reader.read(CHUNK)
            if not data:
                break
            if policy.delay_ms:
                await asyncio.sleep(policy.delay_ms / 1000)
            if quota >= 0 and forwarded + len(data) > quota:
                # The middlebox's cut falls inside this chunk.
                keep = max(0, quota - forwarded)
                if keep:
                    writer.write(data[:keep])
                    await writer.drain()
                forwarded += keep
                dropped += len(data) - keep
                if policy.rst_after >= 0:
                    log.info("conn %d: %s forwarded %d B, now resetting",
                             conn_id, direction, forwarded)
                    return "rst"
                if not announced:
                    announced = True
                    log.info("conn %d: %s quota %d hit — forwarded %d B, "
                             "swallowing the rest (split-hello drop)",
                             conn_id, direction, quota, forwarded)
                continue
            forwarded += len(data)
            writer.write(data)
            await writer.drain()
            if policy.rst_after >= 0 and forwarded == quota:
                # Exact boundary: the client sent N bytes and waits for the
                # answer — no next read will ever cross the quota.
                log.info("conn %d: %s forwarded %d B, now resetting",
                         conn_id, direction, forwarded)
                return "rst"
    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        if direction == "c->s":
            log.info("conn %d: %s done — fwd %d B, dropped %d B",
                     conn_id, direction, forwarded, dropped)
    return "eof"


async def handle(client_reader, client_writer, args, policy, conn_id):
    try:
        server_reader, server_writer = await asyncio.open_connection(
            args.target_host, args.target_port)
    except OSError as e:
        log.warning("conn %d: upstream connect failed: %s", conn_id, e)
        client_writer.close()
        return

    c2s = asyncio.create_task(relay(client_reader, server_writer, "c->s",
                                    policy.quota, policy, conn_id))
    s2c = asyncio.create_task(relay(server_reader, client_writer, "s->c",
                                    -1, policy, conn_id))
    done, pending = await asyncio.wait({c2s, s2c}, return_when=asyncio.FIRST_COMPLETED)

    if policy.rst_after >= 0 and any(t.result() == "rst" for t in done):
        # linger=0 close: the client sees ECONNRESET, like a DPI's RST injection.
        for w in (client_writer, server_writer):
            sock = w.get_extra_info("socket")
            if sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                struct_linger0())
            w.close()
        for t in pending:
            t.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
    else:
        # A FIN is a half-close, not a teardown: propagate it so a reply already
        # on its way still arrives, then let the surviving direction run to EOF.
        ended = next(iter(done))
        peer_writer = server_writer if ended is c2s else client_writer
        if peer_writer.can_write_eof():
            peer_writer.write_eof()
        else:
            peer_writer.close()
        if pending:
            _, pending = await asyncio.wait(pending, timeout=DRAIN_TIMEOUT_S)
        for t in pending:
            t.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        client_writer.close()
        server_writer.close()
    await asyncio.gather(client_writer.wait_closed(),
                         server_writer.wait_closed(), return_exceptions=True)


def struct_linger0():
    # struct linger { int l_onoff; int l_linger; } — on=1, time=0 → RST on close.
    import struct
    return struct.pack("ii", 1, 0)


async def main():
    p = argparse.ArgumentParser(
        description="middlebox emulator: split-ClientHello drop/RST TCP proxy",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--listen", type=int, default=15061, help="listen port (default 15061)")
    p.add_argument("--bind", default="127.0.0.1",
                   help="listen address (default 127.0.0.1; use 0.0.0.0 or a LAN "
                        "address when the client is another device — the port then "
                        "relays to --target for anyone who can reach it)")
    p.add_argument("--target", required=True, help="host:port to forward to")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--pass", dest="pass_", action="store_true",
                   help="clean relay, no fault (control run)")
    g.add_argument("--truncate", type=int, metavar="N", default=-1,
                   help="forward first N bytes c->s, swallow the rest")
    g.add_argument("--rst-after", type=int, metavar="N", default=-1,
                   help="forward first N bytes c->s, then reset the connection")
    g.add_argument("--delay-ms", type=int, default=0,
                   help="delay each relayed chunk by N ms (slow but honest path)")
    p.add_argument("--first-after-idle", type=float, metavar="S", default=None,
                   help="apply the fault only to a connection arriving >= S seconds "
                        "after the previous one")
    p.add_argument("--fail-prob", type=float, metavar="P", default=1.0,
                   help="apply the fault to a selected connection with probability P "
                        "(default 1.0)")
    args = p.parse_args()

    if not 0 <= args.fail_prob <= 1:
        p.error("--fail-prob must be in [0, 1]")
    if args.first_after_idle is not None and args.first_after_idle < 0:
        p.error("--first-after-idle must be >= 0")
    fault_mode = (args.truncate >= 0 or args.rst_after >= 0
                  or args.delay_ms > 0)
    if ((args.first_after_idle is not None or args.fail_prob != 1.0)
            and not fault_mode):
        p.error("--first-after-idle/--fail-prob need a fault mode "
                "(--truncate, --rst-after or --delay-ms)")

    host, _, port = args.target.rpartition(":")
    args.target_host, args.target_port = host, int(port)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s",
                        datefmt="%H:%M:%S")
    counter = 0
    last_arrival = None

    async def on_client(r, w):
        nonlocal counter, last_arrival
        counter += 1
        now = time.monotonic()
        idle = None if last_arrival is None else now - last_arrival
        last_arrival = now            # every connection counts, faulted or clean
        if (args.first_after_idle is not None and idle is not None
                and idle < args.first_after_idle):
            fault, why = False, (f" (idle {idle:.1f}s < "
                                 f"{args.first_after_idle:g}s)")
        elif random.random() >= args.fail_prob:
            fault, why = False, " (prob)"
        else:
            fault, why = True, ""
        policy = Policy(args, fault)
        log.info("conn %d: %s -> %s:%d fault=%s%s", counter,
                 w.get_extra_info("peername"), args.target_host, args.target_port,
                 "on" if policy.active else "off", why)
        await handle(r, w, args, policy, counter)

    server = await asyncio.start_server(on_client, args.bind, args.listen)
    mode = ("pass" if args.pass_ else
            f"truncate@{args.truncate}" if args.truncate >= 0 else
            f"rst-after@{args.rst_after}" if args.rst_after >= 0 else
            f"delay {args.delay_ms}ms")
    sel = []
    if args.first_after_idle is not None:
        sel.append(f"first-after-idle {args.first_after_idle:g}s")
    if args.fail_prob != 1.0:
        sel.append(f"fail-prob {args.fail_prob:g}")
    log.info("listening on %s:%d -> %s (mode=%s%s)", args.bind, args.listen, args.target, mode,
             ", " + ", ".join(sel) if sel else "")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
