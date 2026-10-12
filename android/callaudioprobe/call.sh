#!/bin/sh
# Places a call from the Mac and bridges its audio, until the call ends.
#
#   ./call.sh <number> [phone Bluetooth address] [RFCOMM channel]
#   PHONE_MIC=on ./call.sh <number>     leave the phone's microphone on
#
# The call goes out over HFP (HandsFreeProbe), the audio over adb (CallAudioProbe's
# stream mode on the phone, CallAudioBridge on the Mac). Hang up on the phone, or
# press Ctrl-C here.
set -e
# Spaces and dots are fine inside quotes: "06 12 34 56 78".
NUMBER=$(printf %s "$1" | tr -d ' .')
[ $# -le 3 ] || { echo "too many arguments: quote the number, as in \"06 12 34 56 78\""; exit 1; }
ADDRESS="${2:-64-63-06-5c-68-56}"
CHANNEL="${3:-8}"
[ -n "$NUMBER" ] || { echo "usage: $0 <number> [address] [channel]"; exit 1; }

# The first physical device, emulators aside, unless ANDROID_SERIAL says otherwise.
if [ -z "$ANDROID_SERIAL" ]; then
    ANDROID_SERIAL=$(adb devices | awk 'NR > 1 && $2 == "device" && $1 !~ /^emulator-/ { print $1; exit }')
    export ANDROID_SERIAL
fi
[ -n "$ANDROID_SERIAL" ] || { echo "no phone on adb"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
MAC="$HERE/../../mac"
(cd "$MAC" && swift build --product CallAudioBridge >/dev/null && swift build --product HandsFreeProbe >/dev/null)

cleanup() {
    kill "$PHONE" "$BRIDGE" 2>/dev/null || true
    adb shell pkill -f CallAudioProbe 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [ "$PHONE_MIC" = on ]; then
    "$HERE/run.sh" stream nomute &
else
    "$HERE/run.sh" stream &
fi
PHONE=$!
sleep 6
"$MAC/.build/debug/CallAudioBridge" &
BRIDGE=$!
sleep 2

# Dial, then wait for the call to start and to end.
{
    sleep 4
    echo "dial $NUMBER"
    started=0
    while :; do
        sleep 1
        # One mCallState per SIM: the call is on while any of them is not idle.
        if adb shell dumpsys telephony.registry | grep mCallState | grep -qv "mCallState=0"; then
            started=1
        elif [ "$started" = 1 ]; then
            break
        fi
    done
    echo quit
} | "$MAC/.build/debug/HandsFreeProbe" "$ADDRESS" "$CHANNEL" | grep --line-buffered -E "call active|call setup: [23]"

echo "call ended"
