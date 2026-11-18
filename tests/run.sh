#!/bin/bash
# Runs every test. None of them touch the network or your real OneDrive config.
set -e
cd "$(dirname "$0")"
python3 -m unittest -q test_status test_folders
node model.test.js
python3 i18n_check.py
bash -n ../resync.sh && echo "resync.sh syntax ok"
bash test_resync.sh
