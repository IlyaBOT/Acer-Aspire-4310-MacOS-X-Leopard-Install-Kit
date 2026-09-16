#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

printf '[atom-kernel-pipeline] phase 0: source bootstrap\n'
bash "$SCRIPT_DIR/bootstrap_source.sh"

printf '[atom-kernel-pipeline] phase 1: source audit\n'
bash "$SCRIPT_DIR/audit_source.sh"

printf '[atom-kernel-pipeline] phase 2: vanilla RELEASE/I386 build\n'
bash "$SCRIPT_DIR/build_vanilla.sh"

printf '[atom-kernel-pipeline] phase 3: static artifact validation\n'
bash "$SCRIPT_DIR/test_vanilla.sh" "$ROOT_DIR/artifacts/vanilla/mach_kernel"

printf '[atom-kernel-pipeline] PASS: vanilla source/build/static checks completed\n'
printf '[atom-kernel-pipeline] next: control boot on supported hardware/QEMU; do not patch Atom support yet\n'
