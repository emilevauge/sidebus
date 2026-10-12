#!/bin/sh
#
# Rings the phone with a real incoming call through Twilio, to test what Sidebus does
# with one: the Mac's notification, the caller's name, Answer and Decline.
#
#   mac/Scripts/ring-phone.sh +33612345678
#
# Goes through the Twilio CLI (brew install twilio, then twilio login once), and calls
# from the account's first number unless TWILIO_FROM names another. On a trial account,
# the called number must be verified in the Twilio console, and the call opens with
# Twilio's trial notice: press a key to hear the rest.
set -eu
TO="${1:?usage: $0 <phone number, international format>}"
command -v twilio >/dev/null || { echo "install the Twilio CLI: brew install twilio, then twilio login"; exit 1; }

FROM="${TWILIO_FROM:-$(twilio phone-numbers:list -o json | python3 -c 'import json,sys; n=json.load(sys.stdin); print(n[0]["phoneNumber"] if n else "")')}"
[ -n "$FROM" ] || { echo "no number on the Twilio account: buy one, or set TWILIO_FROM"; exit 1; }

TWIML='<Response><Say language="fr-FR">Appel de test Sidebus.</Say><Pause length="30"/><Say language="fr-FR">Fin du test.</Say></Response>'

twilio api:core:calls:create --to "$TO" --from "$FROM" --twiml "$TWIML" -o json \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print("calling from '"$FROM"':", r[0].get("status") if r else r)'
