#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# build_lambda.sh
#
# Builds Lambda deployment artifacts for the trading simulator:
#   1. A Lambda Layer ZIP containing Python dependencies installed for the
#      manylinux2014_x86_64 platform (compatible with AWS Lambda's runtime).
#   2. A function ZIP containing the trading simulator source (.py files only).
#
# Usage:
#   ./scripts/build_lambda.sh
#
# Outputs (written to .build/):
#   trading-simulator-layer.zip  — Lambda Layer with pip-installed packages
#   trading-simulator.zip        — Lambda function source code
# -----------------------------------------------------------------------------

set -euo pipefail

BUILD_DIR=".build"
SRC_DIR="scripts/lambda/trading_simulator"

# Use python3.11 pip if available, fall back to pip3
if command -v python3.11 &>/dev/null; then
  PIP="python3.11 -m pip"
elif command -v pip3 &>/dev/null; then
  PIP="pip3"
else
  echo "ERROR: Neither python3.11 nor pip3 found." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate source directory
# ---------------------------------------------------------------------------
if [[ ! -d "$SRC_DIR" ]]; then
  echo "ERROR: Source directory '$SRC_DIR' does not exist." >&2
  exit 1
fi

if [[ ! -f "$SRC_DIR/requirements.txt" ]]; then
  echo "ERROR: '$SRC_DIR/requirements.txt' not found." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Prepare build directory
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# 1. Build Lambda Layer ZIP
# ---------------------------------------------------------------------------
echo "Building Lambda Layer..."

LAYER_DIR="$BUILD_DIR/layer/python/lib/python3.11/site-packages"
mkdir -p "$LAYER_DIR"

$PIP install \
  -r "$SRC_DIR/requirements.txt" \
  -t "$LAYER_DIR" \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.11 \
  --only-binary=:all: \
  --quiet

LAYER_ZIP="$BUILD_DIR/trading-simulator-layer.zip"

# Zip from inside the layer staging dir so archive paths start with python/
(cd "$BUILD_DIR/layer" && zip -r -q "../../$LAYER_ZIP" python)

# Clean up the temporary layer staging directory
rm -rf "$BUILD_DIR/layer"

# ---------------------------------------------------------------------------
# 2. Build function source ZIP
# ---------------------------------------------------------------------------
echo "Building Lambda function ZIP..."

FUNCTION_ZIP="$BUILD_DIR/trading-simulator.zip"

# Remove stale artifact if present
rm -f "$FUNCTION_ZIP"

# Zip only .py source files; exclude compiled bytecode, caches, and requirements
(
  cd "$SRC_DIR"
  zip -r -q \
    "../../../$FUNCTION_ZIP" \
    . \
    --include "*.py" \
    --exclude "*.pyc" \
    --exclude "__pycache__/*" \
    --exclude "requirements.txt"
)

# ---------------------------------------------------------------------------
# 3. Report output artifacts
# ---------------------------------------------------------------------------
echo ""
echo "Build complete. Artifacts:"
printf "  %-40s %s\n" "$LAYER_ZIP"    "$(du -sh "$LAYER_ZIP"    | cut -f1)"
printf "  %-40s %s\n" "$FUNCTION_ZIP" "$(du -sh "$FUNCTION_ZIP" | cut -f1)"
