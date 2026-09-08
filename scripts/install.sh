#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$project_dir/scripts/build-app.sh"

applications_dir="$HOME/Applications"
destination="$applications_dir/QuotaBar.app"
mkdir -p "$applications_dir"
ditto "$project_dir/dist/QuotaBar.app" "$destination"
codesign --verify --strict "$destination"
open "$destination"

echo "Installed $destination"
