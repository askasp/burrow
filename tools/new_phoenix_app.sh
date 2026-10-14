#!/usr/bin/env bash
# Generates a Phoenix LiveView + SQLite app with email/password auth.
# Usage: tools/new_phoenix_app.sh <dir> <otp_app> <Module>
set -euo pipefail
dir=$1 otp=$2 mod=$3
tools=$(cd "$(dirname "$0")" && pwd)
parent=$(dirname "$dir")
mkdir -p "$parent"
cd "$parent"
mix phx.new "$otp" --module "$mod" --database sqlite3 --no-gettext --no-dashboard --no-install >/dev/null
[ "$(basename "$dir")" = "$otp" ] || mv "$otp" "$(basename "$dir")"
cd "$(basename "$dir")"
mix deps.get >/dev/null
mix phx.gen.auth Accounts User users --live </dev/null >/dev/null
mix deps.get >/dev/null
python3 "$tools/password_auth.py" . "$mod" "$otp"
mix format
