#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MODEL_DIR="$ROOT_DIR/priv/static/models/movenet"
BASE_URL="https://www.kaggle.com/models/google/movenet/tfJs/singlepose-lightning/4"

mkdir -p "$MODEL_DIR"

download() {
	name="$1"
	dest="$MODEL_DIR/$name"
	url="$BASE_URL/$name?tfjs-format=file"

	if [ -s "$dest" ]; then
		echo "exists $dest"
		return 0
	fi

	tmp="$dest.tmp"
	rm -f "$tmp"
	echo "download $name"

	if command -v curl >/dev/null 2>&1; then
		curl -L -f -o "$tmp" "$url"
	elif command -v fetch >/dev/null 2>&1; then
		fetch -L -o "$tmp" "$url"
	else
		echo "ERROR: need curl or fetch to download MoveNet model assets" >&2
		exit 1
	fi

	mv "$tmp" "$dest"
}

download model.json
download group1-shard1of2.bin
download group1-shard2of2.bin

echo "MoveNet model assets ready in $MODEL_DIR"
