set export

# List justfile targets
list:
    @just --list

# Update flake
update:
    #!/usr/bin/env bash
    export NIX_CONFIG="access-tokens = github.com=$(op item get "Github PAT" --fields label=password --reveal --cache)"
    nix flake update --commit-lock-file
