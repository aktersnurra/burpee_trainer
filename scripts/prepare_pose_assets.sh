#!/usr/bin/env sh
set -eu

ROOT_DIR="$(unset CDPATH && cd -- "$(dirname -- "$0")/.." && pwd)"
MEDIAPIPE_DIR="$ROOT_DIR/priv/static/models/mediapipe_pose"
WASM_DIR="$MEDIAPIPE_DIR/wasm"
TASKS_DIR="$ROOT_DIR/assets/node_modules/@mediapipe/tasks-vision"

MODEL_NAME="pose_landmarker_full.task"
MODEL_URL="https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/latest/$MODEL_NAME"

mkdir -p "$WASM_DIR"

copy_wasm() {
	name="$1"
	src="$TASKS_DIR/wasm/$name"
	dest="$WASM_DIR/$name"

	if [ ! -e "$src" ]; then
		echo "ERROR: missing MediaPipe tasks-vision asset $src; run mix assets.setup" >&2
		exit 1
	fi

	echo "copy wasm/$name"
	cp "$src" "$dest"
}

copy_wasm vision_wasm_internal.js
copy_wasm vision_wasm_internal.wasm
copy_wasm vision_wasm_nosimd_internal.js
copy_wasm vision_wasm_nosimd_internal.wasm

# The pose landmarker bundle is not published to npm, so fetch it once and keep
# it cached in priv/static.
if [ ! -e "$MEDIAPIPE_DIR/$MODEL_NAME" ]; then
	echo "download $MODEL_NAME"
	if ! curl -fsSL -o "$MEDIAPIPE_DIR/$MODEL_NAME.tmp" "$MODEL_URL"; then
		rm -f "$MEDIAPIPE_DIR/$MODEL_NAME.tmp"
		echo "ERROR: could not download $MODEL_URL" >&2
		exit 1
	fi
	mv "$MEDIAPIPE_DIR/$MODEL_NAME.tmp" "$MEDIAPIPE_DIR/$MODEL_NAME"
else
	echo "cached $MODEL_NAME"
fi

echo "MediaPipe Pose assets ready in $MEDIAPIPE_DIR"
