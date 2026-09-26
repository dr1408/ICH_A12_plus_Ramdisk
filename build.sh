#!/usr/bin/env bash
# Build an SSH ramdisk bootchain for A12/A13 after usbliter8 pwned DFU.
#
#   https://github.com/prdgmshift/usbliter8
#   https://github.com/Leeksov/usbliter8ra1n
#
# Flow: patched iBEC → [SPTM/TXM if present] → DT → trustcache → ramdisk → kernel/bootx
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$ROOT/env.sh"
# shellcheck source=scripts/devices.sh
source "$ROOT/scripts/devices.sh"
# shellcheck source=scripts/ramdisk_expand.sh
source "$ROOT/scripts/ramdisk_expand.sh"

nr_banner "build"

IRECOVERY="$NR_TOOLS/irecovery"
PZB="$NR_TOOLS/pzb"
IMG4="$NR_TOOLS/img4"
GTAR="$NR_TOOLS/gtar"
TC="$NR_TOOLS/trustcache"
JQ="$NR_TOOLS/jq"

SELECTION=""
LIVE_DATA=0
# Default ON — without AOP/SIO/… XNU often hangs at AppleA7IOPNub
# ("withRegistryEntry, 47: allocated nub") / disk0 "Device not configured".
WITH_FW=1
USE_IBSS=0
DRY_RUN=0
LIST_ONLY=0
DIRECT_URL=""
IM4M_OVERRIDE=""
PRODUCT_OVERRIDE=""
MODEL_OVERRIDE=""
CPID_OVERRIDE=""
KERNEL_MODE="patched"
KPF_SET="auto"
KERNEL_MODE_SET=0
KPF_SET_SET=0
INTERACTIVE=0

usage() {
    cat <<'EOF'
usage: ./build.sh [--version VERSION|--build BUILD|--url IPSW_URL]
                  [--list] [--im4m PATH]
                  [--product PRODUCT --board BOARD --cpid CPID]
                  [--kernel stock|patched] [--kpf-set SET]
                  [--with-fw|--no-fw] [--use-ibss] [--live-data] [--dry-run]

Detects a connected pwned-DFU device, or accepts an explicit product/board/CPID
for a build without attached hardware. Resolves firmware from ipsw.me (or --url),
builds an SSH ramdisk, and stages a bootchain under
./bootchain/<board>-<ver>-<build>-ramdisk/.

Pwned DFU requires RP2350 + https://github.com/prdgmshift/usbliter8
Run ./setup.sh once on a new Mac before building.

If neither --version nor --build is given, an interactive firmware picker runs.

  --list         list firmwares for the connected device and exit
  --im4m PATH    IM4M / APTicket (default: resources/IM4M_<CPID>)
  --product      IPSW product identifier (e.g. iPhone11,8)
  --board        BuildManifest device class (e.g. n841ap)
  --cpid         chip ID (0x8020 for A12, 0x8030 for A13)
  --kernel       patched (default, usbliter8ra1n AMFI) | stock (fallback)
  --kpf-set      auto (default) | ios17|ios18|ios26|ios27|debugger+amfi|all
  --with-fw      stage AOP/ANE/AVE/ISP/GFX/SIO (+ PMP on A13) — default ON
  --no-fw        skip coprocessor firmwares (DCSD-only; can hang at allocated nub)
  --use-ibss     stage patched iBSS (default: direct iBEC)
  --live-data    also mark bootchain for live-data experiments (RestoreSEP is always staged)
  --dry-run      resolve IPSW + BuildManifest only

Requires: device in DFU with PWND: usbliter8; deps from ./setup.sh.
When building on CI without hardware, pass --product, --board, and --cpid.
EOF
}

while (($#)); do
    case "$1" in
        --build|--version)
            (($# >= 2)) || { usage >&2; exit 64; }
            SELECTION="$2"
            shift 2
            ;;
        --url)
            (($# >= 2)) || { usage >&2; exit 64; }
            DIRECT_URL="$2"
            shift 2
            ;;
        --im4m)
            (($# >= 2)) || { usage >&2; exit 64; }
            IM4M_OVERRIDE="$2"
            shift 2
            ;;
        --product)
            (($# >= 2)) || { usage >&2; exit 64; }
            PRODUCT_OVERRIDE="$2"
            shift 2
            ;;
        --board)
            (($# >= 2)) || { usage >&2; exit 64; }
            MODEL_OVERRIDE="$2"
            shift 2
            ;;
        --cpid)
            (($# >= 2)) || { usage >&2; exit 64; }
            CPID_OVERRIDE="$2"
            shift 2
            ;;
        --kernel)
            (($# >= 2)) || { usage >&2; exit 64; }
            KERNEL_MODE="$2"
            KERNEL_MODE_SET=1
            case "$KERNEL_MODE" in stock|patched) ;; *)
                echo "invalid --kernel: $KERNEL_MODE" >&2; exit 64 ;;
            esac
            shift 2
            ;;
        --kpf-set)
            (($# >= 2)) || { usage >&2; exit 64; }
            KPF_SET="$2"
            KPF_SET_SET=1
            shift 2
            ;;
        --with-fw) WITH_FW=1; shift ;;
        --no-fw) WITH_FW=0; shift ;;
        --use-ibss) USE_IBSS=1; shift ;;
        --live-data) LIVE_DATA=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
done

require() {
    command -v "$1" >/dev/null || {
        echo "missing required command: $1" >&2
        exit 1
    }
}

for tool in "$IRECOVERY" "$PZB" "$IMG4" "$GTAR" "$TC" "$JQ" curl ipsw python3 hdiutil diskutil; do
    if [[ "$tool" == */* ]]; then
        [[ -x "$tool" ]] || { echo "missing required tool: $tool" >&2; exit 1; }
    else
        require "$tool"
    fi
done

MANUAL_DEVICE=0
if [[ -n "$PRODUCT_OVERRIDE$MODEL_OVERRIDE$CPID_OVERRIDE" ]]; then
    [[ -n "$PRODUCT_OVERRIDE" && -n "$MODEL_OVERRIDE" && -n "$CPID_OVERRIDE" ]] || {
        echo "--product, --board, and --cpid must be supplied together" >&2
        exit 64
    }
    PRODUCT="$PRODUCT_OVERRIDE"
    MODEL="$MODEL_OVERRIDE"
    CPID="$CPID_OVERRIDE"
    MODE="manual"
    PWND="not-required"
    MANUAL_DEVICE=1
else
    DEVICE_INFO="$("$IRECOVERY" -q)"
fi
field() {
    awk -F': ' -v key="$1" '$1 == key { print $2; exit }' <<<"$DEVICE_INFO"
}
if ((!MANUAL_DEVICE)); then
    PRODUCT="$(field PRODUCT)"
    MODEL="$(field MODEL)"
    CPID="$(field CPID)"
    MODE="$(field MODE)"
    PWND="$(field PWND)"
    ECID="$(field ECID)"
    NAME="$(field NAME)"
fi

[[ -n "$PRODUCT" && -n "$MODEL" && -n "$CPID" ]] || {
    echo "missing PRODUCT, MODEL, or CPID (or incomplete manual device arguments)" >&2
    echo "Connect a pwned-DFU device or pass --product, --board, and --cpid." >&2
    exit 1
}
if ((!MANUAL_DEVICE)); then
[[ "$MODE" == "DFU" ]] || {
    echo "builder requires DFU; device reports MODE=$MODE" >&2
    exit 1
}
[[ "$PWND" == "usbliter8" ]] || {
    echo "device must be pwned with usbliter8 (PWND: usbliter8); got PWND=${PWND:-none}" >&2
    exit 1
}
fi
nr_is_supported_cpid "$CPID" || {
    echo "unsupported CPID $CPID (this toolkit targets A12/A13: 0x8020 / 0x8030)" >&2
    exit 1
}
CHIP="$(nr_chip_for_cpid "$CPID")"
if [[ "$CHIP" == "A12X" ]]; then
    echo "warning: A12X (0x8027) — usbliter8 offsets TBD; proceed at your own risk" >&2
fi

echo "=== device ==="
echo "  name:     ${NAME:-unknown}"
echo "  product:  $PRODUCT"
echo "  board:    $MODEL"
echo "  cpid:     $CPID ($CHIP)"
echo "  ecid:     ${ECID:-unknown}"
echo "  mode:     $MODE"
echo "  pwnd:     $PWND"

API_JSON="$(curl --fail --silent --show-error --location \
    "https://api.ipsw.me/v4/device/$PRODUCT?type=ipsw")"

if ((LIST_ONLY)); then
    echo
    echo "=== firmwares for $PRODUCT ==="
    "$JQ" -r '.firmwares[] | "\(.version)\t\(.buildid)\t\(.releasedate // "")"' <<<"$API_JSON" \
        | sort -V | column -t -s $'\t'
    exit 0
fi

if [[ -z "$SELECTION" && -z "$DIRECT_URL" ]]; then
    INTERACTIVE=1
    echo
    echo "=== recent firmwares (pick a number, or type version/build) ==="
    FIRM_TMP="$(mktemp)"
    "$JQ" -r '
        [.firmwares | sort_by(.releasedate // "") | reverse[] |
         "\(.version)|\(.buildid)|\(.url)"][0:25][]
    ' <<<"$API_JSON" > "$FIRM_TMP"
    i=1
    while IFS= read -r line; do
        ver="${line%%|*}"
        rest="${line#*|}"
        build="${rest%%|*}"
        printf "  %2d) iOS %-12s  %s\n" "$i" "$ver" "$build"
        i=$((i + 1))
    done < "$FIRM_TMP"
    echo
    read -r -p "Firmware [number | version | build]: " SELECTION
    if [[ "$SELECTION" =~ ^[0-9]+$ ]]; then
        idx="$SELECTION"
        line="$(sed -n "${idx}p" "$FIRM_TMP")"
        [[ -n "$line" ]] || {
            echo "invalid selection index" >&2
            rm -f "$FIRM_TMP"
            exit 1
        }
        ver="${line%%|*}"
        rest="${line#*|}"
        BUILD="${rest%%|*}"
        IPSW_URL="${rest#*|}"
        VERSION="$ver"
        SELECTION="$BUILD"
    fi
    rm -f "$FIRM_TMP"
fi

if [[ -n "$DIRECT_URL" ]]; then
    IPSW_URL="$DIRECT_URL"
    BUILD="${SELECTION:-custom}"
    VERSION="unknown"
elif [[ -z "${IPSW_URL:-}" ]]; then
    MATCH="$("$JQ" -cer --arg selection "$SELECTION" '
        [.firmwares[] | select(.buildid == $selection or .version == $selection)][0]
        // empty
    ' <<<"$API_JSON")" || {
        echo "no IPSW match for $PRODUCT selection $SELECTION" >&2
        echo "hint: ./build.sh --list" >&2
        exit 1
    }
    IPSW_URL="$("$JQ" -r '.url' <<<"$MATCH")"
    BUILD="$("$JQ" -r '.buildid' <<<"$MATCH")"
    VERSION="$("$JQ" -r '.version' <<<"$MATCH")"
fi

[[ "$IPSW_URL" =~ ^https?:// ]] || {
    echo "invalid IPSW URL" >&2
    exit 1
}

CACHE="$NR_CACHE/$PRODUCT-$BUILD"
MANIFEST="$CACHE/BuildManifest.plist"
mkdir -p "$CACHE"
if [[ ! -s "$MANIFEST" ]]; then
    (
        cd "$CACHE"
        "$PZB" -g BuildManifest.plist "$IPSW_URL"
    )
fi

MANIFEST_INFO="$(python3 - "$MANIFEST" "$MODEL" <<'PY'
import plistlib
import sys
from pathlib import Path

manifest = plistlib.loads(Path(sys.argv[1]).read_bytes())
board = sys.argv[2]
identity = next(
    (item for item in manifest["BuildIdentities"]
     if item.get("Info", {}).get("DeviceClass") == board),
    None,
)
if identity is None:
    raise SystemExit(f"BuildManifest has no identity for {board}")

required = {
    "iBEC": "iBEC",
    "DeviceTree": "DeviceTree",
    "KernelCache": "KernelCache",
    "RestoreRamDisk": "RestoreRamDisk",
    "RestoreTrustCache": "RestoreTrustCache",
}
optional = {
    "iBSS": ("iBSS",),
    "RestoreSEP": ("RestoreSEP",),
    "SPTM": ("SPTM", "Ap,SPTM", "SecurePageTableMonitor", "RestoreSPTM"),
    "TXM": ("TXM", "Ap,TXM", "TrustedExecutionMonitor", "Ap,TrustedExecutionMonitor"),
    "AOP": ("AOP",),
    "ANE": ("ANE",),
    "AVE": ("AVE",),
    "ISP": ("ISP",),
    "GFX": ("GFX",),
    "SIO": ("SIO",),
    # A13 (t8030) only — skipped on A12 when absent from Manifest
    "PMP": ("PMP", "Ap,PMP"),
}
images = identity["Manifest"]
for output_name, manifest_name in required.items():
    path = images.get(manifest_name, {}).get("Info", {}).get("Path")
    if path is None:
        raise SystemExit(f"BuildManifest identity {board} has no {manifest_name} path")
    print(f"{output_name}={path}")
for output_name, candidates in optional.items():
    path = None
    for manifest_name in candidates:
        path = images.get(manifest_name, {}).get("Info", {}).get("Path")
        if path:
            break
    if path:
        print(f"{output_name}={path}")
print(f"ManifestBuild={identity['Info'].get('BuildNumber', '')}")
PY
)"

manifest_path() {
    awk -F= -v key="$1" '$1 == key { print substr($0, length(key) + 2); exit }' \
        <<<"$MANIFEST_INFO"
}

MANIFEST_BUILD="$(manifest_path ManifestBuild)"
echo
echo "=== parsed BuildManifest ($MODEL) ==="
echo "  manifest build: ${MANIFEST_BUILD:-unknown}"
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::group::BuildManifest component paths"
fi
sed '/^ManifestBuild=/d;s/^/  /;s/=/ : /' <<<"$MANIFEST_INFO" | sort
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::endgroup::"
fi
if [[ "$VERSION" != "unknown" && -n "$MANIFEST_BUILD" && "$MANIFEST_BUILD" != "$BUILD" ]]; then
    echo "BuildManifest build $MANIFEST_BUILD does not match selected build $BUILD" >&2
    exit 1
fi
[[ -n "$MANIFEST_BUILD" ]] && BUILD="$MANIFEST_BUILD"

HAS_IBSS=0
HAS_SPTM=0
HAS_TXM=0
[[ -n "$(manifest_path iBSS)" ]] && HAS_IBSS=1
[[ -n "$(manifest_path SPTM)" ]] && HAS_SPTM=1
[[ -n "$(manifest_path TXM)" ]] && HAS_TXM=1

# Resolve auto kpf-set from Manifest + iOS major.
# iOS 17/18/26 → Leeksov finder (ios18); 27+/TXM → ios27 (+ launch_constraints).
# Note: the old ios26 byte-offset table does not match j210/23F84 — do not auto-select it.
resolve_kpf_set() {
    local ver="$1" has_txm="$2"
    local major=""
    if [[ "$ver" =~ ^([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"
    fi
    if ((has_txm)) || [[ -n "$major" && "$major" -ge 27 ]]; then
        echo "ios27"
    elif [[ -n "$major" && "$major" -ge 17 ]]; then
        # 17 / 18 / 26: same AMFI + PE_i_can_has_debugger finder path
        echo "ios18"
    else
        echo "ios18"
    fi
}

if [[ "$KPF_SET" == "auto" ]]; then
    KPF_SET="$(resolve_kpf_set "$VERSION" "$HAS_TXM")"
    echo "kpf-set auto → $KPF_SET (iOS $VERSION, TXM=$HAS_TXM)"
fi

echo
echo "=== firmware ==="
echo "  iOS:      $VERSION ($BUILD)"
echo "  IPSW:     $IPSW_URL"
echo "  kernel:   $KERNEL_MODE (kpf-set=$KPF_SET)"
echo "  chain:    iBSS_in_ipsw=$HAS_IBSS use-ibss=$USE_IBSS SPTM=$HAS_SPTM TXM=$HAS_TXM with-fw=$WITH_FW"
if ((HAS_SPTM || HAS_TXM)); then
    echo "  note:     SPTM/TXM present in Manifest → will patch (typical iOS 27-class on A12/A13)"
else
    echo "  note:     no SPTM/TXM in Manifest (typical iOS 17/18/26 on A12/A13) — skip those layers"
fi
echo "  patches:  iBoot always; kernel=$KERNEL_MODE/$KPF_SET (Leeksov)"

if ((DRY_RUN)); then
    printf 'validated manifest members:\n'
    sed '/^ManifestBuild=/d;s/^/  /;s/=/:\ /' <<<"$MANIFEST_INFO" | sort
    exit 0
fi

if ((INTERACTIVE)); then
    read -r -p "Build this bootchain? [Y/n] " ans
    case "${ans:-Y}" in
        Y|y|yes|YES) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

IM4M="${IM4M_OVERRIDE:-$NR_RESOURCES/IM4M_$CPID}"
[[ -f "$IM4M" ]] || {
    echo "missing IM4M ticket: $IM4M" >&2
    echo "Provide one with --im4m /path/to/IM4M (or APTicket.der)." >&2
    exit 1
}
[[ -f "$NR_RESOURCES/ssh.tar.gz" ]] || {
    echo "missing SSH payload: $NR_RESOURCES/ssh.tar.gz" >&2
    exit 1
}
[[ -f "$NR_RESOURCES/sshtarlist.txt" ]] || {
    echo "missing trustcache append list: $NR_RESOURCES/sshtarlist.txt" >&2
    exit 1
}

fetch_member() {
    local member="$1"
    local destination="$CACHE/$(basename "$member")"
    [[ -s "$destination" ]] || (
        cd "$CACHE"
        "$PZB" -g "$member" "$IPSW_URL"
    )
    [[ -s "$destination" ]] || {
        echo "pzb did not produce $(basename "$member")" >&2
        exit 1
    }
    printf '%s\n' "$destination"
}

for key in iBEC DeviceTree KernelCache RestoreRamDisk RestoreTrustCache; do
    fetch_member "$(manifest_path "$key")" >/dev/null
done
if ((USE_IBSS)); then
    ((HAS_IBSS)) || { echo "--use-ibss requested but IPSW has no iBSS" >&2; exit 1; }
    fetch_member "$(manifest_path iBSS)" >/dev/null
fi
((HAS_SPTM)) && fetch_member "$(manifest_path SPTM)" >/dev/null
((HAS_TXM)) && fetch_member "$(manifest_path TXM)" >/dev/null
if ((WITH_FW)); then
    for key in AOP ANE AVE ISP GFX SIO; do
        [[ -n "$(manifest_path "$key")" ]] || {
            echo "BuildManifest missing $key (required by --with-fw)" >&2
            exit 1
        }
        fetch_member "$(manifest_path "$key")" >/dev/null
    done
    # PMP is A13-only; do not fail the build on A12.
    if [[ -n "$(manifest_path PMP)" ]]; then
        fetch_member "$(manifest_path PMP)" >/dev/null
    fi
fi
# Always stage RestoreSEP when present — boot.sh loads it via rsepfirmware.
if [[ -n "$(manifest_path RestoreSEP)" ]]; then
    fetch_member "$(manifest_path RestoreSEP)" >/dev/null
elif ((LIVE_DATA)); then
    echo "selected IPSW has no RestoreSEP component" >&2
    exit 1
fi

WORK="$NR_WORK/$PRODUCT-$BUILD"
OUT="$NR_WORK/out-$PRODUCT-$BUILD"
BOOTCHAIN_NAME="$MODEL-$VERSION-$BUILD-ramdisk"
BOOTCHAIN="$NR_BOOTCHAIN_ROOT/$BOOTCHAIN_NAME"
rm -rf "$WORK" "$OUT" "$BOOTCHAIN"
mkdir -p "$WORK" "$OUT" "$BOOTCHAIN" "$NR_WORK/sshtar"

for key in iBEC DeviceTree KernelCache RestoreRamDisk RestoreTrustCache; do
    cp "$CACHE/$(basename "$(manifest_path "$key")")" "$WORK/$key.im4p"
done
((USE_IBSS)) && cp "$CACHE/$(basename "$(manifest_path iBSS)")" "$WORK/iBSS.im4p"
((HAS_SPTM)) && cp "$CACHE/$(basename "$(manifest_path SPTM)")" "$WORK/SPTM.im4p"
((HAS_TXM)) && cp "$CACHE/$(basename "$(manifest_path TXM)")" "$WORK/TXM.im4p"
if ((WITH_FW)); then
    for key in PMP AOP ANE AVE ISP GFX SIO; do
        [[ -n "$(manifest_path "$key")" ]] || continue
        cp "$CACHE/$(basename "$(manifest_path "$key")")" "$WORK/$key.im4p"
    done
fi
if [[ -n "$(manifest_path RestoreSEP)" ]]; then
    cp "$CACHE/$(basename "$(manifest_path RestoreSEP)")" "$WORK/RestoreSEP.im4p"
fi

ipsw img4 im4p extract -o "$WORK/iBEC.raw" "$WORK/iBEC.im4p"
ipsw img4 im4p extract -o "$WORK/kernelcache.raw" "$WORK/KernelCache.im4p"
"$IMG4" -i "$WORK/RestoreRamDisk.im4p" -o "$WORK/ramdisk.dmg"

# --- iBoot (Leeksov + board finalize, boot-args rd=md0) ---
if ((USE_IBSS)); then
    ipsw img4 im4p extract -o "$WORK/iBSS.raw" "$WORK/iBSS.im4p"
    python3 "$NR_PATCH/iboot_patchfinder.py" \
        "$WORK/iBSS.raw" "$OUT/iBSS.patched.raw" --mode ibss
    # Same board finalize as iBEC when Leeksov slots exist (harmless no-op otherwise).
    python3 "$NR_PATCH/finalize_iboot.py" \
        --stock "$WORK/iBSS.raw" \
        --input "$OUT/iBSS.patched.raw" \
        --output "$BOOTCHAIN/iBSS.patched.bin" \
        --board "$MODEL" \
        || cp "$OUT/iBSS.patched.raw" "$BOOTCHAIN/iBSS.patched.bin"
    printf '1\n' > "$BOOTCHAIN/use-ibss"
    echo "patched iBSS (--use-ibss)"
fi

python3 "$NR_PATCH/iboot_patchfinder.py" "$WORK/iBEC.raw" "$OUT/iBEC.patched.raw" --mode ibec
python3 "$NR_PATCH/finalize_iboot.py" \
    --stock "$WORK/iBEC.raw" \
    --input "$OUT/iBEC.patched.raw" \
    --output "$OUT/iBoot.patched.bin" \
    --board "$MODEL"

# Typed IMG4 for Recovery-stage iBEC handoff after usbliter8ctl boots iBSS.
if ((USE_IBSS)); then
    "$IMG4" -i "$OUT/iBoot.patched.bin" -o "$BOOTCHAIN/iBEC.patched.img4" \
        -A -T ibec -M "$IM4M"
    echo "wrapped iBEC.patched.img4 for iBSS→iBEC handoff"
fi

# SPTM/TXM only when the IPSW ships them (README: iOS 27-class on A12/A13).
if ((HAS_SPTM)); then
    ipsw img4 im4p extract -o "$WORK/SPTM.raw" "$WORK/SPTM.im4p"
    python3 "$NR_PATCH/sptm_patchfinder.py" "$WORK/SPTM.raw" "$OUT/SPTM.patched.raw"
    "$IMG4" -i "$OUT/SPTM.patched.raw" -o "$BOOTCHAIN/sptm.img4" -A -T sptm -M "$IM4M"
    echo "patched SPTM"
fi
if ((HAS_TXM)); then
    ipsw img4 im4p extract -o "$WORK/TXM.raw" "$WORK/TXM.im4p"
    python3 "$NR_PATCH/txm_patchfinder.py" "$WORK/TXM.raw" "$OUT/TXM.patched.raw"
    "$IMG4" -i "$OUT/TXM.patched.raw" -o "$BOOTCHAIN/txm.img4" -A -T trst -M "$IM4M" \
        || "$IMG4" -i "$OUT/TXM.patched.raw" -o "$BOOTCHAIN/txm.img4" -A -M "$IM4M"
    echo "patched TXM"
fi

# --- Expand stock RestoreRamDisk, inject SSH (method A/B) ---
trap 'hdiutil detach -force /tmp/NewRamdiskRD >/dev/null 2>&1 || true' EXIT
# Inject ssh.tar.gz (includes mount_ich). On device after SSH: mount_ich
nr_expand_inject_ramdisk \
    "$WORK/ramdisk.dmg" \
    "$NR_RESOURCES/ssh.tar.gz" \
    /tmp/NewRamdiskRD \
    "$GTAR"
# Ensure ICH-branded restored_external (replaces SSHRD_Script splash/tag).
if [[ -f "$NR_RESOURCES/restored_external" ]]; then
    hdiutil attach -mountpoint /tmp/NewRamdiskRD -owners off \
        -imagekey diskimage-class=CRawDiskImage "$WORK/ramdisk.dmg" >/dev/null
    if [[ -d /tmp/NewRamdiskRD/usr/local/bin ]]; then
        cp "$NR_RESOURCES/restored_external" /tmp/NewRamdiskRD/usr/local/bin/restored_external
        chmod 755 /tmp/NewRamdiskRD/usr/local/bin/restored_external
        echo "installed ICH-branded restored_external (no SSHRD splash)"
    fi
    hdiutil detach -force /tmp/NewRamdiskRD >/dev/null 2>&1 || true
fi
trap - EXIT

# Trustcache: stock RestoreTrustCache + append injected SSH CDHashes.
# sshtarlist.txt paths are relative to project root: work/sshtar/...
"$IMG4" -i "$WORK/RestoreTrustCache.im4p" -o "$NR_WORK/trustcache.bin"
rm -rf "$NR_WORK/sshtar"
mkdir -p "$NR_WORK/sshtar"
"$GTAR" -x --no-overwrite-dir -f "$NR_RESOURCES/ssh.tar.gz" -C "$NR_WORK/sshtar"
(
    cd "$ROOT"
    # shellcheck disable=SC2046
    "$TC" append work/trustcache.bin $(<"resources/sshtarlist.txt")
)
cp "$NR_WORK/trustcache.bin" "$WORK/trustcache.bin"
echo "built trustcache via RestoreTrustCache + append"

# IMG4 + IM4M packaging (proven path for irecovery/bootx on A12).
"$IMG4" -i "$WORK/trustcache.bin" -o "$BOOTCHAIN/trustcache.img4" -A -T rtsc -M "$IM4M"
"$IMG4" -i "$WORK/ramdisk.dmg" -o "$BOOTCHAIN/ramdisk.img4" -A -T rdsk -M "$IM4M"
"$IMG4" -i "$WORK/DeviceTree.im4p" -o "$BOOTCHAIN/devicetree.img4" -T rdtr -M "$IM4M"

if ((WITH_FW)); then
    for component in PMP AOP ANE AVE ISP GFX SIO; do
        [[ -f "$WORK/$component.im4p" ]] || continue
        "$IMG4" -i "$WORK/$component.im4p" -o "$BOOTCHAIN/$component.img4" -M "$IM4M"
    done
    printf '1\n' > "$BOOTCHAIN/with-fw.enabled"
fi

wrap_kernel() {
    local raw_path="$1"
    local output_path="$2"
    python3 - "$raw_path" "$WORK/KernelCache.im4p" "$output_path" "$IM4M" <<'PY'
from pathlib import Path
import sys
from pyimg4 import Compression, IMG4, IM4M, IM4P, PayloadProperty

raw, original_path, output, im4m_path = map(Path, sys.argv[1:])
original = IM4P(original_path.read_bytes())
image = IM4P(fourcc="rkrn", description=original.description, payload=raw.read_bytes())
for prop in original.properties or []:
    image.add_property(PayloadProperty(fourcc=prop.fourcc, value=prop.value))
image.payload.compress(Compression.LZFSE)
output.write_bytes(IMG4(im4p=image, im4m=IM4M(im4m_path.read_bytes())).output())
print(f"wrote {output}")
PY
}

wrap_kernel "$WORK/kernelcache.raw" "$BOOTCHAIN/kernelcache.img4.stock"
python3 "$NR_PATCH/apply_kernel_patches.py" \
    "$WORK/kernelcache.raw" \
    --output "$OUT/kernelcache.patched.raw" \
    --kpf-set "$KPF_SET" \
    --allow-missing
wrap_kernel "$OUT/kernelcache.patched.raw" "$BOOTCHAIN/kernelcache.img4.patched"

if [[ "$KERNEL_MODE" == "patched" ]]; then
    cp "$BOOTCHAIN/kernelcache.img4.patched" "$BOOTCHAIN/kernelcache.img4"
else
    cp "$BOOTCHAIN/kernelcache.img4.stock" "$BOOTCHAIN/kernelcache.img4"
fi
printf '%s\n' "$KERNEL_MODE" > "$BOOTCHAIN/kernel.mode"
printf '%s\n' "$KPF_SET" > "$BOOTCHAIN/kpf.set"
cp "$OUT/iBoot.patched.bin" "$BOOTCHAIN/iBoot.patched.bin"
{
    echo "product=$PRODUCT"
    echo "model=$MODEL"
    echo "cpid=$CPID"
    echo "chip=$CHIP"
    echo "version=$VERSION"
    echo "build=$BUILD"
    echo "ibss=$USE_IBSS"
    echo "sptm=$HAS_SPTM"
    echo "txm=$HAS_TXM"
    echo "kernel=$KERNEL_MODE"
    echo "kpf_set=$KPF_SET"
    echo "with_fw=$WITH_FW"
    echo "packaging=img4-with-im4m"
    echo "trustcache=restore-append"
    echo "source=new_ramdisk"
    echo "nr_version=$NR_VERSION"
    echo "author=$NR_AUTHOR"
} > "$BOOTCHAIN/chain.info"

if [[ -f "$WORK/RestoreSEP.im4p" ]]; then
    "$IMG4" -i "$WORK/RestoreSEP.im4p" -o "$BOOTCHAIN/sep-firmware.img4" -M "$IM4M"
    echo "staged RestoreSEP → sep-firmware.img4 (boot.sh uses rsepfirmware)"
fi
if ((LIVE_DATA)); then
    printf '%s\n' '1' > "$BOOTCHAIN/live-data.enabled"
fi

# Device-specific signed boot logo for this board / panel → bootchain/logo.img4
echo "Building ICH logo for $MODEL (cpid=$CPID) → $BOOTCHAIN/logo.img4"
if NR_CPID="$CPID" "$ROOT/scripts/make_logo.sh" "$MODEL" --out "$BOOTCHAIN/logo.img4"; then
    echo "staged logo.img4 ($(wc -c <"$BOOTCHAIN/logo.img4") bytes)"
else
    echo "warning: logo build failed — boot.sh can rebuild at boot time" >&2
fi

PREFLIGHT=(
    python3 "$NR_PATCH/preflight.py"
    --bootchain "$BOOTCHAIN"
    --stock-iboot "$WORK/iBEC.raw"
    --expected-board "$MODEL"
    --expected-build "$BUILD"
    --kernel-mode "$KERNEL_MODE"
)
if [[ "$KERNEL_MODE" == "stock" ]]; then
    PREFLIGHT+=(--stock-kernel "$WORK/KernelCache.im4p")
else
    PREFLIGHT+=(--stock-kernel "$WORK/KernelCache.im4p" --allow-patched-kernel)
fi
"${PREFLIGHT[@]}"

# Drop scratch after a successful build (keep bootchain/ only).
rm -rf "$WORK" "$OUT" "$NR_WORK" "$CACHE" "$NR_CACHE"
echo "cleaned work/ and cache/"

printf '%s\n' "$BOOTCHAIN_NAME" > "$NR_LAST_BOOTCHAIN_FILE"

echo
echo "Built: $BOOTCHAIN"
echo "new_ramdisk $NR_VERSION by $NR_AUTHOR"
echo "Packaging: IMG4+IM4M | trustcache: RestoreTrustCache + append"
echo "Chain: use-ibss=$USE_IBSS iBEC=1 SPTM=$HAS_SPTM TXM=$HAS_TXM kernel=$KERNEL_MODE with-fw=$WITH_FW"
echo "Boot:  ./boot.sh"
if ((WITH_FW)); then
    echo "       ./boot.sh --with-fw   # (default if with-fw.enabled)"
fi
echo "SSH:   iproxy 2222 22   # then: ssh root@localhost -p 2222  (alpine)"
echo "After SSH: mount_ich          # mounts all filesystems"
nr_footer
