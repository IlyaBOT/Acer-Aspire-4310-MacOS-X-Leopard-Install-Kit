#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CACHE_ROOT="${CARNATIONS_OC_CACHE:-$ROOT_DIR/cache/carnations-opencore}"
SOURCE_REPO="https://github.com/Carnations-Botanica/OpenCorePkg.git"
SOURCE_COMMIT="4d0803b5c1dbb12378e35712b213e531adde1d88"
AUDK_BRANCH="audk-stable-202502"
AUDK_COMMIT="f57172652dc48efac882d0cde416676e4fe4f05a"
SOURCE_DIR="$CACHE_ROOT/src-$SOURCE_COMMIT"
DIST_DIR="$CACHE_ROOT/$SOURCE_COMMIT"
ARCHIVE=""

log() { printf '[carnations-opencore] %s\n' "$*"; }
die() { printf '[carnations-opencore] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Prepare the modified Carnations Botanica OpenCore build required by the legacy
AMD kernel patches.

Usage:
  ./scripts/build_carnations_opencore.sh --ensure
  ./scripts/build_carnations_opencore.sh --archive /path/to/OpenCore-*.zip
  ./scripts/build_carnations_opencore.sh --print-root

--ensure uses an already extracted cache when available. Otherwise it builds the
pinned royalDevelopment commit with the repository's Docker build targets.

The source build pins audk-stable-202502. This Carnations fork is based on the
OpenCore 1.0.5-era EDK2 interface and does not build against current audk master.
EOF
}

validate_root() {
  local root="$1"
  [[ -f "$root/X64/EFI/OC/OpenCore.efi" ]] || return 1
  [[ -f "$root/X64/EFI/BOOT/BOOTx64.efi" ]] || return 1
  [[ -f "$root/Docs/Sample.plist" ]] || return 1
  [[ -f "$root/Utilities/LegacyBoot/bootX64" ]] || return 1
  [[ -f "$root/Utilities/LegacyBoot/boot0" ]] || return 1
  [[ -f "$root/Utilities/LegacyBoot/boot1f32" ]] || return 1
}

extract_archive() {
  local archive="$1"
  have python3 || die "python3 is required"
  [[ -f "$archive" ]] || die "Archive not found: $archive"
  rm -rf -- "$DIST_DIR"
  mkdir -p "$DIST_DIR"
  python3 - "$archive" "$DIST_DIR" <<'PY'
import sys,zipfile
archive,dest=sys.argv[1:]
with zipfile.ZipFile(archive) as zf:
    zf.extractall(dest)
PY
  validate_root "$DIST_DIR" || die "Archive does not contain the expected X64 OpenCore/OpenDuet distribution"
  printf '%s\n' "$SOURCE_COMMIT" > "$DIST_DIR/CARNATIONS_SOURCE_COMMIT"
  log "Prepared $DIST_DIR"
}

prepare_source_compat() {
  local dockerfile="$SOURCE_DIR/Dockerfiles/oc-dev/Dockerfile"
  local tool

  [[ -f "$dockerfile" ]] || die "Carnations Dockerfile is missing: $dockerfile"

  python3 - "$dockerfile" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
old1='    wget https://apt.llvm.org/llvm.sh && chmod +x llvm.sh && ./llvm.sh ${OC_DEV_EDK2_LLVM_VER} && rm -f llvm.sh && \\'
old2='    wget https://apt.llvm.org/llvm.sh && chmod +x llvm.sh && sed -i \'/check_url.*GPG_KEY_URL/d\' llvm.sh && ./llvm.sh ${OC_DEV_EDK2_LLVM_VER} && rm -f llvm.sh && \\'
new='    curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key -o /etc/apt/trusted.gpg.d/apt.llvm.org.asc && \\\n    echo "deb [signed-by=/etc/apt/trusted.gpg.d/apt.llvm.org.asc] https://apt.llvm.org/jammy/ llvm-toolchain-jammy-${OC_DEV_EDK2_LLVM_VER} main" > /etc/apt/sources.list.d/llvm.list && \\\n    apt-get update && \\\n    apt-get install -y clang-${OC_DEV_EDK2_LLVM_VER} lldb-${OC_DEV_EDK2_LLVM_VER} lld-${OC_DEV_EDK2_LLVM_VER} clangd-${OC_DEV_EDK2_LLVM_VER} && \\'
if new not in s:
    if old1 in s:
        s=s.replace(old1,new,1)
    elif old2 in s:
        s=s.replace(old2,new,1)
    else:
        raise SystemExit("unexpected LLVM install stanza in Carnations Dockerfile")
p.write_text(s)
PY

  for tool in build_oc.tool build_duet.tool; do
    python3 - "$SOURCE_DIR/$tool" "$AUDK_BRANCH" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); branch=sys.argv[2]; s=p.read_text()
needle='src=$(curl -LfsS https://raw.githubusercontent.com/acidanthera/ocbuild/master/efibuild.sh) && eval "$src" || exit 1'
repl='src=$(curl -LfsS https://raw.githubusercontent.com/acidanthera/ocbuild/master/efibuild.sh) || exit 1\nsrc=$(printf \'%s\\n\' "$src" | sed \'s#updaterepo "https://github.com/acidanthera/audk" UDK master#updaterepo "https://github.com/acidanthera/audk" UDK '+branch+'#\')\neval "$src" || exit 1'
if repl not in s:
    if needle not in s:
        raise SystemExit(f"unexpected efibuild bootstrap in {p}")
    s=s.replace(needle,repl,1)
p.write_text(s)
PY
  done

  rm -rf -- "$SOURCE_DIR/UDK"
  log "Pinned build dependencies: $AUDK_BRANCH ($AUDK_COMMIT)"
}

select_built_archive() {
  python3 - "$SOURCE_DIR/Binaries" <<'PY'
from pathlib import Path
import sys,zipfile
root=Path(sys.argv[1])
required={
    "X64/EFI/OC/OpenCore.efi",
    "X64/EFI/BOOT/BOOTx64.efi",
    "Docs/Sample.plist",
    "Utilities/LegacyBoot/bootX64",
    "Utilities/LegacyBoot/boot0",
    "Utilities/LegacyBoot/boot1f32",
}
candidates=[]
for p in root.glob("*.zip"):
    try:
        with zipfile.ZipFile(p) as zf:
            names=set(zf.namelist())
    except zipfile.BadZipFile:
        continue
    if required <= names:
        score=2 if "DEBUG" in p.name.upper() else 1 if "RELEASE" in p.name.upper() else 0
        candidates.append((score,p))
if not candidates:
    raise SystemExit("No OpenCore archive with X64 + LegacyBoot files found under Binaries/")
candidates.sort(key=lambda x:(x[0],x[1].name))
print(candidates[-1][1])
PY
}

build_from_source() {
  for cmd in git docker python3; do have "$cmd" || die "Missing required command for source build: $cmd"; done
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"

  mkdir -p "$CACHE_ROOT"
  if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    rm -rf -- "$SOURCE_DIR"
    mkdir -p "$SOURCE_DIR"
    git -C "$SOURCE_DIR" init
    git -C "$SOURCE_DIR" remote add origin "$SOURCE_REPO"
  fi

  current="$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$current" != "$SOURCE_COMMIT" ]]; then
    log "Fetching pinned OpenCore fork commit $SOURCE_COMMIT"
    git -C "$SOURCE_DIR" fetch --depth=1 origin "$SOURCE_COMMIT"
    git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD
  fi
  [[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || die "OpenCore source pin mismatch"

  prepare_source_compat

  log "Building OpenDuet from pinned Carnations Botanica fork against $AUDK_BRANCH"
  (cd "$SOURCE_DIR" && docker compose run --rm build-duet)
  log "Building OpenCore from pinned Carnations Botanica fork against $AUDK_BRANCH"
  (cd "$SOURCE_DIR" && docker compose run --rm build-oc)

  built="$(select_built_archive)"
  log "Selected built archive: $built"
  extract_archive "$built"
}

MODE="ensure"
while (($#)); do
  case "$1" in
    --ensure) MODE="ensure" ;;
    --archive)
      [[ $# -gt 1 ]] || die "--archive requires a path"
      shift
      ARCHIVE="$1"
      MODE="archive"
      ;;
    --print-root) MODE="print" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

case "$MODE" in
  archive)
    extract_archive "$ARCHIVE"
    ;;
  ensure)
    if validate_root "$DIST_DIR"; then
      log "Using cached pinned OpenCore fork: $DIST_DIR"
    else
      build_from_source
    fi
    ;;
  print)
    validate_root "$DIST_DIR" || die "Pinned OpenCore fork is not prepared; run --ensure first"
    ;;
esac

printf '%s\n' "$DIST_DIR"
