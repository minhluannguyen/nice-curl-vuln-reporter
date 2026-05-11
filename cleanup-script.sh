#!/usr/bin/env bash
set -euo pipefail

DIR="./reports"

find "$DIR" -type l -name "*result" -delete
find "$DIR" -type l -name "*result-*" -delete
find "$DIR" -type f -name ".nixos-test-history" -delete