#!/bin/zsh
# Does the VEIL dialer's TLS (Network.framework) present a resumption PSK to a relay it has
# already talked to, and does turning resumption off change the ClientHello?
#
# A relay issues the tickets, so a resumed session names the device's previous connection
# to that relay across an IP change (construct-docs decisions/veil-relay-sees-no-stable-device-id.md,
# todo 311). No root, no simulator: a local `openssl s_server` (TLS 1.3, issues tickets),
# a proxy that parses each ClientHello, and nwclient.swift dialing twice per mode.
#
# Red (exit 1) when:
#   - the control (openssl s_client with a saved session) shows no PSK — the probe is blind;
#   - the dialer's mode ("noresume") presents a PSK on the second connection;
#   - the "noresume" ClientHello's extensions differ from the default one (fingerprint).
# Runs on macOS Network.framework; the simulator and devices are covered by the pcap of todo 310.
set -u
here=${0:A:h}
work=$(mktemp -d)
trap 'kill ${srv:-} ${prx:-} 2>/dev/null; rm -rf $work' EXIT
cd $work
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout key.pem \
  -out cert.pem -days 1 -subj /CN=relay.test >/dev/null 2>&1 || { echo "openssl req failed"; exit 2; }
swiftc -O $here/nwclient.swift -o nwclient 2>&1 | grep -v '^$' && { echo "swiftc failed"; exit 2; }
SP=19443 PP=19444
openssl s_server -accept $SP -cert cert.pem -key key.pem -www -quiet >/dev/null 2>&1 & srv=$!
python3 -I $here/hello_proxy.py $PP $SP > hellos.log 2>&1 & prx=$!
sleep 1

hellos() { sleep 0.5; grep '^conn' hellos.log | tail -n $1; }

# Control: a client that does resume, through the same proxy.
printf 'GET / HTTP/1.0\r\n\r\n' | openssl s_client -connect 127.0.0.1:$PP -servername relay.test \
  -sess_out sess.pem -ign_eof >/dev/null 2>&1
printf 'GET / HTTP/1.0\r\n\r\n' | openssl s_client -connect 127.0.0.1:$PP -servername relay.test \
  -sess_in sess.pem -ign_eof >/dev/null 2>&1
control=$(hellos 1)
./nwclient $PP default; default=$(hellos 2)
./nwclient $PP noresume; noresume=$(hellos 2)

print "control (openssl, saved session): $control"
print "default:\n$default"
print "noresume (the dialer):\n$noresume"

red=0
[[ $control == *psk=True* ]] || { print "RED: the control shows no PSK — the probe cannot see a resumption"; red=1; }
[[ $(print $noresume | tail -1) == *psk=False* ]] || { print "RED: the dialer's mode resumed"; red=1; }
exts() { print $1 | sed -E 's/.*exts=([^ ]*).*/\1/' | sort -u; }
[[ $(exts $default | head -1) == $(exts $noresume | head -1) && $(exts $noresume | wc -l) -eq 1 ]] \
  || { print "RED: resumption off changes the ClientHello extensions"; red=1; }
[[ $(print $default | tail -1) == *psk=True* ]] && print "note: Network.framework resumes by default here — the dialer's setting is what stops it"
(( red )) && exit 1
print "GREEN"
