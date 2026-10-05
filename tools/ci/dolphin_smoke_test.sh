#!/usr/bin/env bash
# Boot a built main.dol in headless Dolphin for a few seconds and check that
# the emulated game did not crash.
#
# Usage: dolphin_smoke_test.sh <extracted-game-dir> <built-main.dol> [seconds] [log-dir]
#
# <extracted-game-dir> is the output of Dolphin's "Extract Entire Disc". Its
# sys/main.dol is replaced with <built-main.dol> and the directory is booted
# as a disc (Dolphin's DirectoryBlob support).
#
# Set DOLPHIN to override the emulator command (default: Flathub's
# dolphin-emu-nogui).

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <extracted-game-dir> <built-main.dol> [seconds] [log-dir]" >&2
    exit 2
fi

game_dir=$(realpath "$1")
built_dol=$(realpath "$2")
seconds=${3:-30}
log_dir=$(realpath -m "${4:-dolphin-logs}")

mkdir -p "$log_dir"
user_dir=$(mktemp -d)
trap 'rm -rf "$user_dir"' EXIT

# Wii extractions keep the game partition under DATA/; prefer it if present.
boot_dol=$(find "$game_dir" -path '*/DATA/sys/main.dol' -print -quit)
if [ -z "$boot_dol" ]; then
    boot_dol=$(find "$game_dir" -path '*/sys/main.dol' -print -quit)
fi
if [ -z "$boot_dol" ]; then
    echo "::error::No sys/main.dol found under $game_dir" >&2
    exit 1
fi
echo "Booting $boot_dol (replaced with $built_dol)"
cp "$built_dol" "$boot_dol"

if [ -n "${DOLPHIN:-}" ]; then
    read -r -a dolphin_cmd <<< "$DOLPHIN"
else
    dolphin_cmd=(flatpak run
        "--filesystem=$game_dir"
        "--filesystem=$user_dir"
        --command=dolphin-emu-nogui
        org.DolphinEmu.dolphin-emu)
fi

dolphin_args=(
    --user="$user_dir"
    --platform=headless
    --video_backend=Null
    --config=Dolphin.Interface.UsePanicHandlers=False
    --config=Dolphin.Interface.ConfirmStop=False
    "--config=Dolphin.DSP.Backend=No Audio Output"
    --config=Dolphin.Analytics.PermissionAsked=True
    --config=Dolphin.Analytics.Enabled=False
    --config=Logger.Options.WriteToFile=True
    --config=Logger.Options.WriteToConsole=True
    --config=Logger.Options.Verbosity=4
    --config=Logger.Logs.BOOT=True
    --config=Logger.Logs.CORE=True
    --config=Logger.Logs.OSREPORT=True
    --config=Logger.Logs.OSREPORT_HLE=True
    --config=Logger.Logs.PowerPC=True
    --config=Logger.Logs.MI=True
    --config=Logger.Logs.EXI=True
    --exec="$boot_dol"
)

echo "Running for ${seconds}s: ${dolphin_cmd[*]} ${dolphin_args[*]}"
set +e
timeout --kill-after=10 "$seconds" "${dolphin_cmd[@]}" "${dolphin_args[@]}" \
    > "$log_dir/stdout.log" 2>&1
rc=$?
set -e

cp -r "$user_dir/Logs/." "$log_dir/" 2>/dev/null || true
echo "---- Dolphin output (last 100 lines) ----"
tail -n 100 "$log_dir/stdout.log" || true
echo "-----------------------------------------"

failed=0
# 124: still running when the timeout hit, which is what we want.
if [ "$rc" -ne 124 ]; then
    echo "::error::Dolphin exited after less than ${seconds}s (exit code $rc)"
    failed=1
fi

crash_pattern='Invalid (read|write) (from|to)|Unknown instruction|Unhandled exception|PanicAlert|Segmentation fault|ISI exception|DSI exception|Program exception'
if grep -h -E -m 20 "$crash_pattern" "$log_dir"/*.log; then
    echo "::error::Crash indicators found in Dolphin logs (see above)"
    failed=1
fi

if [ "$failed" -eq 0 ]; then
    echo "Game ran for ${seconds}s without crashing."
fi
exit "$failed"
