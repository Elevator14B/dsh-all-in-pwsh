# dsh-all-in-pwsh

[![license](https://img.shields.io/github/license/Elevator14B/dsh-all-in-pwsh?style=flat)](LICENSE)

A [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) agent preset that gives the model exactly one tool — a persistent PowerShell 7 shell — and exposes every other mounted tool from inside that shell through a native PowerShell object interface.

Maintainer: [Huanqi Cao](https://github.com/Elevator14B). Tested on Windows 11 with PowerShell 7.6.6 against the DeepSeek Harness desktop runtime 0.1.6-alpha.1.20260917.2.

## What it does

- **One model-visible tool.** The wire catalog contains only `pwsh`. Every other mounted tool is denied to the model directly and listed in the reference the preset generates from the live catalog.
- **Native PowerShell arguments.** Tools are called as PowerShell commands with PowerShell objects, so arguments are never JSON the caller has to serialize:

```powershell
Invoke-DshTool -Name read -Arguments @{ file_path = 'C:\work A\note.txt' }

dsh-tool write @{
    file_path = 'C:\work A\note.txt'
    content = @'
中文 "quoted", O'Brien & Sons, $var and a backtick: `tick
C:\folder\file.txt
'@
}

Get-DshTool                        # every callable tool
Get-DshToolSchema -Name read       # one tool's exact parameter schema
$reply = Invoke-DshTool read @{ file_path = 'note.txt' } -PassThru
```

A here-string terminator (`'@`) must sit at the start of its own line; everything between `@'` and that line is the value, quotes and backslashes included.

- **Everything still runs through the tool registry.** A bridged call is a nested tool execution carrying the original exec context, so approvals, cancellation, scoping and the session log behave as for any other call, and the Web conversation renders them as PTC-style sub-call rows.
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

Account-free checks — no DSH host, no model, no network. 51 PowerShell checks: module argument fidelity, the argument types the module must reject, the installer contract (default home resolution, absolute paths, ownership, update/uninstall safety, staging, broken-bundle rollback, and a failed swap restoring a clean, a user-modified or a `-Force`-replaced directory unchanged), README snippet parsing, and repository hygiene. Plus 12 checks over the host plugin's per-agent serial queue.

```powershell
pwsh -NoProfile -File ./tests/unit/run.ps1        # module contract + installer + hygiene
node ./tests/unit/serial-locks.mjs                # per-agent serial queue cleanup
pwsh -NoProfile -File ./tests/unit/mutations.ps1  # optional: each installer check must catch its regression
```

The last one is a check on the checks: it applies one small regression at a time to a throwaway copy of `install.ps1` and fails if the suite does not notice. It is slower, so it is not part of the default run.

Integration checks — 26 in total, booting the real DSH runtime with the installed preset against a throwaway DSH home. The cold probe (7 checks) covers first use and warm-up concurrency, the lifecycle probe (9 checks) covers outliving, cancelling and aborting a call plus the per-shell lock, and the model probe (10 checks) drives real tool calls end to end:

```powershell
node ./tests/integration/run.cjs               # cold/warm concurrency + execution lifecycle
node ./tests/integration/run.cjs --with-model  # adds the model-backed acceptance probe
```

The runner auto-detects the desktop runtime under the current user's local app data directory. Set `DSH_PROBE_RUNTIME` and `DSH_PROBE_EXE` to point at another build; without a runtime it prints `SKIP` and exits 0.

The model probe is the only one that needs a model route, and it is the only reason `--with-model` copies `settings.yaml` and `.credentials.yaml` into the throwaway home. Those copies are deleted when the probe exits, pass or fail.

## Compatibility

- Windows with PowerShell 7 only. The preset refuses to mount elsewhere rather than half-working.
- The preset reuses the official `dsh-terminal-bash` PTY backend with `shellDialect: pwsh`; no DSH package is patched or replaced.
- It needs a DSH build whose runtime exposes the extension points it uses: the `system-prompt/assemble` waterfall, `systemPrompt.section`, `tools.guard`, the `tools/execute` waterfall, and `ctx.terminals.list`/`startSend`. The shipped desktop and web profiles do.

## Structure and behaviour boundaries

```
preset/preset.yml                 display metadata
preset/agent.cordis.yml           the agent composition (bootstrap path is a placeholder)
preset/plugin/dsh-all-in-pwsh.mjs host plugin: catalog collapse, guard, bridge, lock
preset/plugin/DshCli.psm1         the PowerShell object interface
preset/plugin/bootstrap.ps1       imported by the persistent shell at startup
install.ps1                       install / update / uninstall
THIRD-PARTY-NOTICES.md            what is adapted from DeepSeek Harness, and its MIT notice
tests/unit/...                    no account needed
tests/integration/...             needs the real DSH runtime
```

- The model-facing reference is generated from the live catalog at every prompt assembly, so it always matches the tools the session actually has.
- The bridge listens on loopback with a per-instance token stored under the DSH home (Windows filesystem permissions govern access). Any process on the machine that can read that file can reach the bridge; this is a local developer tool, not a multi-tenant design.
- Only a shell command that is still running can call tools. A background process keeps the identity it inherited; once that command ends the identity is revoked and its calls are refused.
- Commands in one shell are serialized; independent sessions and hosts run in parallel.
- Nothing here modifies DSH itself, and the installer never edits your global PowerShell profile.

## Troubleshooting

Failures fall into three groups, and the error text says which:

1. **Invalid arguments** — thrown by the module before any request is sent, naming the parameter path and the offending type. Examples: a `DateTime` instead of an ISO-8601 string, a non-string dictionary key, a cycle, or nesting past the 48-level JSON budget.
2. **Bridge or protocol failures** — `-PassThru` reports `ErrorKind = Protocol`: the bridge is unreachable, the execution identity is missing or revoked, or the request was refused. The request did not complete successfully; a connection failure after dispatch may leave the tool outcome unknown.
3. **Executed-tool failures** — `-PassThru` reports `ErrorKind = Tool`: the call ran and the tool itself failed. `Text` and `Error` carry the tool's own result, unchanged.

Other symptoms:

- **`dsh-all-in-pwsh is not active in this shell`** — the command is not running inside a preset shell call, for example a background job started by an earlier command. Run it in the foreground.
- **The preset is missing from the picker** — check that `<DSH home>/.agent-presets/dsh-all-in-pwsh/agent.cordis.yml` exists and that the host resolves `<DSH home>` the way you expect (`DSH_HOME`).
- **The preset fails to mount** — the mount error names the row. The usual cause is a DSH build older than the extension points listed above.
- **`Get-Command dsh-tool` reports Application instead of Alias** — a different `dsh-tool` is on `PATH`. Remove it; the module alias should win inside the preset shell.

## License

[MIT](LICENSE), Copyright (c) 2026 Huanqi Cao. The preset composition adapts the agent presets shipped with DeepSeek Harness, which is MIT licensed, Copyright (c) 2026 DeepSeek; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
