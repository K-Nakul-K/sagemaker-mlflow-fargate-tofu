#!/usr/bin/env bash
set -euo pipefail

# Tofu/Terraform equivalent of the CDK deploy_stack.sh.
# Requires: opentofu (or terraform), aws cli, and a container CLI (docker or podman) for the image build/push.
#
# Usage:
#   ./deploy_stack.sh [apply|destroy] [project_name]
# Examples:
#   ./deploy_stack.sh                 # apply with project_name=mlflow
#   ./deploy_stack.sh apply myproj    # apply with project_name=myproj
#   ./deploy_stack.sh destroy         # destroy the mlflow stack

ACTION="${1:-apply}"
PROJECT_NAME="${2:-mlflow}"

case "$ACTION" in
  apply | destroy) ;;
  *)
    echo "Invalid action '$ACTION'. Use 'apply' or 'destroy'." >&2
    exit 1
    ;;
esac

# Auto-detect a container CLI (override with CONTAINER_CLI env var).
if [ -n "${CONTAINER_CLI:-}" ]; then
  :
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CLI=docker
elif command -v podman >/dev/null 2>&1; then
  CONTAINER_CLI=podman
else
  echo "No container CLI found (need docker or podman on PATH)." >&2
  exit 1
fi

# Pick tofu if available, otherwise terraform.
if command -v tofu >/dev/null 2>&1; then
  TF=tofu
elif command -v terraform >/dev/null 2>&1; then
  TF=terraform
else
  echo "Neither tofu nor terraform found on PATH." >&2
  exit 1
fi

# Terraform/OpenTofu code lives in the tofu/ subfolder.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/tofu"

"$TF" init

if [ "$ACTION" = "destroy" ]; then
  "$TF" destroy -auto-approve -var "project_name=${PROJECT_NAME}" -var "container_cli=${CONTAINER_CLI}"
  echo
  echo "Destroyed stack for project '${PROJECT_NAME}'."
  exit 0
fi

"$TF" apply -auto-approve -var "project_name=${PROJECT_NAME}" -var "container_cli=${CONTAINER_CLI}"

echo
echo "MLflow tracking server URL:"
"$TF" output -raw mlflow_url
echo
