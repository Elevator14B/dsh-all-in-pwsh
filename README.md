# dsh-all-in-pwsh

[![license](https://img.shields.io/github/license/Elevator14B/dsh-all-in-pwsh?style=flat)](LICENSE)

A [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) agent preset that gives the model exactly one tool - a persistent PowerShell 7 shell - and exposes every other mounted tool from inside that shell as a reusable PowerShell **tool object** whose every call returns one **result object**.

Maintainer: [Huanqi Cao](https://github.com/Elevator14B). Tested on Windows 11 with PowerShell 7.6.5 (the version the preset's own persistent shell reports) against the DeepSeek Harness desktop runtime 0.1.6-alpha.1.20260917.2.

## What it does

- **One model-visible tool.** The wire catalog contains only `pwsh`. Every other mounted tool is denied to the model directly and listed in the reference the preset generates from the live catalog.
- **Discover, then call through objects.** `Get-DshTool` lists the catalog (name and one-line summary). `Get-DshTool -Name <name>` fetches a definition once and returns a reusable object; printing it shows its parameters, its return contract and a short validated example, and keeping the variable lets later blocks call it again. Property access is local: it never talks to the bridge.

```powershell
Get-DshTool                                  # catalog: name and summary
$read, $write = Get-DshTool -Name read, write # reusable tool objects
$read                                       # parameters, return contract, example

$source = $read.Invoke(@{ file_path = 'orders.json' })
$orders = $source.Value.Text | ConvertFrom-Json   # complete file text
$source.DisplayText                          # presentation only
```

- **Every call returns ONE result object.** `Ok`, `HasValue`, `Value`, `Content`, `DisplayText`, `Error` and `Metadata`. Printing shows a bounded preview plus a status line; assigning keeps the structured fields. Empty and single-element arrays keep their shape, strings stay strings, and a present key holding `$null` is distinct from an absent key. Object keys preserve their spelling; dot access is case-insensitive unless keys differ only by case, when exact-key indexing preserves both. Integers decode as Int64 where possible, then Decimal or Double; arbitrary precision across the JSON boundary is not promised.
- **A read returns complete data for its requested scope.** The preset registers its own `read` operation in the session's registry layer, so the value the tool itself produces is the whole decoded file when no range is asked for, or exactly the requested `offset`/`limit` range: `.Value.Text` plus the same scope line by line in `.Value.lines` (untruncated, no terminators), with `.Path`, `.Offset`, `.Limit`, `.EndLine` and `.TotalLines` beside them. The printed text is a bounded preview of that same single provider read; it never truncates `.Value`. A whole-file read over the configured `readFullMaxBytes` fails with the provider's `FS_TOO_LARGE`, an explicit line range whose text exceeds it fails with a message, and neither returns a prefix.
- **Native PowerShell arguments.** Arguments are a hashtable, ordered dictionary or PSCustomObject - never JSON text, never an arguments file:

```powershell
$write.Invoke(@{
    file_path = 'C:\work A\note.txt'
    content = @'
中文 "quoted", O'Brien & Sons, $var and a backtick: `tick
C:\folder\file.txt
'@
})
```

A single-quoted here-string opens with `@'` followed by a line break and closes with `'@` at the start of its own line. Quotes and backslashes inside it are literal. `Invoke-DshTool -Name ... -Arguments ...` and the `dsh-tool` alias remain convenience entry points and return the same result object; `-PassThru` is accepted and changes nothing.
- **Failures stop the block, or branch explicitly.** The preset's shell defaults to `$ErrorActionPreference = 'Stop'`, so a failed `.Invoke` terminates the statement and dependent writes do not run on missing data. When a failure is an expected branch, `.TryInvoke(@{ ... })` returns the same result object with `Ok = false` and a structured `Error` (`kind`, `code`, `message`, `tool`, `parameterPath`). A caller that relaxes the error policy explicitly gives up the stop guarantee.
- **Everything still runs through the tool registry.** A bridged call is a nested tool execution carrying the original exec context, so approvals, cancellation, scoping and the session log behave as for any other call, and the Web conversation renders them as PTC-style sub-call rows. The full-text read completes through the registered filesystem provider (`ctx.fs`), so sandbox enforcement, cancellation and provider errors still apply.
- **Definitions cannot go stale silently.** Each tool object carries a definition fingerprint; if the definition changed, the call is refused before executing and names `Refresh()`. A handle is reusable across blocks of the session that created it, and cannot be used in another session or bridge instance.
- **Per-execution identity.** Before each shell command the host writes a fresh call id and capability into that shell's environment and revokes them when the command ends, so a background process started by an earlier command is refused instead of inheriting a later command's identity.

## Install

```powershell
git clone https://github.com/Elevator14B/dsh-all-in-pwsh
cd dsh-all-in-pwsh
pwsh -NoProfile -File ./install.ps1
```

The installer stages and validates the bundle, then installs it to `<DSH home>/.agent-presets/dsh-all-in-pwsh`, substituting the installed bootstrap path into the composition. It never touches your global PowerShell profile.

- Another home or id: `./install.ps1 -DshHome C:\dsh -PresetId my-preset`
- Update: run it again. Files you added or changed inside the preset are kept as `<id>.backup-<timestamp>-<unique>`.
- Remove: `./install.ps1 -Uninstall`, which preserves your changes the same way.
- A directory the installer did not create is left alone unless you pass `-Force`; a foreign directory is never claimed, and a bundle that fails validation leaves the working installation untouched.

Then start a host and pick the preset for a new session:

```powershell
dsh web --port 8080
```

## Tests

Account-free checks - no DSH host, no model, no network. 103 PowerShell checks cover argument fidelity, tool and result objects, catalog refusal handling, JSON decoding, failure branches, handle identity and definition changes, bootstrap defaults, installer ownership and rollback, README snippet parsing, and repository hygiene. Another 12 checks cover the host plugin's per-agent serial queue.

```powershell
pwsh -NoProfile -File ./tests/unit/run.ps1        # objects + module contract + installer + hygiene
node ./tests/unit/serial-locks.mjs                # per-agent serial queue cleanup
pwsh -NoProfile -File ./tests/unit/mutations.ps1  # optional: each installer check must catch its regression
```

The last one is a check on the checks: it applies one small regression at a time to a throwaway copy of `install.ps1` and fails if the suite does not notice. It is slower, so it is not part of the default run.

Integration checks boot the real DSH runtime with the installed preset against a throwaway DSH home. The cold probe covers first use and warm-up concurrency, the objects probe covers the object and read contracts end to end (`.Value.Text` against the file on disk for small, over-2000-line, over-2000-character-line, over-50-KiB, empty, CRLF/Unicode and explicit-range reads; `FS_TOO_LARGE`; `offset` past EOF; a failing `Invoke` leaving no dependent write behind; `TryInvoke` branches; handle reuse across blocks; definition drift and `Refresh()`; the prompt's worked example executed verbatim; and image content staying on its own channel), the lifecycle probe covers outliving, cancelling and aborting a call plus the per-shell lock, and the model probe drives real tool calls end to end:

```powershell
node ./tests/integration/run.cjs               # cold + objects + lifecycle
node ./tests/integration/run.cjs --with-model  # adds the model-backed acceptance probe
```

The runner auto-detects the desktop runtime under the current user's local app data directory. Set `DSH_PROBE_RUNTIME` and `DSH_PROBE_EXE` to point at another build; without a runtime it prints `SKIP` and exits 0.

The model probe is the only one that needs a model route, and it is the only reason `--with-model` copies `settings.yaml` and `.credentials.yaml` into the throwaway home. Those copies are deleted when the probe exits, pass or fail.

## Compatibility

The object API changes the previous return contract: `Invoke-DshTool` always returns a result object, including without `-PassThru`. Its `.Text` alias means display text; use `.Value.Text` for a text read's data. `Get-DshToolSchema` now returns a structured schema object instead of a JSON string. Call `.Invoke(@{})` for tools with no arguments; `.Invoke()` is not an overload. Other tools keep their own declared value shape; a missing output schema does not imply a `.Value.Text` property.

- Windows with PowerShell 7 only. The preset refuses to mount elsewhere rather than half-working.
- The preset reuses the official `dsh-terminal-bash` PTY backend with `shellDialect: pwsh`; no DSH package is patched or replaced.
- The read contract is completed by a `read` operation this preset registers into the session's own registry layer, so it shadows the mounted tool for that session only while keeping its dispatch, guards, permissions, cancellation, `fs/observed` observations and UI card. It uses only registered filesystem provider operations (`ctx.fs.resolve`, `stat`, `readBytes`, `streamText`); the preset never reads a file itself. A session whose read is not mounted, or is restricted away, is left alone, and a registration failure is raised rather than silently serving the windowed read.
- It needs a DSH build whose runtime exposes the extension points it uses: the `system-prompt/assemble` waterfall, `systemPrompt.section`, `tools.guard`, the `tools/execute` waterfall, `ctx.tools.get/schemas/execute` and `ctx.terminals.list/startSend`. The shipped desktop and web profiles do.

## Structure and behaviour boundaries

```
preset/preset.yml                 display metadata
preset/agent.cordis.yml           the agent composition (bootstrap path is a placeholder)
preset/plugin/dsh-all-in-pwsh.mjs host plugin: catalog collapse, guard, bridge, lock, read contract
preset/plugin/DshCli.psm1         the PowerShell tool and result objects
preset/plugin/DshCli.format.ps1xml display views for the object types
preset/plugin/bootstrap.ps1       imported by the persistent shell at startup (sets the Stop policy)
install.ps1                       install / update / uninstall
THIRD-PARTY-NOTICES.md            what is adapted from DeepSeek Harness, and its MIT notice
tests/unit/...                    no account needed
tests/integration/...             needs the real DSH runtime
```

- The model-facing reference is generated from the live catalog at every prompt assembly, so it always matches the tools the session actually has. It lists names and summaries only; parameters and schemas are disclosed by printing a tool object.
- The bridge listens on loopback with a per-instance token stored under the DSH home (Windows filesystem permissions govern access). Any process on the machine that can read that file can reach the bridge; this is a local developer tool, not a multi-tenant design.
- Only a shell command that is still running can call tools. A background process keeps the identity it inherited; once that command ends the identity is revoked and its calls are refused.
- Commands in one shell are serialized; independent sessions and hosts run in parallel.
- Nothing here modifies DSH itself, and the installer never edits your global PowerShell profile.

## Troubleshooting

Failures are structured. `$result.Ok` is false and `$result.Error` names the group, and a raised failure prints one `[dsh] FAILED <tool> (kind=..., code=..., parameter=...): <message>` line before the block stops, so the reason stays visible even though the command wrapper swallows the terminating error: 

1. **Invalid arguments** (`kind = Bridge` before any request, or thrown by the module): a `DateTime` instead of an ISO-8601 string, a non-string dictionary key, a cycle, or nesting past the 48-level JSON budget. The message names the parameter path and the offending type.
2. **Bridge or host refusals** (`kind = Bridge` or `kind = Host`): the bridge is unreachable, the execution identity is missing or revoked (`IDENTITY_REVOKED`), the tool object belongs to another bridge instance or session (`HANDLE_INSTANCE_MISMATCH` / `HANDLE_SESSION_MISMATCH`), or the definition changed (`kind = DefinitionChanged`, which names `Refresh()`). A connection failure after dispatch is reported with `Metadata.outcome = 'unknown'`: the operation may or may not have taken effect, and it is never retried automatically.
3. **Executed-tool failures** (`kind = Tool`): the call ran and the tool failed. A read of a missing path reports the provider's `FS_NOT_FOUND`; a whole-file read over the configured byte limit reports the provider's `FS_TOO_LARGE`; an explicit line range whose text exceeds that limit fails with a message and no code. `TryInvoke` returns these without terminating, while revoked-execution control flow is raised even there.

Other symptoms:

- **`dsh-all-in-pwsh is not active in this shell`** - the command is not running inside a preset shell call, for example a background job started by an earlier command. Run it in the foreground.
- **A dependent write ran after a failed call** - the shell's error policy was relaxed. The preset sets `$ErrorActionPreference = 'Stop'` at startup; a script that sets `Continue` gives up the stop guarantee and should use `TryInvoke`.
- **A block stops with only an exit code** - every raised failure prints its `[dsh] FAILED ...` reason line first, and that line, not the exit code, is the diagnosis. A native command that fails inside the block still reports through its own stderr and `$LASTEXITCODE`.
- **An argument seems to have no effect** - the harness compiles a plugin's parameters into an implicitly open object root, so a name the tool's `InputSchema` does not declare is ignored rather than rejected. The preset prints `[dsh] WARNING <tool> ignores undeclared argument(s): <names> (declared: <names>)` before the call runs and still executes the call. A tool that closes its root with `additionalProperties: false` is rejected by the harness itself, which the failure line above reports.
- **The preset is missing from the picker** - check that `<DSH home>/.agent-presets/dsh-all-in-pwsh/agent.cordis.yml` exists and that the host resolves `<DSH home>` the way you expect (`DSH_HOME`).
- **The preset fails to mount** - the mount error names the row. The usual cause is a DSH build older than the extension points listed above.
- **`Get-Command dsh-tool` reports Application instead of Alias** - a different `dsh-tool` is on `PATH`. Remove it; the module alias should win inside the preset shell.

## License

[MIT](LICENSE), Copyright (c) 2026 Huanqi Cao. The preset composition adapts the agent presets shipped with DeepSeek Harness, which is MIT licensed, Copyright (c) 2026 DeepSeek; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
