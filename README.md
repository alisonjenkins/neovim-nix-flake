# neovim-nix-flake
My Neovim config and environment ported to a Nix Flake

## GitHub Actions

This repository includes several GitHub Actions workflows:

- **build-and-cache.yaml**: Builds the Nix flake and caches it to Cachix on push to main
- **update.yaml**: Updates the flake lock file on a schedule or manual trigger
- **trigger-nix-config-update.yaml**: Triggers the "Update and push flake lock" action on the `alisonjenkins/nix-config` repository when changes are merged to main

### Setup for trigger-nix-config-update.yaml

To enable the workflow that triggers updates on the nix-config repository, you need to:

1. Create a GitHub Personal Access Token (PAT) with one of the following:
   - Classic token with `repo` scope, OR
   - Fine-grained token with `Actions: Read and write` permission for the `alisonjenkins/nix-config` repository

2. Add this token as a repository secret:
   - Go to Settings → Secrets and variables → Actions
   - Create a new secret named `NIX_CONFIG_TRIGGER_TOKEN`
   - Paste the PAT as the value

3. Ensure the `alisonjenkins/nix-config` repository has a workflow that listens for the `repository_dispatch` event with `event_type: update-flake-lock`
