# shellcheck shell=bash
# agentguard shell integration.
#
# Source this file from shell startup when a host wants all dependency shell
# loaders to follow the same convention:
#   . "$(shdeps dep-file cgraf78/agentguard share/agentguard/shell.sh)"

# shellcheck disable=SC2034 # public marker for callers that verify the loader ran.
AGENTGUARD_SHELL_LOADED=1

# ---------------------------------------------------------------------------
# Public API - stable shell integration surface
# ---------------------------------------------------------------------------
# agentguard currently exports no interactive shell functions. Agent hook
# launchers use the executable files in bin/, while scripts that need detection
# should source lib/agentguard/agentguard.sh.
