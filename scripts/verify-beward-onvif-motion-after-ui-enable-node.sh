#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-node}"
STREAMS="${EVENT_STREAMS:-onvif2,onf}"
SECONDS_TO_LISTEN="${SECONDS_TO_LISTEN:-180}"
OUT_DIR="${OUT_DIR:-/tmp/newdomofon-beward-onvif-motion-verify-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

RULES_SCRIPT="/tmp/diagnose-onvif-analytics-rules-node.sh"
LIVE_SCRIPT="/tmp/diagnose-onvif-live-ruleengine-node.sh"

if [ ! -s "$RULES_SCRIPT" ]; then
  curl --retry 5 --retry-delay 2 --connect-timeout 20 --max-time 120 -fsSL \
    "https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main/scripts/diagnose-onvif-analytics-rules-node.sh?nocache=$(date +%s%N)" \
    -o "$RULES_SCRIPT"
fi
if [ ! -s "$LIVE_SCRIPT" ]; then
  curl --retry 5 --retry-delay 2 --connect-timeout 20 --max-time 120 -fsSL \
    "https://raw.githubusercontent.com/rirodevdom/newdomofon-video/main/scripts/diagnose-onvif-live-ruleengine-node.sh?nocache=$(date +%s%N)" \
    -o "$LIVE_SCRIPT"
fi
chmod +x "$RULES_SCRIPT" "$LIVE_SCRIPT"

echo "---- 1/2: checking ONVIF analytics rules ----"
EVENT_STREAMS="$STREAMS" OUT_DIR="$OUT_DIR/rules" bash "$RULES_SCRIPT" | tee "$OUT_DIR/rules.stdout.log" || true

echo "---- rules summary ----"
grep -RniE 'GetRulesResponse|<[^>]*Rule[ >]|MotionRegion|MotionRegionDetector|RuleNotification|RuleEngineConfiguration' "$OUT_DIR/rules" | head -250 || true

echo "---- 2/2: listening PullPoint for ${SECONDS_TO_LISTEN}s ----"
echo "Now create real movement in front of the camera."
EVENT_STREAMS="$STREAMS" SECONDS="$SECONDS_TO_LISTEN" OUT_DIR="$OUT_DIR/live" bash "$LIVE_SCRIPT" | tee "$OUT_DIR/live.stdout.log" || true

echo "---- motion change summary ----"
if grep -RniE '"operation":"Changed"|PropertyOperation="Changed"|"State":"true"|Name="State" Value="true"|"IsMotion":"true"|Name="IsMotion" Value="true"' "$OUT_DIR/live" | head -250; then
  echo "OK: ONVIF changed motion event found. DVR collector should be able to store onvif.motion events."
else
  echo "NO_CHANGED_MOTION: no PropertyOperation=Changed with State/IsMotion=true was found. Camera still does not publish real motion changes via ONVIF."
fi

echo "OUT_DIR=$OUT_DIR"
echo "Remove credentials later: find '$OUT_DIR' -type f -name cameras.json -delete"
