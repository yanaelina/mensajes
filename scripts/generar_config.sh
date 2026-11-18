#!/usr/bin/env bash
# Genera frontend/config.js con las salidas de Terraform.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "window.CONFIG = $(terraform -chdir=terraform output -json config_frontend);" > frontend/config.js
echo "Listo: frontend/config.js"
cat frontend/config.js
