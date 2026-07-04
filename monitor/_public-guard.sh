#!/usr/bin/env bash
# Public-template disable switch.
#
# This template ships DISABLED on purpose: a casual
# `./nexus` / `./watcher`, a `monitor/svc.sh up`, or the bootstrap
# installer must NOT be able to spin up autonomous Claude Code
# workers by accident. Every start entry point calls
# `nexus_public_guard` before doing any real bring-up work.
#
# It defaults to unset (disabled). Sourcing this file is
# side-effect-free — it only defines the function; the guard fires
# only where it is called.

nexus_public_guard() {
    if [[ "${NEXUS_PUBLIC_ENABLED:-}" == "1" ]]; then
        return 0
    fi
    cat >&2 <<'DISABLED'
nexus is disabled: this template is not intended for public use.
DISABLED
    exit 1
}
