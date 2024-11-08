#!/usr/bin/env bash
# Runs after the container is created.
set -x
pre-commit install
git config --global core.editor "code --wait"
git config --global credential.https://dev.azure.com.useHttpPath true
if [ "$(git rev-parse --is-shallow-repository)" != "false" ]; then
    git fetch --unshallow
fi
