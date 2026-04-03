#!/bin/bash
set -euo pipefail

DIR="./reports"

find "$DIR" -type f -name "*.qcow2" -not -path "*/disks/*" -delete
find "$DIR" -type l -name "*result" -delete
find "$DIR" -type l -name "*result-*" -delete
find "$DIR" -type f -name ".nixos-test-history" -delete