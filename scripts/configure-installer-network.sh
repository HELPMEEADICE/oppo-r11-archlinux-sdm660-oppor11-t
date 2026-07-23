#!/usr/bin/env bash
set -euo pipefail

INTERFACE=${1:-}
if [[ -z $INTERFACE ]]; then
	for net in /sys/class/net/*; do
		name=${net##*/}
		[[ $name != lo ]] || continue
		[[ -r $net/address ]] || continue
		[[ $(<"$net/address") == 02:60:66:00:00:02 ]] || continue
		INTERFACE=$name
		break
	done
fi
[[ -n $INTERFACE && -d /sys/class/net/$INTERFACE ]] || {
	echo 'ERROR: R11T ECM interface was not found' >&2
	exit 1
}

ip link set "$INTERFACE" up
ip address replace 172.31.66.2/24 dev "$INTERFACE"
echo "Configured $INTERFACE as 172.31.66.2/24"
ping -c 3 -W 2 172.31.66.1
