# AGENTS.md - Persistent Project Memory

## Overview
Droidspaces RootFS Builder builds rootfs tarballs for [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) from Dockerfiles, publishes them as GitHub releases, and regenerates `rootfs.json` on release.

## Repository Architecture & Structure
```
archs.json                  # Supported architectures -> docker platform + GitHub Actions runner
build.sh                    # Build script for one template for one arch (CI/Remote use)
templates/<arch>/*.Dockerfile # Distro templates per architecture
scripts/generate_rootfs_json.py # Metadata parser, label linter, and rootfs.json generator
rootfs.json                 # Auto-generated catalog of available images (do not manually edit)
.github/workflows/          # GitHub Actions workflows for CI/CD
```

## Tech Stack
- **Docker / Buildx**: Multi-stage Docker builds exporting rootfs tarballs
- **Python 3**: Label linting and `rootfs.json` generation
- **Bash / Shell**: Build orchestration
- **GitHub Actions**: Remote matrix builds, GitHub Releases publishing, and asset cleanup

## Template Requirements & Conventions
- Distro Dockerfiles reside in `templates/<arch>/<Name>.Dockerfile`.
  - Supported distributions include: Alpine, Arch, Artix, Azure Linux, Debian, Fedora, Kali, OpenWrt, Ubuntu.
- The final build stage must be named `export` (`FROM scratch AS export`) and must provide required metadata labels:
  - `droidspaces.name`: Display name
  - `droidspaces.distro`: Distribution family (e.g., Ubuntu, Debian, Arch)
  - `droidspaces.description`: Description of rootfs image
  - `droidspaces.author`: Author name (defaults to "Droidspaces developers")
- Any additional `droidspaces.<key>` label is copied into `rootfs.json` entry under `<key>`.
- Build context is repository root (`COPY scripts/...` is valid).

## CI/CD Workflows & GitHub CLI Commands
All builds are offloaded to GitHub Actions.
- **Lint template labels locally (safe/lightweight):**
  ```sh
  python3 scripts/generate_rootfs_json.py --lint
  ```
- **Trigger Full CI Build & Release:**
  ```sh
  gh workflow run build-rootfs-releases.yml --ref <branch>
  ```
- **Trigger `rootfs.json` update only (without full rebuild):**
  ```sh
  gh workflow run build-rootfs-releases.yml -f update_json_only=true
  ```
- **Monitor Workflow Runs:**
  ```sh
  gh run list --workflow=build-rootfs-releases.yml
  gh run watch <run-id>
  gh run view <run-id> --log-failed
  ```

## Hardware & Environment Rules
- **No Local Builds:** Local environment runs inside Linux on an Android device with limited CPU, RAM, and thermal headroom. Never run Docker builds, heavy compression, or container emulation locally.
- **Local Scope:** File editing, lightweight static checks/linting (`python3 scripts/generate_rootfs_json.py --lint`), Git, and GitHub CLI (`gh`).
