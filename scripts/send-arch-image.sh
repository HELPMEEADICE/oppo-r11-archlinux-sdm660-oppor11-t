#!/usr/bin/env bash
set -euo pipefail

IMAGE=
ADDRESS=172.31.66.1
TARGET=

while (($#)); do
	case "$1" in
	--image) IMAGE=${2:-}; shift 2 ;;
	--address) ADDRESS=${2:-}; shift 2 ;;
	--target) TARGET=${2:-}; shift 2 ;;
	*) echo "usage: $0 --image FILE [--target system|userdata] [--address IP]" >&2; exit 2 ;;
	esac
done
[[ -f $IMAGE ]] || { echo "ERROR: image not found: $IMAGE" >&2; exit 1; }
case "$TARGET" in
	'') target_arg= ;;
	system|userdata) target_arg="--target $TARGET " ;;
	*) echo 'ERROR: target must be system or userdata' >&2; exit 2 ;;
esac
SIZE=$(stat -c %s "$IMAGE")
(( SIZE > 0 && SIZE % 4096 == 0 )) || {
	echo 'ERROR: image size must be 4096-byte aligned' >&2
	exit 1
}
HASH=$(sha256sum "$IMAGE" | cut -d' ' -f1)

echo "On the installer ACM console run:"
echo "receive_arch_image ${target_arg}--bytes $SIZE --sha256 $HASH --confirm"
echo 'After it reports that it is listening, press Enter here.'
read -r

if command -v nc >/dev/null 2>&1; then
	zstd -T0 -3 --check -c "$IMAGE" | nc -N "$ADDRESS" 5555
elif command -v socat >/dev/null 2>&1; then
	zstd -T0 -3 --check -c "$IMAGE" | socat - "TCP:$ADDRESS:5555"
else
	echo 'ERROR: install either OpenBSD nc or socat' >&2
	exit 1
fi
echo 'Stream sent; wait for the ACM readback verification result.'
