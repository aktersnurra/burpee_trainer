#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MEDIAPIPE_DIR="$ROOT_DIR/priv/static/models/mediapipe_pose"

mkdir -p "$MEDIAPIPE_DIR"

copy_mediapipe() {
	name="$1"
	src="$ROOT_DIR/assets/node_modules/@mediapipe/pose/$name"
	dest="$MEDIAPIPE_DIR/$name"

	if [ ! -e "$src" ]; then
		echo "ERROR: missing MediaPipe Pose asset $src; run npm --prefix assets install" >&2
		exit 1
	fi

	if [ -e "$dest" ]; then
		echo "exists $dest"
		return 0
	fi

	echo "copy $name"
	cp "$src" "$dest"
}

copy_mediapipe pose.js
copy_mediapipe pose_landmark_full.tflite
copy_mediapipe pose_web.binarypb
copy_mediapipe pose_solution_packed_assets_loader.js
copy_mediapipe pose_solution_packed_assets.data
copy_mediapipe pose_solution_simd_wasm_bin.js
copy_mediapipe pose_solution_simd_wasm_bin.wasm
copy_mediapipe pose_solution_simd_wasm_bin.data
copy_mediapipe pose_solution_wasm_bin.js
copy_mediapipe pose_solution_wasm_bin.wasm

echo "MediaPipe Pose assets ready in $MEDIAPIPE_DIR"
