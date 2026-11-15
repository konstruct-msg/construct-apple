# pcap stand

Proves from captured traffic, not from code, that the direct path carries no stable identifier in
the clear, falls back to nothing unencrypted, and repeats no handshake field across connections.
Todos 309 and 310 in construct-docs; the method is the one report GNMX-01 used on MTProto's
`auth_key_id` (capture, search the bytes, block ports one at a time).

| Script | Does |
|---|---|
| `capture.sh start\|stop <name>` | tcpdump on the default-route interface → `logs/pcap_stand/<name>.pcap` |
| `control.sh` | positive control: makes traffic that must be caught and fails unless the analyzer catches all of it |
| `stand.sh start\|stop <name>` | installs the built app on one stand simulator, captures, collects needles, runs t1–t3 |
| `stand.sh follow-pf` | relaunches the app at each phase `pf_block.sh` writes |
| `pf_block.sh <address>` | root: blocks UDP 443, then TCP 443, then both, to the service address only |
| `needles.py` | the stand's own identifiers, from the simulator at run time, in every encoding |
| `analyze.py t1\|t2\|t3\|addresses` | the checks; exit 1 on a red line, 2 when the capture holds nothing to judge |

## Run

```bash
# once per boot, in a real terminal (sudo needs a tty): bpf access for the account's group
sudo chgrp access_bpf /dev/bpf* && sudo chmod g+rw /dev/bpf*

CONFIGURATION=Beta ./scripts/two_sims.sh build      # what testers run
./scripts/pcap_stand/control.sh                      # must print CONTROL OK
SIM_A_NAME=Construct-C ./scripts/pcap_stand/stand.sh start run1
#   …drive the scenario: send, background, foreground, relaunch…
SIM_A_NAME=Construct-C STAND_TEXT=<username typed> ./scripts/pcap_stand/stand.sh stop run1

# t2 under blocking: start a capture, then
./scripts/pcap_stand/stand.sh follow-pf &            # relaunches the app at each phase
sudo scripts/pcap_stand/pf_block.sh <address>        # the owner; address from `analyze.py addresses`
```

## What the stand cannot see, and why it is built this way

- **No process names.** pktap would tag each packet with its process, but macOS lets only root
  create the pktap interface. t1 therefore searches the whole Mac's traffic (an identifier of the
  stand is red wherever it appears); t2 and t3 judge the flows to the service, found by address,
  by DNS answers for the service domain, and by the SNI of each ClientHello.
- **Pass pf_block an address, not a name.** On 2026-11-15 root's resolver answered with a proxy's
  fake-IP range (198.18.0.0/15) while the simulator connected to the real address, and three
  blocking phases blocked nothing. The script now refuses a fake-IP answer.
- **QUIC Initial is read decrypted.** Its keys come from the DCID, so any observer has them;
  tshark decrypts it, and t1 searches those bytes too.
- **The app's ClientHello spans two TCP segments** (post-quantum key share). The analyzer lets
  tshark reassemble; the control pads its own hellos past one segment, so a field read only from
  single-segment hellos turns the control red.
- **A blob is searched in 16-byte windows**, except where a window touches a host name written in
  it: the sealed-sender certificate names its issuing server, which every SNI shows anyway.
- A green capture is deleted (a gigabyte in five minutes is common); `KEEP_PCAP=1` keeps it.
  Needles and outputs stay in `logs/pcap_stand/` (gitignored): they hold the stand accounts' ids.
