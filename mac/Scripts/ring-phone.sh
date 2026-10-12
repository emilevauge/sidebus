#!/bin/sh
#
# Rings the phone with a real incoming call through Twilio, to test what Sidebus does
# with one: the Mac's notification, the caller's name, Answer and Decline.
#
#   TWILIO_ACCOUNT_SID=AC... TWILIO_AUTH_TOKEN=... TWILIO_FROM=+1... \
#   mac/Scripts/ring-phone.sh +33612345678
#
# TWILIO_FROM is a number of the Twilio account. On a trial account, the called number
# must be verified in the Twilio console, and the call opens with Twilio's trial notice:
# press a key to hear the rest.
set -eu
TO="${1:?usage: $0 <phone number, international format>}"
: "${TWILIO_ACCOUNT_SID:?set TWILIO_ACCOUNT_SID}"
: "${TWILIO_AUTH_TOKEN:?set TWILIO_AUTH_TOKEN}"
: "${TWILIO_FROM:?set TWILIO_FROM, a number of the Twilio account}"

TWIML='<Response><Say language="fr-FR">Appel de test Sidebus.</Say><Pause length="30"/><Say language="fr-FR">Fin du test.</Say></Response>'

curl -sS -X POST "https://api.twilio.com/2010-04-01/Accounts/$TWILIO_ACCOUNT_SID/Calls.json" \
    -u "$TWILIO_ACCOUNT_SID:$TWILIO_AUTH_TOKEN" \
    --data-urlencode "To=$TO" \
    --data-urlencode "From=$TWILIO_FROM" \
    --data-urlencode "Twiml=$TWIML" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("status") or r.get("message"))'
