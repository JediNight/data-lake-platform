#!/usr/bin/env bash
# scripts/package-lambda.sh — Build Lambda deployment ZIP
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PRODUCER_DIR="$PROJECT_DIR/producer-api"
BUILD_DIR="$PROJECT_DIR/.build/lambda-producer"
ZIP_PATH="$PROJECT_DIR/.build/lambda-producer.zip"

echo "==> Cleaning build directory"
rm -rf "$BUILD_DIR" "$ZIP_PATH"
mkdir -p "$BUILD_DIR"

echo "==> Installing dependencies"
pip install -q -r "$PRODUCER_DIR/app/requirements.txt" -t "$BUILD_DIR"

echo "==> Copying application code"
cp -r "$PRODUCER_DIR/app" "$BUILD_DIR/app"
cp "$PRODUCER_DIR/handler.py" "$BUILD_DIR/handler.py"

echo "==> Creating ZIP"
cd "$BUILD_DIR"
zip -q -r "$ZIP_PATH" . -x "*/__pycache__/*" "*.pyc"

echo "==> Lambda package: $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
