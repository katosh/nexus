#!/usr/bin/env bash
# labsh-root.sh — run any labsh verb against the ROOT work-root
# JupyterLab from anywhere, typically from inside work/<project>.
#
#   monitor/labsh-root.sh notebook attach analysis.ipynb --kernel-name proj-<project>
#   monitor/labsh-root.sh kernel exec -n analysis.ipynb 'CODE'
#   monitor/labsh-root.sh url
#
# Why this exists: labsh anchors on $PWD — server discovery, the helper
# venv, and the auth token all live under ./.jupyter. The root session's
# .jupyter lives at the WORK ROOT, so a bare `labsh notebook attach` (or
# a first `labsh kernel exec`) inside work/<project> cannot see the root
# server. This wrapper points the two env knobs labsh honours
# (JUPYTER_CONFIG_DIR / JUPYTER_DATA_DIR) at the work root and execs
# labsh. Relative notebook paths still resolve against YOUR cwd, and the
# root server adopts the notebook because its root_dir contains it.
#
# CAUTION: lifecycle verbs pass through too — `labsh-root.sh stop` stops
# the SHARED root server (its supervisor will bounce it within ~45 s,
# losing everyone's kernels). Project agents should stick to
# kernel/notebook/url/token verbs.
#
# ENV:
#   NEXUS_WORKROOT — override the work root (tests/fixtures).
#   NEXUS_ROOT     — as elsewhere (default: this script's own checkout);
#                    work root defaults to $NEXUS_ROOT/work.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_script_dir/.." && pwd)}"
WORKROOT="${NEXUS_WORKROOT:-$NEXUS_ROOT/work}"

[[ -d "$WORKROOT/.jupyter" ]] || {
    echo "labsh-root: no root session state at $WORKROOT/.jupyter — activate it first: monitor/jupyter-up.sh --root" >&2
    exit 1
}

export JUPYTER_CONFIG_DIR="$WORKROOT/.jupyter"
export JUPYTER_DATA_DIR="$WORKROOT/.jupyter/share/jupyter"
exec labsh "$@"
