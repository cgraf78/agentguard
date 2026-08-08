# Reconcile one complete AgentGuard hook generation with a consumer-owned
# settings object. Invoke with `--arg agent NAME`, `--slurpfile d LIVE`, and
# `--slurpfile s PROVIDER`.
#
# A plain recursive merge cannot express provider retirement: if AgentGuard
# changes a command or stops supporting an event, the destination-only copy
# survives forever. Consumers should not solve that with their own per-runtime
# deletion lists because those lists immediately become a second, drifting
# implementation of AgentGuard's compatibility policy. Instead, command
# identity carries the ownership boundary. This filter removes the selected
# agent's previous `agent-hook-*` commands, preserves every unowned command and
# setting, and then installs the current provider generation.
#
# The predicate intentionally recognizes both the original `env
# AGENTGUARD_NAME=...` form and the hardened `env -u ...
# AGENTGUARD_NAME=...` form. Future command-envelope migrations should extend
# this predicate so a single AgentGuard release can retire every historical
# generation without requiring downstream migration code.

def agentguard_owned_command($agent):
  type == "string" and
  contains("AGENTGUARD_NAME=" + $agent + " ") and
  contains(" agent-hook-");

def without_agentguard_commands($agent):
  if type == "object" and ((.hooks? | type) == "array") then
    .hooks = [
      .hooks[] |
      select(((.command? // "") | agentguard_owned_command($agent)) | not)
    ] |
    select((.hooks | length) > 0)
  else
    .
  end;

($d[0] // {}) as $destination |
($s[0] // null) as $source |
if ($destination | type) != "object" then
  error("AgentGuard destination must be a JSON object")
elif ($source | type) != "object" then
  error("AgentGuard provider fragment must be a JSON object")
elif (($source | has("hooks")) | not) or (($source.hooks | type) != "object") then
  error("AgentGuard provider fragment must contain a hooks object")
elif (($destination.hooks? // {}) | type) != "object" then
  error("AgentGuard destination hooks must be an object")
else
  ($destination |
    .hooks = ((.hooks // {}) | with_entries(
      # Some runtimes keep mutable metadata such as Codex trust records below
      # the hooks table. Only array-valued event entries participate in native
      # hook reconciliation; preserve all other runtime-owned values verbatim.
      if (.value | type) == "array" then
        .value = [.value[] | without_agentguard_commands($agent)] |
        select((.value | length) > 0)
      else
        .
      end
    ))) as $clean |
  ($clean * ($source | del(.hooks))) as $base |
  (($clean.hooks // {}) as $existing |
    ($source.hooks // {}) as $incoming |
    if ($incoming | all(.[]; type == "array")) | not then
      error("AgentGuard provider hook events must contain arrays")
    else
      reduce (($incoming | keys_unsorted)[]) as $event
        ($existing;
          .[$event] = (
            (if (.[$event] | type) == "array" then .[$event] else [] end) +
            $incoming[$event]
          ))
    end) as $hooks |
  $base |
  if ($hooks | length) > 0 then .hooks = $hooks else del(.hooks) end
end
