#!/bin/bash
# Wrapper script for launchd-scheduled Zoom recording downloads.
# Runs hourly, downloads only recordings Zoom has finished processing, and
# posts a macOS notification with the result and the downloads folder size.
#
# Set ALWAYS_NOTIFY=1 to be notified on every run, not just on new files or errors.

set -uo pipefail

cd ~/Sandbox/zoom-recording-downloader

LOG="launchd.log"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-90}"
ALWAYS_NOTIFY="${ALWAYS_NOTIFY:-0}"
MAX_LOG_BYTES=$((5 * 1024 * 1024))

notify() {
    # Arguments are interpolated into AppleScript, so strip any double quotes.
    local title="${1//\"/}" msg="${2//\"/}"
    /usr/bin/osascript -e "display notification \"${msg}\" with title \"${title}\"" \
        >/dev/null 2>&1 || true
}

fail() {
    echo "### $1"
    notify "Zoom Downloader failed" "$1"
    exit 1
}

# Rotate the log before writing so hourly runs cannot grow it without bound.
if [[ -f "$LOG" ]] && (( $(stat -f%z "$LOG") > MAX_LOG_BYTES )); then
    mv -f "$LOG" "${LOG}.1"
fi

echo "=== $(date '+%Y-%m-%d %H:%M:%S') starting ==="

START_DATE=$(date -v-"${LOOKBACK_DAYS}"d +%Y-%m-%d)
END_DATE=$(date +%Y-%m-%d)

/opt/homebrew/bin/jq \
    --arg start "$START_DATE" \
    --arg end "$END_DATE" \
    '.Recordings.start_date = $start | .Recordings.end_date = $end' \
    zoom-recording-downloader.conf > tmp.json \
    || fail "could not update config dates"
mv tmp.json zoom-recording-downloader.conf

# Capture output so the run can be summarized, while still logging it in full.
RUN_OUTPUT=$(mktemp)
trap 'rm -f "$RUN_OUTPUT" tmp.json' EXIT

echo "1" | ./venv/bin/python zoom-recording-downloader.py --skip-existing 2>&1 \
    | tee "$RUN_OUTPUT"
STATUS=${PIPESTATUS[1]}

DOWNLOADED=$(grep -c '> Downloading' "$RUN_OUTPUT" || true)
PROCESSING=$(grep -c 'still processing at Zoom' "$RUN_OUTPUT" || true)
ERRORS=$(grep -c '^###' "$RUN_OUTPUT" || true)
SIZE=$(du -sh downloads 2>/dev/null | cut -f1 | tr -d ' ')
SIZE="${SIZE:-unknown}"

SUMMARY="${DOWNLOADED} new file(s), ${SIZE} total"
[[ "$PROCESSING" -gt 0 ]] && SUMMARY="${SUMMARY}, ${PROCESSING} still processing"

echo "=== $(date '+%Y-%m-%d %H:%M:%S') finished: exit=${STATUS} ${SUMMARY} ==="

if [[ "$STATUS" -ne 0 ]]; then
    notify "Zoom Downloader failed" "Exit ${STATUS}. ${SUMMARY}"
    exit "$STATUS"
fi

if [[ "$ERRORS" -gt 0 ]]; then
    notify "Zoom Downloader: ${ERRORS} error(s)" "$SUMMARY"
elif [[ "$DOWNLOADED" -gt 0 || "$ALWAYS_NOTIFY" == "1" ]]; then
    notify "Zoom Downloader" "$SUMMARY"
fi
