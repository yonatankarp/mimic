#!/usr/bin/env bash
# Double-click to install Mimic. It opens this window, installs everything, then opens Mimic.
cd "$(dirname "$0")"
/bin/bash ./setup.sh "$@"
status=$?
echo
read -r -p "Press Enter to close this window. " _
exit $status
