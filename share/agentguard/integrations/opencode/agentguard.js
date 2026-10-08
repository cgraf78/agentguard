// agentguard-managed:opencode-plugin

import { AsyncLocalStorage } from "node:async_hooks";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, constants as fsConstants } from "node:fs";
import { access } from "node:fs/promises";
import path from "node:path";

// These agents are OpenCode bookkeeping, not user-delegated workers. Starting
// memory/security lifecycles for them would create noise and orphan sessions;
// real task subagents deliberately remain guarded.
// Private core barrier: V1 events remain fire-and-forget, while V2 model
// context must await error/lifecycle guidance before its next request.
const DRAIN = Symbol("agentguard.drain");
// Private core entry for audit-only lifecycle events. V2 delivers compaction
// and failure notices on its own event stream, while the core owns which
// sessions are started and therefore eligible for a record.
const OBSERVE = Symbol("agentguard.observe");

const INTERNAL_AGENTS = new Set(["title", "summary", "compaction"]);

// OpenCode's generic MCP helpers use different names from the server-prefixed
// tools it synthesizes. Keep that vocabulary in one table so pre/post mapping
// cannot silently drift between resource operations.
const RESOURCE_TOOLS = new Map([
  ["read_mcp_resource", { operations: ["read_resource"], list: false }],
  ["list_mcp_resources", { operations: ["list_resources"], list: true }],
  ["list_mcp_resource_templates", { operations: ["list_resource_templates"], list: true }],
  ["opencode_read_mcp_resource", { operations: ["read_resource"], list: false }],
  // The V2 helper returns both catalogs. Guard both identities so a policy
  // specifically protecting templates cannot be bypassed through this helper.
  [
    "opencode_list_mcp_resources",
    { operations: ["list_resources", "list_resource_templates"], list: true },
  ],
]);
const TIMEOUTS = new Map([
  ["agent-hook-pre-bash", 600_000],
  ["agent-hook-post-bash", 120_000],
  ["agent-hook-post-edit", 60_000],
  ["agent-hook-session-end", 30_000],
]);
const DEFAULT_TIMEOUT = 10_000;
// The passive audit recorder normally finishes in milliseconds. Nothing waits
// for it during a session; this bound only lets unload give a final SessionEnd
// record time to land before stopping recorders that are still running.
const RECORDER = "agent-hook-telemetry";
const RECORDER_DRAIN = 2_000;
const CALL_TTL = 6 * 60 * 60 * 1_000;
const MAX_CALLS = 1_024;
const MCP_STATUS_TTL = 5_000;
const MCP_STATUS_TIMEOUT = 1_000;
const CONTEXT_HEADING = "AgentGuard context";
// Cleanup executes only after this adapter has declared a hook transaction
// unsafe. Never resolve its interpreter or process enumerator through a
// project-controlled PATH: an attacker able to replace either program could
// turn a fail-closed denial back into a surviving descendant. These root-owned
// locations are shared by supported Linux and macOS hosts; if neither exists,
// the narrower kernel process-group kill remains the non-executing fallback.
const TRUSTED_CLEANUP_PYTHON = ["/usr/bin/python3", "/bin/python3"].find(existsSync);
const TRUSTED_CLEANUP_PS = ["/bin/ps", "/usr/bin/ps"].find(existsSync);
const TRUSTED_CLEANUP_PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
// These variables are executable input to a newly started non-interactive
// shell, not ordinary application configuration. Inheriting them would let a
// project or outer agent run code before an AgentGuard hook's first line, which
// is too early for the hook launcher's own environment scrub to intervene.
const UNSAFE_SHELL_STARTUP_ENV = new Set([
  "BASH_ENV",
  "ENV",
  "BASHOPTS",
  "SHELLOPTS",
  "BASH_COMPAT",
  "BASH_XTRACEFD",
  "FUNCNEST",
  "POSIXLY_CORRECT",
]);
// V2 publishes compaction and turn failures only on its event stream. Map the
// ones other runtimes also record to the shared event names; the payload keeps
// each event's native detail.
const V2_AUDIT_EVENTS = new Map([
  ["session.compaction.started", (data) => ["PreCompact", { trigger: data.reason }]],
  [
    "session.compaction.ended",
    (data) => ["PostCompact", { trigger: data.reason, compact_summary: data.text }],
  ],
  ["session.execution.failed", (data) => ["StopFailure", { error: data.error }]],
]);
const PERMISSION_FAILURE_PREFIXES = [
  "The user rejected permission to use this specific tool call.",
  "The user rejected permission to use this specific tool call with the following feedback:",
  "The user has specified a rule which prevents you from using this specific tool call.",
];

// Node can create a private POSIX session but cannot enumerate its members.
// The usual command-line shortcuts are not portable here: Apple's pkill omits
// the `-s` selector, while Apple's `ps sess` field is an opaque kernel pointer
// rather than the numeric session ID. When Python is available, its getsid(2)
// binding lets this small helper keep the cleanup boundary identical on macOS
// and Linux. The narrower process-group cleanup remains the safe fallback.
const POSIX_SESSION_KILLER = `
import os
import signal
import subprocess
import sys

session_id = int(sys.argv[1])
ps_path = sys.argv[2]

# The adapter kills the leader's process group before this broader sweep. Most
# hooks and descendants are therefore already stopped, closing the fork race
# before we enumerate helpers that deliberately moved into another group. Use
# two snapshots because those escaped helpers can still be disappearing while
# Node reaps the original group.
for _ in range(2):
    result = subprocess.run(
        [ps_path, "-A", "-o", "pid="],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(1)

    members = []
    for line in result.stdout.splitlines():
        try:
            pid = int(line)
            if os.getsid(pid) == session_id:
                members.append(pid)
        except (PermissionError, ProcessLookupError, ValueError):
            pass

    # Stop helpers before any surviving leader. The common leader group was
    # already killed atomically; this order keeps a separately grouped helper
    # from outliving another escaped process that it owns.
    members.sort(key=lambda pid: pid == session_id)
    for pid in members:
        try:
            # Revalidate the kernel-owned SID immediately before signaling so
            # PID reuse or a deliberate setsid(2) cannot widen the kill scope.
            if os.getsid(pid) == session_id:
                os.kill(pid, signal.SIGKILL)
        except (PermissionError, ProcessLookupError):
            pass
`;

// Long-running Bash checks need the same practical budget as the Claude and
// Codex integrations. Tests scale these values instead of weakening production
// behavior.
function scaled(milliseconds) {
  const scale = Number.parseFloat(process.env.AGENTGUARD_OPENCODE_TIMEOUT_SCALE ?? "1");
  const safeScale = Number.isFinite(scale) && scale > 0 ? scale : 1;
  return Math.max(1, Math.round(milliseconds * safeScale));
}

function timeoutFor(hook) {
  return scaled(TIMEOUTS.get(hook) ?? DEFAULT_TIMEOUT);
}

function sanitizeMcpName(value) {
  return value.replace(/[^A-Za-z0-9_-]/g, "_");
}

function contextFrom(parsed) {
  // AgentGuard supports both its compact response and the Claude-compatible
  // hook envelope. Accepting both keeps this adapter policy-free.
  const context = parsed?.context ?? parsed?.hookSpecificOutput?.additionalContext;
  return typeof context === "string" && context.trim() ? context.trim() : "";
}

function appendContext(original, contexts) {
  // Append under a stable boundary rather than parsing or rewriting display
  // text. OpenCode and AgentGuard can then evolve their prose independently.
  const usable = contexts.filter((item) => typeof item === "string" && item.trim());
  if (usable.length === 0) return original;
  const prefix = original ? `${original}\n\n` : "";
  return `${prefix}<${CONTEXT_HEADING}>\n${usable.join("\n\n")}\n</${CONTEXT_HEADING}>`;
}

function agentName() {
  const configured = process.env.AGENTGUARD_OPENCODE_NAME?.trim();
  return configured || "opencode";
}

function hookEnvironment(overrides = {}) {
  const environment = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (UNSAFE_SHELL_STARTUP_ENV.has(name)) continue;
    // Bash imports exported functions before a script can inspect its
    // environment. AgentGuard's launchers also defend against this form, but
    // dropping it here closes the earlier interpreter-startup boundary.
    if (name.startsWith("BASH_FUNC_") && name.endsWith("%%")) continue;
    environment[name] = value;
  }
  return { ...environment, ...overrides };
}

function appendOutputContext(output, contexts) {
  const context = appendContext("", contexts);
  if (!context) return;
  if (Array.isArray(output.content)) {
    output.content = [...output.content, { type: "text", text: context }];
    return;
  }
  if (typeof output.content === "string") {
    output.content = appendContext(output.content, contexts);
    return;
  }
  if (typeof output.output === "string") {
    output.output = appendContext(output.output, contexts);
    return;
  }
  output.output = context;
}

// AgentGuard owns one stable cross-runtime schema. Translate OpenCode's native
// camel-case arguments here instead of teaching individual guard hooks about
// another runtime.
function canonicalToolInput(tool, args) {
  if (tool === "bash" || tool === "shell") {
    return {
      command: args.command,
      ...(args.timeout === undefined ? {} : { timeout: args.timeout }),
      ...((args.workdir ?? args.cwd) === undefined ? {} : { workdir: args.workdir ?? args.cwd }),
    };
  }
  if (tool === "edit") {
    return {
      ...args,
      file_path: args.filePath ?? args.path,
      old_string: args.oldString,
      new_string: args.newString,
      replace_all: args.replaceAll,
    };
  }
  if (tool === "write") {
    return {
      ...args,
      file_path: args.filePath ?? args.path,
      content: args.content,
    };
  }
  if (tool === "multiedit") {
    return {
      ...args,
      file_path: args.filePath ?? args.path,
      edits: (args.edits ?? []).map((edit) => ({
        old_string: edit.oldString,
        new_string: edit.newString,
        replace_all: edit.replaceAll,
      })),
    };
  }
  if (tool === "apply_patch" || tool === "patch") {
    return {
      ...args,
      patch: args.patchText ?? args.patch,
    };
  }
  return args;
}

function directTarget(tool, args) {
  // AgentGuard's edit policy covers all filesystem mutation primitives. Keep
  // OpenCode's visible Write name for audit clarity while routing it through
  // the same pre/post-edit executable.
  if (tool === "bash" || tool === "shell") {
    return { kind: "bash", name: "Bash", input: canonicalToolInput(tool, args) };
  }
  if (tool === "edit") {
    return { kind: "edit", name: "Edit", input: canonicalToolInput(tool, args) };
  }
  if (tool === "write") {
    return { kind: "edit", name: "Write", input: canonicalToolInput(tool, args) };
  }
  if (tool === "multiedit") {
    return { kind: "edit", name: "MultiEdit", input: canonicalToolInput(tool, args) };
  }
  if (tool === "apply_patch" || tool === "patch") {
    return { kind: "edit", name: "Edit", input: canonicalToolInput(tool, args) };
  }
}

function matchingMcpTargets(tool, args, servers, prefixFor) {
  return servers
    .map((server) => ({ server, prefix: prefixFor(server) }))
    .filter(({ prefix }) => tool.startsWith(prefix) && tool.length > prefix.length)
    .map(({ server, prefix }) => ({
      kind: "mcp",
      name: `mcp__${server}__${tool.slice(prefix.length)}`,
      input: args,
    }));
}

function resourceServer(args) {
  return typeof args.server === "string" && args.server ? args.server : undefined;
}

function mcpTargets(tool, args, servers) {
  const resource = RESOURCE_TOOLS.get(tool);
  if (resource) {
    const scoped = resourceServer(args);
    const targets = scoped ? [scoped] : resource.list ? servers : [];
    return targets.flatMap((server) =>
      resource.operations.map((operation) => ({
        kind: "mcp",
        name: `mcp__${server}__${operation}`,
        input: scoped ? args : { ...args, server },
      })),
    );
  }

  // Canonical aliases remain executable in compatible runtimes even when the
  // advertised tool name is flattened. Evaluate both interpretations together:
  // valid server names can make their prefixes overlap, and guessing would let
  // the wrong server's policy authorize a call.
  const matches = [
    ...matchingMcpTargets(tool, args, servers, (server) => `mcp__${server}__`),
    ...matchingMcpTargets(tool, args, servers, (server) => `${sanitizeMcpName(server)}_`),
  ];
  if (matches.length > 1) {
    throw new Error(`Ambiguous MCP tool identity for ${tool}`);
  }
  return matches;
}

function targetsFor(tool, args, servers) {
  const direct = directTarget(tool, args);
  return direct ? [direct] : mcpTargets(tool, args, servers);
}

function couldBeDynamicMcpTool(tool) {
  // OpenCode flattens runtime-added MCP identities as <server>_<tool>, while
  // compatible runtimes can retain the canonical mcp__<server>__<tool> form.
  // Resource helpers are also MCP operations even when no server is explicit.
  // During a live-inventory outage these shapes are the boundary between
  // unrelated single-token built-ins and calls that must not silently bypass
  // AgentGuard merely because their server was added after configuration.
  return RESOURCE_TOOLS.has(tool) || tool.startsWith("mcp__") || tool.includes("_");
}

function auditTarget(tool, args, targets, directory) {
  // The audit trail holds one event per OpenCode call, not one per guard. A
  // single guarded identity keeps the canonical name its guard records carry;
  // unguarded tools and multi-server fan-out keep OpenCode's native name.
  if (targets?.length === 1) return targets[0];
  let direct;
  try {
    direct = directTarget(tool, args ?? {});
  } catch {
    // Arguments too malformed to normalize are kept verbatim: the request
    // still belongs in the trail even though its guard will refuse it.
  }
  return direct
    ? { ...direct, cwd: targetCwd(direct, directory) }
    : { kind: targets?.[0]?.kind, name: tool, input: args, cwd: directory };
}

function targetCwd(target, directory) {
  // This mirrors OpenCode's current Bash contract: absolute workdirs win and
  // ordinary relative values resolve from the plugin's project directory.
  // Home shorthand and shell quoting are not part of that path API.
  if (target.kind === "bash" && typeof target.input.workdir === "string" && target.input.workdir) {
    return path.resolve(directory, target.input.workdir);
  }
  return directory;
}

function hookFor(kind, phase) {
  return `agent-hook-${phase}-${kind}`;
}

function basePayload(sessionID, directory, eventName) {
  return {
    session_id: sessionID,
    cwd: directory,
    hook_event_name: eventName,
  };
}

// The call ID is AgentGuard's tool_use_id: the documented key that joins a
// guard's decision record to the recorder's pre and post events for one call.
function toolPayload(sessionID, directory, eventName, target, callID, output) {
  const response = output === undefined ? undefined : toolResponse(target, output);
  return {
    ...basePayload(sessionID, directory, eventName),
    tool_name: target.name,
    tool_input: target.input,
    ...(callID === undefined ? {} : { tool_use_id: callID }),
    ...(response === undefined ? {} : { tool_response: response }),
    ...(target.kind === "mcp" && typeof output?.isError === "boolean"
      ? { tool_result_is_error: output.isError }
      : {}),
  };
}

function toolResponse(target, output) {
  // Never infer execution status from OpenCode's human-readable output. The
  // structured metadata is the only stable machine contract.
  if (target.kind === "bash") {
    const metadata = output.metadata ?? {};
    let exitCode;
    if (Object.hasOwn(metadata, "exit")) {
      // OpenCode reports a null exit for signal termination. AgentGuard treats
      // an absent status as success, so preserve the failure explicitly.
      exitCode = metadata.exit === null ? 1 : metadata.exit;
    } else if (Object.hasOwn(metadata, "exit_code")) {
      exitCode = metadata.exit_code;
    } else if (metadata.signal || metadata.timeout === true) {
      exitCode = 1;
    } else if (
      Object.hasOwn(metadata, "status") &&
      !["completed", "running"].includes(metadata.status)
    ) {
      exitCode = metadata.status;
    }
    return {
      stdout:
        typeof output.output === "object" && output.output !== null
          ? output.output.output
          : output.output,
      ...(metadata.stderr === undefined ? {} : { stderr: metadata.stderr }),
      ...(exitCode === undefined ? {} : { exit_code: exitCode }),
      metadata: output.metadata,
    };
  }
  return {
    output: output.output,
    ...(output.content === undefined ? {} : { content: output.content }),
    metadata: output.metadata,
  };
}

async function executable(hook) {
  // Prefer the conventional per-user installation even when a caller's PATH is
  // stale, while retaining PATH fallback for portable and test installations.
  const home = process.env.HOME ?? process.env.USERPROFILE;
  if (home) {
    const local = path.join(home, ".local", "bin", hook);
    try {
      await access(local, fsConstants.X_OK);
      return local;
    } catch {
      // Fall through to PATH for other installations.
    }
  }

  for (const directory of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!directory) continue;
    const candidate = path.join(directory, hook);
    try {
      await access(candidate, fsConstants.X_OK);
      return candidate;
    } catch {
      // Continue through PATH.
    }
  }
}

function spawnHook(command, hook, payload, directory, sessionID, runtimeName) {
  return new Promise((resolve, reject) => {
    // A timed-out hook may have spawned helpers. A separate POSIX process group
    // lets us enforce the timeout across the whole tree instead of leaving
    // detached descendants to mutate state after OpenCode has denied the call.
    const grouped = process.platform !== "win32";
    const child = spawn(command, [], {
      cwd: directory,
      detached: grouped,
      env: hookEnvironment({
        AGENTGUARD_NAME: runtimeName,
        AGENTGUARD_SESSION_ID: sessionID,
      }),
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    let terminated = false;

    function terminate() {
      if (terminated) return;
      terminated = true;
      if (grouped && child.pid) {
        let groupKilled = false;
        try {
          // `detached` makes the child a private session and process-group
          // leader. Kill that group first: the kernel selects all ordinary
          // descendants in one operation, so none can fork between a userspace
          // process snapshot and the signal that is meant to stop it.
          process.kill(-child.pid, "SIGKILL");
          groupKilled = true;
        } catch {
          // It may have exited between timeout detection and cleanup. Still
          // sweep the session because a separately grouped helper can remain.
        }

        // Shells may place background helpers in additional process groups
        // inside the private session. A negative PID cannot reach those groups;
        // enumerate the full session or a denied hook could leave one alive to
        // mutate files after OpenCode has returned.
        //
        // This synchronous call runs only while handling a timeout or protocol
        // failure. Waiting for it here preserves the stronger invariant that
        // no owned session member is left running when the hook promise rejects.
        let sessionKill;
        if (TRUSTED_CLEANUP_PYTHON && TRUSTED_CLEANUP_PS) {
          sessionKill = spawnSync(
            TRUSTED_CLEANUP_PYTHON,
            ["-I", "-c", POSIX_SESSION_KILLER, String(child.pid), TRUSTED_CLEANUP_PS],
            {
              // `-I` removes the current directory and PYTHON* environment from
              // module discovery. A neutral cwd and fixed system PATH are
              // defense in depth: cleanup must never import a checkout module
              // or execute a project/toolchain replacement for Python or ps.
              cwd: path.parse(process.execPath).root,
              env: hookEnvironment({ PATH: TRUSTED_CLEANUP_PATH }),
              stdio: "ignore",
              timeout: 2_000,
            },
          );
        }
        if (sessionKill?.status === 0 || groupKilled) return;

        // A damaged or unusually minimal environment may omit Python or ps.
        // Retry the original process group as a safe, narrower fallback because
        // this adapter created it and retained its leader PID for this boundary.
        try {
          process.kill(-child.pid, "SIGKILL");
          return;
        } catch {
          // The group may have exited between detection and cleanup.
        }
      }
      child.kill("SIGKILL");
    }

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      terminate();
      reject(new Error(`${hook} timed out after ${timeoutFor(hook)}ms`));
    }, timeoutFor(hook));

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.stdin.on("error", (error) => {
      // A hook that exits before consuming a large payload can raise EPIPE on
      // the parent stream. Without a listener Node terminates OpenCode; treating
      // it as a protocol failure keeps protected pre-hooks fail closed.
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      terminate();
      reject(new Error(`${hook} input failed: ${error.message}`));
    });
    child.on("error", (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new Error(`${hook} launch failed: ${error.message}`));
    });
    child.on("close", (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      // Keep the private-session cleanup capability with the completed result.
      // JSON/protocol validation happens one layer above because it needs hook
      // semantics, but that validation must still be able to stop descendants
      // before rejecting a protected call whose leader already exited.
      resolve({ code: code ?? 1, signal, stdout, stderr, terminate });
    });
    child.stdin.end(`${JSON.stringify(payload)}\n`);
  });
}

// The recorder only observes, so none of its outcomes may reach OpenCode: it
// bypasses invoke()'s fail-closed protocol, its output is discarded, and every
// failure is silent. It still gets the guard hooks' sanitized environment and
// private process group so a wedged recorder can be stopped with its helpers.
function spawnRecorder(command, body, directory, sessionID, runtimeName) {
  const grouped = process.platform !== "win32";
  let child;
  try {
    child = spawn(command, [], {
      cwd: directory,
      detached: grouped,
      env: hookEnvironment({
        AGENTGUARD_NAME: runtimeName,
        AGENTGUARD_SESSION_ID: sessionID,
      }),
      stdio: ["pipe", "ignore", "ignore"],
    });
  } catch {
    return { done: Promise.resolve(), terminate() {} };
  }
  let exited = false;
  let timer;

  function terminate() {
    // Only a leader that is still running is stopped. Once it exits, its
    // detached retention sweep must be allowed to finish on its own.
    if (exited) return;
    try {
      if (grouped && child.pid) {
        process.kill(-child.pid, "SIGKILL");
      } else {
        child.kill("SIGKILL");
      }
    } catch {
      // It exited between the check and the signal.
    }
  }

  const done = new Promise((resolve) => {
    child.once("error", resolve);
    child.once("exit", resolve);
  }).then(() => {
    exited = true;
    clearTimeout(timer);
  });
  // A wedged recorder gets the ordinary hook budget, then stops, so repeated
  // stalls cannot accumulate processes over a long session.
  timer = setTimeout(terminate, timeoutFor(RECORDER));
  // Fire-and-forget must also hold at host shutdown: neither the child, its
  // watchdog, nor a large payload still queued for a slow reader may keep
  // OpenCode's event loop alive.
  timer.unref?.();
  child.unref();
  child.stdin.unref?.();
  // A recorder that exits without draining a large payload raises EPIPE here;
  // unhandled, that error would terminate OpenCode itself.
  child.stdin.on("error", () => {});
  child.stdin.end(body);
  return { done, terminate };
}

export const AgentGuardPlugin = async ({ directory, client, onContext }) => {
  // Session records serialize lifecycle events that OpenCode intentionally
  // dispatches without awaiting. Call records are separate because concurrent
  // tools need their own pre-hook context and cleanup boundary.
  const sessions = new Map();
  const calls = new Map();
  // In-flight recorder children, drained with a bound at unload.
  const recorders = new Set();
  const runtimeName = agentName();
  let configState;
  let runtimeMcpServers;
  let runtimeMcpInventoryComplete = true;
  let runtimeMcpCheckedAt = 0;
  let runtimeMcpRefresh;
  let reportedMcpStatusFailure = false;

  function state(sessionID) {
    let record = sessions.get(sessionID);
    if (!record || record.ended) {
      record = {
        id: sessionID,
        chain: Promise.resolve(),
        start: undefined,
        pending: [],
        generation: 0,
        stoppedGeneration: -1,
        ended: false,
        end: undefined,
        missing: new Set(),
        audited: undefined,
        failedGeneration: -1,
        touched: Date.now(),
      };
      sessions.set(sessionID, record);
    }
    record.touched = Date.now();
    return record;
  }

  function log(error) {
    console.error(
      `[opencode-agentguard] ${error instanceof Error ? error.message : String(error)}`,
    );
  }

  function configuredMcpServers() {
    return Object.entries(configState?.mcp ?? {})
      .filter(([, info]) => info?.enabled !== false)
      .map(([name]) => name);
  }

  async function activeMcpServers() {
    const fallback = runtimeMcpServers ?? configuredMcpServers();
    // Older runtimes without a status API expose only configured servers, so
    // that configuration is their complete supported inventory. A present but
    // failing status API is different: it may be hiding runtime-added tools.
    if (typeof client?.mcp?.status !== "function") {
      return { servers: fallback, complete: true };
    }

    if (runtimeMcpServers !== undefined && Date.now() - runtimeMcpCheckedAt < MCP_STATUS_TTL) {
      return { servers: runtimeMcpServers, complete: runtimeMcpInventoryComplete };
    }
    if (runtimeMcpRefresh) return runtimeMcpRefresh;

    runtimeMcpRefresh = (async () => {
      let timeout;
      try {
        // Config hooks share a mutable object, but OpenCode can also add MCP
        // servers at runtime without touching it. The local status endpoint is
        // the authoritative inventory for actual tool exposure and also
        // excludes disabled/failed servers that could create false prefix
        // ambiguity. Bound that local RPC because every unknown tool passes
        // through this lookup and a wedged OpenCode client must not hang tools.
        const deadline = new Promise((_, reject) => {
          timeout = setTimeout(
            () => reject(new Error(`MCP status timed out after ${MCP_STATUS_TIMEOUT}ms`)),
            MCP_STATUS_TIMEOUT,
          );
        });
        const response = await Promise.race([
          Promise.resolve().then(() => client.mcp.status()),
          deadline,
        ]);
        if (!response?.data || typeof response.data !== "object") {
          throw new Error("MCP status returned no data");
        }
        runtimeMcpServers = Object.entries(response.data)
          .filter(([, status]) => status?.status === "connected")
          .map(([name]) => name);
        runtimeMcpInventoryComplete = true;
        reportedMcpStatusFailure = false;
      } catch (error) {
        // A transient local API failure must not erase the last known or
        // configured inventory. Cache the fallback briefly as well; otherwise
        // a hanging endpoint would impose the full timeout on every read tool.
        runtimeMcpServers = fallback;
        runtimeMcpInventoryComplete = false;
        if (!reportedMcpStatusFailure) {
          reportedMcpStatusFailure = true;
          const reason = error instanceof Error ? error.message : String(error);
          log(`MCP status unavailable; using last known inventory: ${reason}`);
        }
      } finally {
        clearTimeout(timeout);
        runtimeMcpCheckedAt = Date.now();
      }
      return { servers: runtimeMcpServers, complete: runtimeMcpInventoryComplete };
    })().finally(() => {
      runtimeMcpRefresh = undefined;
    });
    return runtimeMcpRefresh;
  }

  // Protected pre-hooks distinguish an unavailable AgentGuard installation
  // from a broken installed hook: bootstrap absence is advisory, but a hook
  // that launches and violates the protocol must fail closed.
  async function invoke(sessionID, hook, payload, protectedPre = false, cwd = directory) {
    const command = await executable(hook);
    if (!command) {
      // Finalization marks a record ended before SessionEnd runs. Reuse that
      // record for its last missing-hook notice instead of creating a new
      // active session while the old one is being removed.
      const record = sessions.get(sessionID) ?? state(sessionID);
      if (!record.missing.has(hook)) {
        record.missing.add(hook);
        log(`${hook} unavailable; skipping`);
      }
      return { missing: true, context: "" };
    }

    const result = await spawnHook(command, hook, payload, cwd, sessionID, runtimeName);
    try {
      let parsed;
      if (result.stdout.trim()) {
        try {
          parsed = JSON.parse(result.stdout);
        } catch (error) {
          if (protectedPre || result.code === 0) {
            throw new Error(`Invalid AgentGuard output from ${hook}: ${error.message}`);
          }
        }
      }
      const context = contextFrom(parsed);

      if (result.code === 0) {
        if (result.stderr.trim()) log(result.stderr.trim());
        return { missing: false, context };
      }
      if (protectedPre && result.code === 2) {
        throw new Error(
          result.stderr.trim() || context || result.stdout.trim() || `${hook} denied the tool`,
        );
      }
      throw new Error(
        result.stderr.trim() ||
          `${hook} failed with ${result.signal ? `signal ${result.signal}` : `exit ${result.code}`}`,
      );
    } catch (error) {
      // A hook leader can exit after starting a redirected background helper.
      // Any outcome that invoke() rejects is a failed protocol transaction, so
      // stop the entire private session before the caller observes the denial.
      // Successful hooks are intentionally left alone: lifecycle extensions may
      // own asynchronous work beyond the immediate callback.
      result.terminate();
      throw error;
    }
  }

  function advisory(sessionID, hook, payload, cwd = directory) {
    // Completed work cannot be rolled back. Post/lifecycle hooks therefore log
    // protocol failures while protected pre-hooks above retain deny semantics.
    return invoke(sessionID, hook, payload, false, cwd).catch((error) => {
      log(error);
      return { missing: false, context: "" };
    });
  }

  // `build` returns the payload and `after` is an earlier record's promise.
  // Returns this record's own completion so later records can order behind it.
  function audit(sessionID, build, after) {
    // Build and serialize now, inside this guard. Building reads arbitrary
    // tool arguments, and a malformed one must not throw into a callback whose
    // guard decision is still pending. Callers also keep mutating OpenCode's
    // objects after this returns (context appends, V2 result rewrites), and
    // the trail must hold what the tool produced, not what the model later saw.
    let body;
    try {
      body = `${JSON.stringify(build())}\n`;
    } catch {
      return after;
    }
    // Nothing awaits this work, so a slow or hung recorder cannot delay a
    // callback. Resolution matches the guard hooks, and absence is silent:
    // unlike a guard, a missing recorder changes nothing the user relies on.
    // Until the child exists, stopping the entry cancels the spawn, so unload
    // cannot leave behind a recorder that resolved its path just afterwards.
    const entry = {
      terminate() {
        entry.cancelled = true;
      },
    };
    // Records are stamped when their recorder finishes, so a record spawned
    // behind `after` cannot land before it: a fast tool's PostToolUse would
    // otherwise often precede its own PreToolUse in the timeline.
    entry.done = Promise.resolve(after)
      .then(() => executable(RECORDER))
      .then((command) => {
        if (!command || entry.cancelled) return;
        // The record takes its cwd from the payload, so the recorder always
        // starts in the plugin directory: a Bash call naming a missing workdir
        // must still leave its audit record, even though its guard cannot run.
        const child = spawnRecorder(command, body, directory, sessionID, runtimeName);
        entry.terminate = child.terminate;
        return child.done;
      })
      .catch(() => {})
      .finally(() => recorders.delete(entry));
    recorders.add(entry);
    return entry.done;
  }

  function auditLifecycle(session, payload) {
    // A session's lifecycle records keep their dispatch order, as they would
    // with any runtime that runs one lifecycle hook to completion at a time.
    session.audited = audit(session.id, () => payload, session.audited);
  }

  async function drainRecorders() {
    // Unload is the one point that waits, briefly, so a SessionEnd record
    // written just before it can land. Stragglers are owned children and are
    // stopped rather than left to outlive the plugin.
    if (recorders.size === 0) return;
    let timer;
    const deadline = new Promise((resolve) => {
      timer = setTimeout(resolve, scaled(RECORDER_DRAIN));
    });
    await Promise.race([Promise.allSettled([...recorders].map((entry) => entry.done)), deadline]);
    clearTimeout(timer);
    for (const entry of recorders) entry.terminate();
  }

  function observe(sessionID, eventName, fields = {}) {
    // Audit-only lifecycle events follow the same ownership as the guard
    // lifecycle: internal maintenance sessions never start, so they record
    // nothing, and a finalized session cannot gain events after SessionEnd.
    const session = sessions.get(sessionID);
    if (!session?.start || session.ended) return;
    auditLifecycle(session, { ...basePayload(sessionID, directory, eventName), ...fields });
    // StopFailure replaces Stop for the turn it ended, as in other runtimes.
    if (eventName === "StopFailure") session.failedGeneration = session.generation;
  }

  function queue(record, work) {
    // Store the continuation synchronously before returning. That synchronous
    // write is the barrier that makes later awaited callbacks observe work from
    // OpenCode's fire-and-forget event dispatcher.
    const next = record.chain.catch(log).then(work);
    record.chain = next.catch(log);
    return next;
  }

  function ensureStarted(record) {
    // Startup is lazy because session.created has no agent identity; waiting
    // for the first real message is what lets internal maintenance agents stay
    // outside AgentGuard without racing duplicate starts.
    if (!record.start) {
      // The recorder's SessionStart record also triggers its retention prune,
      // so it shares the guard lifecycle's lazy, deduplicated start point.
      const payload = basePayload(record.id, directory, "SessionStart");
      auditLifecycle(record, payload);
      record.start = invoke(record.id, "agent-hook-session-start", payload)
        .then((result) => {
          if (result.context) {
            record.pending.push(result.context);
            onContext?.(record.id, [result.context]);
          }
          return result;
        })
        .catch((error) => {
          log(error);
          return { missing: false, context: "" };
        });
    }
    return record.start;
  }

  function removeCalls(sessionID) {
    for (const [callID, call] of calls) {
      if (call.sessionID === sessionID) calls.delete(callID);
    }
  }

  function claimCall(callID, sessionID) {
    const call = calls.get(callID);
    if (!call || call.sessionID !== sessionID) return;
    calls.delete(callID);
    return call;
  }

  async function runPostHooks(sessionID, call, output) {
    const contexts = [...call.contexts];
    for (const target of call.targets) {
      const result = await advisory(
        sessionID,
        hookFor(target.kind, "post"),
        toolPayload(sessionID, target.cwd, "PostToolUse", target, call.callID, output),
        target.cwd,
      );
      if (result.context) contexts.push(result.context);
    }
    return contexts;
  }

  function terminalToolError(event) {
    if (event.type !== "message.part.updated") return;
    const part = event.properties?.part;
    if (
      part?.type !== "tool" ||
      part.state?.status !== "error" ||
      typeof part.callID !== "string"
    ) {
      return;
    }
    return part;
  }

  function isNonExecutionFailure(state) {
    if (state.metadata?.interrupted === true) return true;
    if (state.error === "Tool execution aborted") return true;
    return (
      typeof state.error === "string" &&
      PERMISSION_FAILURE_PREFIXES.some((prefix) => state.error.startsWith(prefix))
    );
  }

  function handleTerminalToolError(event, sessionID) {
    const part = terminalToolError(event);
    if (!part || (part.sessionID && part.sessionID !== sessionID)) return false;

    // Claim before queueing so duplicate events and a late after-hook cannot
    // report the same call twice. Terminal errors for other tool families and
    // non-execution outcomes still retire their otherwise orphaned records.
    const call = claimCall(part.callID, sessionID);
    if (!call) return true;
    // Audit every failed call, including denials and cancellations that the
    // post-hook deliberately skips: the trail records what happened, while
    // the post-hook only reports work that actually executed.
    audit(
      sessionID,
      () => ({
        ...basePayload(sessionID, call.audit.cwd, "PostToolUseFailure"),
        tool_name: call.audit.name,
        tool_input: call.audit.input,
        tool_use_id: call.callID,
        error: part.state.error,
      }),
      call.preAudit,
    );
    if (isNonExecutionFailure(part.state)) return true;
    if (call.targets.length === 0 || call.targets.some((target) => target.kind !== "mcp")) {
      return true;
    }

    const record = sessions.get(sessionID) ?? state(sessionID);
    if (record.ended) return true;
    const output = {
      output: part.state.error,
      metadata: part.state.metadata,
      isError: true,
    };
    queue(record, async () => {
      const contexts = await runPostHooks(sessionID, call, output);
      record.pending.push(...contexts);
      onContext?.(sessionID, contexts);
    });
    return true;
  }

  function finalize(record) {
    // Mark ended before queueing so delete and dispose converge on the same
    // promise. Records remain present through SessionEnd for missing-hook
    // notice ownership, then disappear only after all queued work completes.
    if (record.end) return record.end;
    record.ended = true;
    record.end = queue(record, async () => {
      await record.start;
      if (record.start) {
        const payload = basePayload(record.id, directory, "SessionEnd");
        auditLifecycle(record, payload);
        await advisory(record.id, "agent-hook-session-end", payload);
      }
      removeCalls(record.id);
      if (sessions.get(record.id) === record) sessions.delete(record.id);
    });
    return record.end;
  }

  function prune() {
    // Never expire active sessions: manufacturing SessionEnd from elapsed time
    // can race a later prompt into a second SessionStart. Only orphaned tool
    // calls are bounded because OpenCode may never deliver their after-hook.
    const cutoff = Date.now() - CALL_TTL;
    for (const [callID, call] of calls) {
      if (call.touched < cutoff) calls.delete(callID);
    }
    while (calls.size > MAX_CALLS) calls.delete(calls.keys().next().value);
  }

  function sessionIDFromEvent(event) {
    return event.properties?.sessionID ?? event.properties?.info?.id;
  }

  return {
    [DRAIN]: async (sessionID) => {
      await sessions.get(sessionID)?.chain;
    },
    config: async (config) => {
      // Retain the shared object rather than a startup snapshot. Plugins run
      // config hooks sequentially and a later plugin may mutate MCP entries.
      configState = config;
    },

    "shell.env": async (input, output) => {
      // Hook subprocesses already receive this identity, but OpenCode launches
      // the actual Bash tool separately. Carry the same two generic AgentGuard
      // keys into that shell so integrations can associate direct child-process
      // activity with this OpenCode session. Keep consumer-specific vocabulary
      // out of the adapter; launchers remain responsible for any translation.
      output.env.AGENTGUARD_NAME = runtimeName;
      if (input.sessionID) {
        output.env.AGENTGUARD_SESSION_ID = input.sessionID;
      } else {
        // OpenCode overlays these entries on process.env after this callback,
        // so deleting the key here would let an outer Claude/Codex session leak
        // straight back in. An explicit empty value masks that parent identity;
        // a consumer can then create an OpenCode-local fallback instead of
        // attributing activity to the parent agent.
        output.env.AGENTGUARD_SESSION_ID = "";
      }
    },

    "chat.message": async (input, output) => {
      if (INTERNAL_AGENTS.has(input.agent)) return;
      prune();
      const record = state(input.sessionID);
      await queue(record, async () => {
        await ensureStarted(record);
        record.generation += 1;

        const prompt = output.parts
          .filter((part) => part.type === "text" && typeof part.text === "string")
          .map((part) => part.text)
          .join("\n");
        const payload = {
          ...basePayload(input.sessionID, directory, "UserPromptSubmit"),
          prompt,
        };
        auditLifecycle(record, payload);
        const result = await advisory(input.sessionID, "agent-hook-prompt-submit", payload);
        // Stop can arrive through the unawaited event channel between prompts.
        // Drain its queued context together with startup and this prompt so no
        // lifecycle guidance is lost or attached to the wrong generation.
        const contexts = record.pending.splice(0);
        if (result.context) contexts.push(result.context);
        output.message.system = appendContext(output.message.system ?? "", contexts);
      });
    },

    "permission.ask": async (input) => {
      // OpenCode has a first-class permission callback, so notification hooks
      // do not need brittle matching against generic event display strings.
      const payload = {
        ...basePayload(input.sessionID, directory, "PermissionRequest"),
        permission: input,
      };
      audit(input.sessionID, () => payload);
      await advisory(input.sessionID, "agent-hook-notification", payload);
    },

    "tool.execute.before": async (input, output) => {
      prune();
      let targets;
      let identity;
      let preAudit;
      const contexts = [];
      try {
        // Direct tools never need a status round trip. Every other tool may be
        // a runtime-added MCP tool, so refresh identity before deciding it is
        // unrelated and therefore safe to skip.
        const inventory = directTarget(input.tool, output.args)
          ? { servers: [], complete: true }
          : await activeMcpServers();
        if (
          !inventory.complete &&
          RESOURCE_TOOLS.get(input.tool)?.list &&
          !resourceServer(output.args)
        ) {
          // An unscoped helper contacts every server. Guarding only the cached
          // subset would leave runtime-added servers unprotected during outages.
          throw new Error(
            `MCP inventory unavailable; refusing unscoped resource list ${input.tool}`,
          );
        }
        targets = targetsFor(input.tool, output.args, inventory.servers).map((target) => ({
          ...target,
          cwd: targetCwd(target, directory),
        }));
        // Record before any guard runs and for every tool, guarded or not, so
        // the trail holds the request even when a guard then denies it.
        identity = auditTarget(input.tool, output.args, targets, directory);
        preAudit = audit(input.sessionID, () =>
          toolPayload(input.sessionID, identity.cwd, "PreToolUse", identity, input.callID),
        );
        if (targets.length === 0 && !inventory.complete && couldBeDynamicMcpTool(input.tool)) {
          throw new Error(`MCP inventory unavailable; refusing dynamic tool ${input.tool}`);
        }

        for (const target of targets) {
          const result = await invoke(
            input.sessionID,
            hookFor(target.kind, "pre"),
            toolPayload(input.sessionID, target.cwd, "PreToolUse", target, input.callID),
            true,
            target.cwd,
          );
          if (result.context) contexts.push(result.context);
        }
      } catch (error) {
        if (!identity) {
          // Identity resolution itself refused the call (an ambiguous or
          // unverifiable MCP name). Audit the request under its native name.
          audit(input.sessionID, () => {
            const native = auditTarget(input.tool, output.args, undefined, directory);
            return toolPayload(input.sessionID, native.cwd, "PreToolUse", native, input.callID);
          });
        }
        // OpenCode blocks on the rejected callback. Compatible runtimes can
        // additionally consume the structured decision from the same failure.
        output.decision = "deny";
        output.reason = error instanceof Error ? error.message : String(error);
        throw error;
      }
      // Unguarded calls are tracked too, with no targets, so their post and
      // failure events reuse the identity captured here and retire exactly once.
      calls.set(input.callID, {
        sessionID: input.sessionID,
        callID: input.callID,
        targets,
        contexts,
        audit: identity,
        preAudit,
        touched: Date.now(),
      });
      prune();
    },

    "tool.execute.after": async (input, output) => {
      // Use identities captured before execution. Re-resolving MCP state here
      // could route the post-hook differently if a server disconnects mid-call.
      const call = claimCall(input.callID, input.sessionID);
      // Record every completion, even one whose pre-call state is gone (pruned,
      // already claimed by a terminal event, or never seen), before returning.
      audit(
        input.sessionID,
        () => {
          const identity = call?.audit ?? auditTarget(input.tool, input.args, undefined, directory);
          return toolPayload(
            input.sessionID,
            identity.cwd,
            "PostToolUse",
            identity,
            input.callID,
            output,
          );
        },
        call?.preAudit,
      );
      if (!call) return;
      const contexts = await runPostHooks(input.sessionID, call, output);
      appendOutputContext(output, contexts);
    },

    event: ({ event }) => {
      // OpenCode discards this callback's promise. Queue durable work now and
      // return immediately; direct callbacks and dispose provide the awaits.
      const sessionID = sessionIDFromEvent(event);
      if (!sessionID) return Promise.resolve();

      if (handleTerminalToolError(event, sessionID)) return Promise.resolve();

      if (event.type === "session.created") {
        state(sessionID);
        return Promise.resolve();
      }
      const record = sessions.get(sessionID);
      if (!record) return Promise.resolve();
      record.touched = Date.now();

      if (event.type === "session.idle") {
        queue(record, async () => {
          // OpenCode may emit duplicate idle events. Generation ownership makes
          // Stop exactly once without suppressing it after the next message.
          if (!record.start || record.stoppedGeneration === record.generation) return;
          record.stoppedGeneration = record.generation;
          const payload = basePayload(sessionID, directory, "Stop");
          if (record.failedGeneration !== record.generation) auditLifecycle(record, payload);
          const result = await advisory(sessionID, "agent-hook-stop", payload);
          if (result.context) {
            record.pending.push(result.context);
            onContext?.(record.id, [result.context]);
          }
        });
      } else if (event.type === "session.deleted") {
        void finalize(record);
      } else if (event.type === "session.compacted") {
        observe(sessionID, "PostCompact");
      } else if (event.type === "session.error") {
        // A provider, abort, or output-limit failure ended the turn. The
        // shared vocabulary for that is StopFailure; the native error object
        // says which kind it was.
        observe(sessionID, "StopFailure", { error: event.properties.error });
      }
      return Promise.resolve();
    },

    // V1 1.18 exposes compaction start only as this experimental hook. Observe
    // it without touching the output, which customizes the compaction prompt.
    "experimental.session.compacting": async (input) => {
      observe(input.sessionID, "PreCompact");
    },

    [OBSERVE]: observe,

    dispose: async () => {
      await Promise.all([...sessions.values()].map(finalize));
      await drainRecorders();
    },
  };
};

// V2 moved extension points into domains. Both hosts use the same guard and
// lifecycle core; this boundary only translates the published 2.0.22 shapes.
// Plugin.define is an identity function, so a local JS asset needs no SDK import.
export default {
  id: "agentguard",
  server: AgentGuardPlugin,
  async setup(ctx) {
    const execution = new AsyncLocalStorage();
    const sessions = new Map();
    const registrations = [];
    const controller = new AbortController();
    let disposed = false;
    const client = {
      mcp: {
        status: async () => {
          const response = await ctx.mcp.list();
          if (!Array.isArray(response?.data)) throw new Error("MCP list returned no data");
          return {
            data: Object.fromEntries(response.data.map((server) => [server.name, server.status])),
          };
        },
      },
    };
    async function session(sessionID) {
      if (disposed) throw new Error("AgentGuard plugin is unloaded");
      let record = sessions.get(sessionID);
      if (!record) {
        // Session location can differ from plugin location (worktrees/subpaths).
        // Resolve once per session, not per tool, and share its core across calls.
        record = (async () => {
          const info = await ctx.session.get({ sessionID });
          const directory = path.resolve(info.location.directory, info.subpath ?? ".");
          const record = { context: "" };
          record.hooks = await AgentGuardPlugin({
            directory,
            client,
            onContext: (_id, contexts) => {
              record.context = appendContext(record.context, contexts);
            },
          });
          return record;
        })();
        sessions.set(sessionID, record);
        record.catch(() => {
          if (sessions.get(sessionID) === record) sessions.delete(sessionID);
        });
      }
      const resolved = await record;
      if (disposed) throw new Error("AgentGuard plugin is unloaded");
      return resolved;
    }
    async function cleanup() {
      disposed = true;
      controller.abort();
      // Dispose explicitly before draining children, including partially failed
      // setup. A retained callback may not recreate a finalized session.
      await Promise.allSettled(registrations.map((registration) => registration.dispose()));
      await Promise.allSettled(
        [...sessions.values()].map(async (record) => (await record).hooks.dispose()),
      );
      sessions.clear();
    }
    try {
      registrations.push(
        await ctx.tool.transform((editor) => {
          // The shell domain omits session identity. Async scope must follow the
          // executor, never the last observed pre-hook, because tools overlap.
          for (const tool of editor.list()) {
            editor.update(tool.id, (definition) => {
              const execute = definition.execute;
              definition.execute = function (input, context) {
                return execution.run(context, () => execute.call(this, input, context));
              };
            });
          }
        }),
      );
      registrations.push(
        await ctx.shell.hook("create.before", (event) => {
          if (disposed) throw new Error("AgentGuard plugin is unloaded");
          event.env.AGENTGUARD_NAME = agentName();
          event.env.AGENTGUARD_SESSION_ID = execution.getStore()?.sessionID ?? "";
        }),
      );
      registrations.push(
        await ctx.session.hook("prompt", async (event) => {
          const record = await session(event.sessionID);
          const info = await ctx.session.get({ sessionID: event.sessionID });
          if (disposed) throw new Error("AgentGuard plugin is unloaded");
          const output = { message: {}, parts: [{ type: "text", text: event.prompt.text }] };
          await record.hooks["chat.message"](
            { sessionID: event.sessionID, agent: info.agent },
            output,
          );
          record.context = output.message.system ?? "";
        }),
      );
      registrations.push(
        await ctx.session.hook("context", async (event) => {
          if (INTERNAL_AGENTS.has(event.agent)) return;
          const record = await session(event.sessionID);
          await record.hooks[DRAIN](event.sessionID);
          if (disposed) throw new Error("AgentGuard plugin is unloaded");
          if (record.context) event.system.push({ type: "text", text: record.context });
        }),
      );
      registrations.push(
        await ctx.permission.hook("evaluate", async (event) => {
          if (event.effect !== "ask") return;
          const record = await session(event.sessionID);
          await record.hooks["permission.ask"](event);
        }),
      );
      registrations.push(
        await ctx.tool.hook("execute.before", async (event) => {
          const record = await session(event.sessionID);
          const output = { args: event.input };
          await record.hooks["tool.execute.before"]({ ...event, callID: event.id }, output);
          event.input = output.args;
        }),
      );
      registrations.push(
        await ctx.tool.hook("execute.after", async (event) => {
          const record = await session(event.sessionID);
          const output =
            event.status === "completed"
              ? { ...event.result, isError: event.result.metadata?.isError }
              : { isError: true, output: event.error.message, metadata: event.error.metadata };
          if (
            event.status === "completed" &&
            event.tool === "shell" &&
            event.result.metadata?.status === "running"
          ) {
            // A background shell is admitted but not complete. Do not label a
            // partial result as successful execution or run completion hooks.
            return;
          }
          if (event.status === "error") {
            // Reuse the core's terminal-error suppression (permission rejection
            // and cancellation are not completed MCP invocations). V2 reports
            // failures directly; V1 needed message-part event recovery instead.
            await record.hooks.event({
              event: {
                type: "message.part.updated",
                properties: {
                  sessionID: event.sessionID,
                  part: {
                    type: "tool",
                    callID: event.id,
                    tool: event.tool,
                    sessionID: event.sessionID,
                    state: {
                      status: "error",
                      input: event.input,
                      error: event.error.message,
                      metadata: {
                        ...event.error.metadata,
                        ...(event.error.error?._tag === "Permission.DeniedError"
                          ? { interrupted: true }
                          : {}),
                      },
                    },
                  },
                },
              },
            });
            await record.hooks[DRAIN](event.sessionID);
            return;
          }
          await record.hooks["tool.execute.after"](
            { ...event, callID: event.id, args: event.input },
            output,
          );
          // isError is the legacy bridge's machine field, not part of Tool.Result.
          delete output.isError;
          event.result = output;
        }),
      );
    } catch (error) {
      await cleanup();
      throw error;
    }
    const events = (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          if (disposed) break;
          if (event.location?.directory && event.location.directory !== ctx.location.directory)
            continue;
          const sessionID = event.data?.sessionID;
          const translate = V2_AUDIT_EVENTS.get(event.type);
          if (
            !sessionID ||
            (!translate &&
              !["session.created", "session.idle", "session.deleted"].includes(event.type))
          )
            continue;
          // Do not lazily start lifecycles for unrelated sessions merely because
          // the server event stream observes them. Prompt/tool callbacks own it.
          const pending = sessions.get(sessionID);
          if (!pending) continue;
          const record = await pending;
          if (disposed) break;
          if (translate) {
            record.hooks[OBSERVE](sessionID, ...translate(event.data));
            continue;
          }
          await record.hooks.event({ event: { type: event.type, properties: { sessionID } } });
          if (event.type === "session.deleted") {
            await record.hooks.dispose();
            sessions.delete(sessionID);
          }
        }
      } catch (error) {
        if (!controller.signal.aborted)
          console.error(`[opencode-agentguard] event stream: ${error.message}`);
      }
    })();
    return async () => {
      await cleanup();
      await events;
    };
  },
};
