#!/bin/bash
# Canonical directory layout for the NIM Singularity deployment.
#
# Source this file AFTER NIM_BASE_DIR is set. This file is intentionally
# silent: no echo, no mkdir, no side effects — only variable declarations.
# Directory creation is the responsibility of the script that sources this file.
#
# Shared paths (persist across jobs and users):
#   NIM_IMAGES_DIR    — SIF container images (read-only at runtime)
#   NIM_CACHE_DIR     — Singularity pull cache
#   NIM_MODELS_DIR    — Model weight caches (downloaded once, read by all)
#   NIM_SESSIONS_DIR  — Per-user session directories (job isolation)

# ==============================================================================
# Base directory (required)
# ==============================================================================
export NIM_BASE_DIR="${NIM_BASE_DIR:?NIM_BASE_DIR must be set}"

# ==============================================================================
# Container infrastructure (shared, read-only at runtime)
# ==============================================================================
export NIM_IMAGES_DIR="$NIM_BASE_DIR/containers/images"
export NIM_CACHE_DIR="$NIM_BASE_DIR/containers/cache"
export SINGULARITY_CACHEDIR="$NIM_CACHE_DIR"

# ==============================================================================
# Model weight caches (shared, downloaded once per model)
# ==============================================================================
export NIM_MODELS_DIR="$NIM_BASE_DIR/models"

# ==============================================================================
# Session directories (per-user, per-job isolation)
# ==============================================================================
export NIM_SESSIONS_DIR="$NIM_BASE_DIR/sessions"
