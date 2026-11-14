#!/bin/zsh
# Gather the VEIL lines of every Konstruct client running on this Mac into ~/Code/veil-measure,
# for scripts/veil_measure/analyze.py — todo 311 step 1.
#
# The app keeps a four-file, 5 MB ring of logs (LogCollector), so a day of use can rotate the
# morning away; this follows current.log through rotations and keeps every VEIL / transport event
# line. Only lines analyze.py reads are kept: no message content is in them.
#
# Sources it finds (Debug/Beta builds write logs; Release writes none):
#   desktop   ~/Library/Containers/maximeliseyev.construct-desktop/…/Documents/Logs/current.log
#   ipad-mac  the iOS app run as "Designed for iPad" on this Mac (its own container)
#   sim-<id>  each booted simulator with the app installed
#
#   scripts/veil_measure/collect.sh            # run until Ctrl-C (leave it in a terminal)
#   scripts/veil_measure/analyze.py ~/Code/veil-measure/*.log
set -u
out=~/Code/veil-measure
mkdir -p $out
pattern='VEIL native-TLS: exporter derived|falling back to rustls|per-connection dial failed|Network path changed|mode is off'

typeset -A sources
for f in ~/Library/Containers/maximeliseyev.construct-desktop/Data/Documents/Logs/current.log(N); do
  sources[desktop]=$f
done
for f in ~/Library/Containers/*/Data/Documents/Logs/current.log(N); do
  [[ $f == *construct-desktop* ]] && continue
  plist=${f:h:h:h:h}/.com.apple.containermanagerd.metadata.plist
  [[ -f $plist ]] && /usr/bin/plutil -p $plist 2>/dev/null | grep -q 'maximeliseyev.constructmessenger"' \
    && sources[ipad-mac]=$f
done
for dev in $(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-F-]{36}'); do
  data=$(xcrun simctl get_app_container $dev maximeliseyev.constructmessenger data 2>/dev/null) || continue
  [[ -f $data/Documents/Logs/current.log ]] && sources[sim-${dev:0:8}]=$data/Documents/Logs/current.log
done

if (( ${#sources} == 0 )); then
  print "no client log found — start Desktop, the iPad-on-Mac app or a simulator (Debug/Beta build) first"
  exit 1
fi
pids=()
for label path in ${(kv)sources}; do
  print "following $label: $path → $out/$label.log"
  # Seed with what the ring still holds, then follow through rotations.
  cat ${path:h}/{3,2,1}.log(N) $path 2>/dev/null | grep -E "$pattern" >> $out/$label.log
  ( tail -n0 -F $path 2>/dev/null | grep --line-buffered -E "$pattern" >> $out/$label.log ) &
  pids+=$!
done
trap 'kill $pids 2>/dev/null; print "\nstopped; analyze: scripts/veil_measure/analyze.py $out/*.log"; exit 0' INT TERM
print "collecting… Ctrl-C to stop"
wait
