#!/bin/bash
# Double-click: builds Notch Island and installs it to ~/Applications.
cd "$(dirname "$0")"
if ./build.sh; then
  echo ""
  echo "✓ Done. Notch Island is running – point your mouse at the notch."
else
  echo ""
  echo "✗ Something went wrong. See build.log for details."
fi
echo "You can close this window."
