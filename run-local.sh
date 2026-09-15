#!/bin/sh

set -e

cd "$(dirname "$0")"

if [ ! -f ".env" ]; then
  echo "Missing .env file."
  echo
  echo "Create .env with:"
  echo "CANVAS_TOKEN='your-token'"
  echo "TOKEN_EXPIRES='YYYY-MM-DD'"
  exit 1
fi

set -a
. ./.env
set +a

exec ruby app.rb