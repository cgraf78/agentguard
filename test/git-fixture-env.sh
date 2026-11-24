#!/usr/bin/env bash

# A suite can start inside a Git hook. Repository selectors also override
# git -C, and injected config can override a fixture's hooks or init setup.
# Cases that exercise these settings set them explicitly after setup.
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_DIR GIT_GRAFT_FILE
unset GIT_IMPLICIT_WORK_TREE GIT_INDEX_FILE GIT_NAMESPACE GIT_OBJECT_DIRECTORY
unset GIT_NO_REPLACE_OBJECTS GIT_PREFIX GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_WORK_TREE
unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR
# Keep the caller's config files out of Git commands too. Fixtures that need
# a writable global config can still opt in through _mock_home.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# Container fixtures can have a different uid from the owned checkout.
_test_checkout_files() {
  local checkout=$1
  shift
  git -C "$checkout" -c "safe.directory=$checkout" ls-files -z -- "$@"
}
