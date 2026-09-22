#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
"$PROJECT_DIR/scripts/build-app.sh"
open "$PROJECT_DIR/dist/Mijine Bar.app"
