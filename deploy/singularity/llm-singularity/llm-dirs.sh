#!/bin/bash
# Canonical directory layout for the LLM Singularity deployment.
#
# Source this file AFTER LLM_BASE_DIR is set. This file is intentionally
# silent: no echo, no mkdir, no side effects — only variable declarations.
# Directory creation is the responsibility of the script that sources this file.
#
# Shared paths (persist across jobs and users):
#   LLM_IMAGES_DIR    — SIF container images (read-only at runtime)
#   LLM_CACHE_DIR     — Singularity pull cache
#   LLM_MODELS_DIR    — Model weight caches (downloaded once, read by all)
#   LLM_SESSIONS_DIR  — Per-user session directories (job isolation)

# ==============================================================================
# Base directory (required)
# ==============================================================================
export LLM_BASE_DIR="${LLM_BASE_DIR:?LLM_BASE_DIR must be set}"
LLM_BASE_DIR="${LLM_BASE_DIR%/}"

# ==============================================================================
# Container infrastructure (shared, read-only at runtime)
# ==============================================================================
export LLM_IMAGES_DIR="$LLM_BASE_DIR/containers/images"
export LLM_CACHE_DIR="$LLM_BASE_DIR/containers/cache"
export SINGULARITY_CACHEDIR="$LLM_CACHE_DIR"

# ==============================================================================
# Model weight caches (shared, downloaded once per model)
# ==============================================================================
export LLM_MODELS_DIR="$LLM_BASE_DIR/models"

# ==============================================================================
# Session directories (per-user, per-job isolation)
# ==============================================================================
export LLM_SESSIONS_DIR="$LLM_BASE_DIR/sessions"
