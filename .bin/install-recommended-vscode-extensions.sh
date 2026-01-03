#!/bin/bash
set -euxo pipefail

# Path to the extensions.json file
EXTENSIONS_FILE=../.vscode/extensions.json

# Pre Install ShellCheck
sudo apt install -y shfmt

# Check if extensions.json exists
if [ ! -f "$EXTENSIONS_FILE" ]; then
  echo "extensions.json file not found: $EXTENSIONS_FILE"
  exit 1
fi

# Read recommendations and install each extension
for ext in $(jq -r '.recommendations[]' "$EXTENSIONS_FILE"); do
  echo "Installing extension: $ext"
  code --install-extension "$ext"
done

echo "All extensions have been installed."
