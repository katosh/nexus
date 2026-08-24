# Extract, for the head sha, the (workflow, status, conclusion, attempt, id) of
# EVERY run.
#
# Input: the body of `GET /repos/{owner}/{repo}/actions/runs?head_sha=<sha>`.
# Output: one run per line, TAB-separated:
#   `path<TAB>status<TAB>conclusion<TAB>run_attempt<TAB>run_id`
# (e.g. `.github/workflows/tests.yml	completed	success	1	31153179886`).
# A run still in flight has status `in_progress`/`queued` and a null conclusion,
# emitted as an empty third field.
#
# WHY run_attempt IS EXTRACTED (your-org/nexus-code#748). This endpoint returns
# ONE entry per run — the LATEST attempt — and says nothing about the earlier
# ones unless you read `run_attempt`. So a band that concluded `failure` and was
# then re-run green is byte-identical, here and in `gh run list` and in the
# check-runs API, to a band that passed first time. That is not hypothetical: at
# head d4df844f the SLOW band went `failure` (test-jupyter-service.sh) and then
# `success` on re-run at the SAME sha, and every tool in this repo read the
# result as a clean first-pass green. `run_attempt` was in this very payload the
# whole time — the extractor simply dropped it, so no consumer could have known.
# It costs ZERO extra API calls to keep, which is why the field is carried here
# rather than fetched later.
#
# `run_attempt` alone says a retry HAPPENED; it does not say what the earlier
# attempt concluded, and those are different findings — a green that replaced a
# `failure` has two contradicting verdicts at one sha and nothing has
# adjudicated between them, whereas a green that replaced a `cancelled` replaced
# no verdict at all. Resolving that needs one call per retried run and lives in
# monitor/ci-attempt-history.sh, which enriches these rows with a sixth field.
# `run_id` is carried here so that script has something to fetch by.
#
# This file is a FAITHFUL EXTRACTOR, not the verdict filter. It deliberately
# emits skipped/cancelled/timed_out runs too — dropping them here is what used
# to collapse "a run ran and was skipped" (NO-VERDICT) into "no run at all"
# (MISSING-RUN), two states that need different diagnoses. Which conclusions
# count as a VERDICT now lives in ONE place, monitor/ci-trigger-audit.py
# (VERDICT_CONCLUSIONS + classify_runs, your-org/nexus-code#628): only
# `success` and `failure` are verdicts; `skipped`, `cancelled`, `timed_out`,
# `action_required`, `neutral`, `stale` and absence are not, and a `failure` is
# reported distinctly from an absence. Keeping extraction here and the verdict
# semantics there lets monitor/test-ci-trigger-audit.sh exercise the REAL
# classification against synthetic run sets, while still exercising THIS
# extractor against a real runs payload — neither is a copy of the other.
.workflow_runs[]
| [.path, (.status // ""), (.conclusion // ""),
   ((.run_attempt // 1) | tostring), ((.id // "") | tostring)]
| @tsv
