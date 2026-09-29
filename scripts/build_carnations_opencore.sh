#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CACHE_ROOT="${CARNATIONS_OC_CACHE:-$ROOT_DIR/cache/carnations-opencore}"
SOURCE_REPO="https://github.com/Carnations-Botanica/OpenCorePkg.git"
SOURCE_COMMIT="4d0803b5c1dbb12378e35712b213e531adde1d88"
AUDK_BRANCH="audk-stable-202502"
AUDK_COMMIT="f57172652dc48efac882d0cde416676e4fe4f05a"
SOURCE_DIR="$CACHE_ROOT/src-$SOURCE_COMMIT"
LOCAL_PATCH_REV="2"
PATCH_MARKER="Original mach_kernel is absent, trying ESP Kernels fallback"
DIST_DIR="$CACHE_ROOT/${SOURCE_COMMIT}-r${LOCAL_PATCH_REV}"
ARCHIVE=""
BUNDLED_ARCHIVE="${CARNATIONS_OC_BUNDLED_ARCHIVE:-$ROOT_DIR/vendor/carnations-opencore/OpenCore-1.0.5-DEBUG.zip}"

log() { printf '[carnations-opencore] %s\n' "$*"; }
die() { printf '[carnations-opencore] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

binary_has_local_patch() {
  local binary="$1"
  [[ -f "$binary" ]] || return 1
  have python3 || return 1
  python3 - "$binary" "$PATCH_MARKER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
marker = sys.argv[2].encode("ascii")
try:
    data = path.read_bytes()
except OSError:
    raise SystemExit(1)
raise SystemExit(0 if marker in data else 1)
PY
}

archive_has_local_patch() {
  local archive="$1"
  [[ -f "$archive" ]] || return 1
  have python3 || return 1
  python3 - "$archive" "$PATCH_MARKER" <<'PY'
import sys
import zipfile

archive = sys.argv[1]
marker = sys.argv[2].encode("ascii")
member = "X64/EFI/OC/OpenCore.efi"

try:
    with zipfile.ZipFile(archive) as zf:
        data = zf.read(member)
except (OSError, KeyError, zipfile.BadZipFile):
    raise SystemExit(1)

raise SystemExit(0 if marker in data else 1)
PY
}

usage() {
  cat <<'EOF'
Prepare the modified Carnations Botanica OpenCore build required by the legacy
AMD kernel patches.

Usage:
  ./scripts/build_carnations_opencore.sh --ensure
  ./scripts/build_carnations_opencore.sh --archive /path/to/OpenCore-*.zip
  ./scripts/build_carnations_opencore.sh --print-root

--ensure uses an already extracted cache when available, then prefers the
repository-bundled OpenCore 1.0.5 DEBUG archive. Docker is only a fallback when
the bundled archive is unavailable.

The source fallback pins audk-stable-202502. This Carnations fork is based on
the OpenCore 1.0.5-era EDK2 interface and does not build against current audk
master.
EOF
}

validate_root() {
  local root="$1"
  [[ -f "$root/X64/EFI/OC/OpenCore.efi" ]] || return 1
  [[ -f "$root/X64/EFI/BOOT/BOOTx64.efi" ]] || return 1
  [[ -f "$root/Docs/Sample.plist" ]] || return 1
  [[ -f "$root/X64/EFI/OC/Drivers/OpenRuntime.efi" ]] || return 1
  [[ -f "$root/X64/EFI/OC/Drivers/OpenHfsPlus.efi" ]] || return 1
  [[ -f "$root/X64/EFI/OC/Drivers/OpenPartitionDxe.efi" ]] || return 1
  [[ -f "$root/Utilities/macrecovery/macrecovery.py" ]] || return 1
  [[ -f "$root/Utilities/LegacyBoot/bootX64" ]] || return 1
  [[ -f "$root/Utilities/LegacyBoot/boot0" ]] || return 1
  [[ -f "$root/Utilities/LegacyBoot/boot1f32" ]] || return 1
  binary_has_local_patch "$root/X64/EFI/OC/OpenCore.efi" || return 1
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

  python3 - "$SOURCE_DIR/Library/OcMainLib/OpenCoreKernel.c" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

needle = '''  Status = OcSafeFileOpen (This, NewHandle, FileName, OpenMode, Attributes);

  DEBUG ((
    DEBUG_VERBOSE,
    "OC: Opening file %s with %u mode gave - %r\\n",
    FileName,
    (UINT32)OpenMode,
    Status
    ));

  //
  // Hook kernelcache read attempts for fuzzy kernelcache matching.
'''

patched = '''  Status = OcSafeFileOpen (This, NewHandle, FileName, OpenMode, Attributes);

  DEBUG ((
    DEBUG_VERBOSE,
    "OC: Opening file %s with %u mode gave - %r\\n",
    FileName,
    (UINT32)OpenMode,
    Status
    ));

  //
  // Mavericks Recovery BaseSystem.dmg may contain only a prelinked
  // kernelcache and no /mach_kernel. When Cacheless rejects the stock
  // kernelcache, boot.efi falls back to mach_kernel. Allow CustomKernel
  // to satisfy that request directly from ESP:/Kernels even when the
  // original filesystem has no placeholder mach_kernel file.
  //
  if (  (Status == EFI_NOT_FOUND)
     && (OpenMode == EFI_FILE_MODE_READ)
     && ((Attributes & EFI_FILE_DIRECTORY) == 0)
     && (mCustomKernelDirectory != NULL))
  {
    NewFileName = OcStrrChr (FileName, L'\\\\');
    if (NewFileName == NULL) {
      NewFileName = FileName;
    } else {
      NewFileName++;
    }

    if (StrCmp (NewFileName, L"mach_kernel") == 0) {
      DEBUG ((DEBUG_INFO, "OC: Original mach_kernel is absent, trying ESP Kernels fallback\\n"));

      mCustomKernelDirectoryInProgress = TRUE;
      Status = OcSafeFileOpen (
                 mCustomKernelDirectory,
                 &EspNewHandle,
                 NewFileName,
                 OpenMode,
                 Attributes
                 );
      mCustomKernelDirectoryInProgress = FALSE;

      DEBUG ((DEBUG_INFO, "OC: ESP mach_kernel fallback status: %r\\n", Status));

      if (!EFI_ERROR (Status)) {
        This       = mCustomKernelDirectory;
        *NewHandle = EspNewHandle;
        FileName   = NewFileName;
      }
    }
  }

  //
  // Hook kernelcache read attempts for fuzzy kernelcache matching.
'''

if "Original mach_kernel is absent, trying ESP Kernels fallback" not in s:
    if needle not in s:
        raise SystemExit("unexpected OpenCoreKernel.c layout; cannot apply Mavericks mach_kernel fallback")
    s = s.replace(needle, patched, 1)

expected = "NewFileName = OcStrrChr (FileName, L'\\\\');"
if expected not in s:
    raise SystemExit("Mavericks fallback patch produced invalid C backslash escaping")

p.write_text(s)
PY

  rm -rf -- "$SOURCE_DIR/UDK"
  log "Pinned build dependencies: $AUDK_BRANCH ($AUDK_COMMIT), local patch r$LOCAL_PATCH_REV"
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
    "X64/EFI/OC/Drivers/OpenPartitionDxe.efi",
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

  log "Building OpenDuet X64 DEBUG from pinned Carnations Botanica fork against $AUDK_BRANCH"
  (cd "$SOURCE_DIR" && TARGETS=DEBUG ARCHS=X64 docker compose run --rm -T build-duet)
  log "Building OpenCore X64 DEBUG from pinned Carnations Botanica fork against $AUDK_BRANCH"
  (cd "$SOURCE_DIR" && TARGETS=DEBUG ARCHS=X64 docker compose run --rm -T build-oc)

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
      if [[ -d "$DIST_DIR" ]]; then
        log "Cached OpenCore is incomplete or lacks local patch r$LOCAL_PATCH_REV; discarding $DIST_DIR"
        rm -rf -- "$DIST_DIR"
      fi

      if [[ -f "$BUNDLED_ARCHIVE" ]] && archive_has_local_patch "$BUNDLED_ARCHIVE"; then
        log "Preparing bundled OpenCore archive: $BUNDLED_ARCHIVE"
        extract_archive "$BUNDLED_ARCHIVE"
      else
        if [[ -f "$BUNDLED_ARCHIVE" ]]; then
          log "Bundled OpenCore archive lacks local patch r$LOCAL_PATCH_REV marker; falling back to source build"
        else
          log "Bundled OpenCore archive not found; falling back to source build"
        fi
        build_from_source
      fi
    fi
    ;;
  print)
    validate_root "$DIST_DIR" || die "Pinned OpenCore fork is not prepared; run --ensure first"
    ;;
esac

printf '%s\n' "$DIST_DIR"
