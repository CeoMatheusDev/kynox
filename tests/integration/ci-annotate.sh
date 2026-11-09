#!/usr/bin/env bash
#
# Publishes the result of an integration script as a CI annotation.
#
# Why this exists: the console of a step is not reachable from every
# environment — the log endpoint redirects to a storage host that a restricted
# network refuses — while the annotations of a run are served by the API
# itself. The scripts already know, at the moment they give up, which
# assertion failed and what the console said; this file is the one place that
# says it in the form the CI reads.
#
# The calls are no-ops outside GitHub Actions, so a developer running the
# script by hand sees the ordinary output and nothing else.
#
# Usage:
#   source tests/integration/ci-annotate.sh
#   ci_annotate_error "title" "message"     # on a failure
#   ci_annotate_warning "title" "message"

# The marker that GitHub Actions parses in the log of the step. Everything
# after `::` is the message, so the characters that would end the command —
# `%` (the escape itself), CR and LF — are percent-encoded.
ci_annotate() {
    local level="$1" title="$2" message="$3"
    [[ "${GITHUB_ACTIONS:-}" == "true" ]] || return 0
    message="${message//'%'/%25}"
    message="${message//$'\r'/%0D}"
    message="${message//$'\n'/%0A}"
    title="${title//'%'/%25}"
    title="${title//$'\r'/%0D}"
    title="${title//$'\n'/%0A}"
    printf '::%s title=%s::%s\n' "$level" "$title" "$message"
}

ci_annotate_error() {
    ci_annotate error "$1" "$2"
}

ci_annotate_warning() {
    ci_annotate warning "$1" "$2"
}

# True when the run can publish more annotations. GitHub accepts a small
# number per step, and the callers stay inside it.
ci_annotations_enabled() {
    [[ "${GITHUB_ACTIONS:-}" == "true" ]]
}
