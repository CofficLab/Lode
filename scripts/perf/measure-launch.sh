#!/bin/bash
# Cold-launch measurement for Lode.
#
# Launches a built Lode.app repeatedly and reads the launch-phase history the
# app persists to UserDefaults (DatabaseManager.launchHistory), then reports
# per-phase medians. Assembly and firstWindow are recorded on every launch;
# firstConnection only when a saved connection auto-reconnects.
#
# Usage: scripts/perf/measure-launch.sh /path/to/Lode.app [iterations]
#
# The assembly baseline for the CI budget gate lives in
# scripts/perf/launch-baseline.json and is regenerated with:
#   LODE_PERF_MEASURE=1 xcodebuild test -project Lode.xcodeproj -scheme Lode \
#       -only-testing:LodeTests/LaunchBudgetGateTests/testMeasureAssemblyBaseline \
#       -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
set -euo pipefail

APP_PATH="${1:?usage: measure-launch.sh /path/to/Lode.app [iterations]}"
ITERATIONS="${2:-5}"
BUNDLE_ID="com.coffic.lode"
HISTORY_KEY="DatabaseManager.launchHistory"

if [ ! -d "$APP_PATH" ]; then
    printf 'error: app not found at %s\n' "$APP_PATH" >&2
    exit 1
fi

read_history() {
    defaults export "$BUNDLE_ID" - 2>/dev/null | HISTORY_KEY="$HISTORY_KEY" python3 -c '
import sys, os, plistlib, json
try:
    plist = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    print("[]")
    sys.exit(0)
data = plist.get(os.environ["HISTORY_KEY"])
if isinstance(data, bytes):
    try:
        print(json.dumps(json.loads(data)))
        sys.exit(0)
    except Exception:
        pass
print("[]")
'
}

quit_app() {
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    sleep 2
}

ACCUM="$(mktemp)"
trap 'rm -f "$ACCUM"' EXIT

for i in $(seq 1 "$ITERATIONS"); do
    quit_app
    before="$(read_history | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')"
    open "$APP_PATH"
    records="[]"
    for _ in $(seq 1 30); do
        sleep 1
        records="$(read_history)"
        count="$(printf '%s' "$records" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')"
        if [ "$count" -gt "$before" ]; then
            break
        fi
    done
    printf '%s\n' "$records" | python3 -c "
import sys, json
records = json.load(sys.stdin)
for record in records[$before:]:
    print(json.dumps(record))
" >> "$ACCUM"
    printf 'launch %s/%s captured\n' "$i" "$ITERATIONS"
    quit_app
done

python3 - "$ACCUM" <<'EOF'
import json, sys

records = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
phases = {}
for record in records:
    phases.setdefault(record["phase"], []).append(record["durationMs"])

print("=== Cold-launch medians ===")
for phase, durations in sorted(phases.items()):
    durations.sort()
    median = durations[len(durations) // 2]
    print(f"{phase}: n={len(durations)} median={median:.1f}ms max={durations[-1]:.1f}ms")
if not phases:
    print("(no launch records captured)")
EOF