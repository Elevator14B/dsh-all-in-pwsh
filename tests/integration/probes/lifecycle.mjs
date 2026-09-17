/**
 * Integration probe ported from the development harness. Requires a real DSH
 * runtime; it does not need a model account unless it says so.
 * The preset id under test comes from PROBE_PRESET.
 */
const PRESET = process.env.PROBE_PRESET || 'dsh-all-in-pwsh'
import { writeFileSync, readFileSync, existsSync, readdirSync } from 'node:fs'
import { request } from 'node:http'
import path from 'node:path'
import { randomUUID } from 'node:crypto'

export const name = 'review-followup'
export const inject = ['agents', 'agentPresets', 'sessions', 'tools']

function post(port, headers, payload) {
  return new Promise((resolve, reject) => {
    const body = Buffer.from(JSON.stringify(payload), 'utf8')
    const req = request({ host: '127.0.0.1', port, path: '/rpc', method: 'POST', headers: Object.assign({ 'content-type': 'application/json', 'content-length': body.length }, headers) }, response => {
      const chunks = []
      response.on('data', chunk => chunks.push(chunk))
      response.on('end', () => { try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))) } catch { resolve(undefined) } })
    })
    req.on('error', reject)
    req.end(body)
  })
}

export function apply(ctx) {
  const out = process.env.PROBE_OUT
  const report = { checks: [], results: {} }
  const save = () => writeFileSync(out, JSON.stringify(report, null, 2))
  const record = (name, ok, detail) => { report.checks.push({ name, ok, detail: detail === undefined ? undefined : JSON.parse(JSON.stringify(detail)) }); save() }

  async function run() {
    await ctx.get('loader')?.await()
    const dir = process.cwd()
    ctx.tools.register({
      name: 'probe_slow',
      description: 'Probe-only tool that waits, then reports how long it waited.',
      parameters: { ms: { type: 'number', required: true, description: 'milliseconds to wait' } },
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: String(value) }] },
      async execute(args) {
        await new Promise(resolve => setTimeout(resolve, Number(args.ms)))
        return 'SLOW_DONE_' + String(args.ms)
      },
    })
    const { agent } = await ctx.agents.create({ sessionId: 'session-' + randomUUID(), meta: { cwd: dir, agentPreset: PRESET }, setup: async c => { await ctx.agentPresets.mount(c, PRESET) } })
    await agent.whenIdle()

    const instancesRoot = path.join(process.env.DSH_HOME, 'dsh-all-in-pwsh', 'instances')
    for (let wait = 0; wait < 100; wait += 1) {
      const bound = existsSync(instancesRoot) && readdirSync(instancesRoot).some(id => {
        try { return typeof JSON.parse(readFileSync(path.join(instancesRoot, id, 'bridge.json'), 'utf8')).port === 'number' } catch { return false }
      })
      if (bound) break
      await new Promise(resolve => setTimeout(resolve, 100))
    }
    const instanceId = readdirSync(instancesRoot)[0]
    const bridge = JSON.parse(readFileSync(path.join(instancesRoot, instanceId, 'bridge.json'), 'utf8'))
    const modulePath = path.join(process.env.DSH_HOME, '.agent-presets', PRESET, 'plugin', 'DshCli.psm1')

    let i = 0
    const exec = (id, command, signal) => agent.ctx.tools.execute({ callId: id, rootCallId: id, name: 'pwsh', arguments: { command }, agent, signal: signal ?? new AbortController().signal })
    const textOf = r => (r.content || []).filter(b => b.type === 'text').map(b => b.text).join('')
    const events = () => { const list = []; for (let k = 0; k < agent.session.seq; k += 1) { const e = agent.session.eventAt(k); if (e) list.push(e) } return list }
    const esc = value => value.replaceAll("'", "''")

    await exec('warm-' + (++i), '$null = $null')
    const seqBeforeA = agent.session.seq
    const slowOut = path.join(dir, 'slow-out.txt')
    const slowClient = path.join(dir, 'slow-client.ps1')
    writeFileSync(slowClient, [
      "Import-Module '" + esc(modulePath) + "' -Force",
      'try {',
      "  $value = Invoke-DshTool -Name probe_slow -Arguments @{ ms = 15000 } -ErrorAction Stop",
      "  ('COMPLETED: ' + $value) | Set-Content -LiteralPath '" + esc(slowOut) + "'",
      '} catch {',
      "  ('FAILED: ' + $_.Exception.Message) | Set-Content -LiteralPath '" + esc(slowOut) + "'",
      '}',
    ].join(String.fromCharCode(10)))

    // A fully detached client calls a slow tool; the shell command returns
    // while that accepted call is still running. Every standard handle is
    // redirected so the child cannot hold this PTY open.
    const command = [
      '$psi = [System.Diagnostics.ProcessStartInfo]::new()',
      '$psi.FileName = (Get-Process -Id $PID).Path',
      "  $psi.Arguments = '-NoProfile -File \"' + (Resolve-Path -LiteralPath 'slow-client.ps1').Path + '\"'",
      '$psi.UseShellExecute = $false',
      '$psi.CreateNoWindow = $true',
      '$psi.RedirectStandardInput = $true',
      '$psi.RedirectStandardOutput = $true',
      '$psi.RedirectStandardError = $true',
      '$child = [System.Diagnostics.Process]::Start($psi)',
      '$child.StandardInput.Close()',
      'Start-Sleep -Seconds 5',
      "Write-Output 'SHELL_RETURNED'",
    ].join(String.fromCharCode(10))
    const started = Date.now()
    const result = await exec('outlive-' + (++i), command)
    const elapsed = Date.now() - started
    report.results.shellCommand = { text: textOf(result), elapsedMs: elapsed }
    // The official shell tool keeps the outer call open while a detached child
    // holds the console prompt, so "the shell returned first" is not the
    // observable guarantee here. What IS guaranteed and asserted below is that
    // the accepted call is cancelled with its execution and never succeeds.
    record('outlive.shell_command_ran', textOf(result).includes('SHELL_RETURNED'), report.results.shellCommand)

    let slowText = ''
    for (let wait = 0; wait < 100; wait += 1) {
      slowText = existsSync(slowOut) ? readFileSync(slowOut, 'utf8') : ''
      if (slowText.trim().length > 0) break
      await new Promise(resolve => setTimeout(resolve, 200))
    }
    const dispatch = events().slice(seqBeforeA).filter(e => String(e.type).startsWith('tool/ptc-dispatch'))
    report.results.dispatch = dispatch.map(e => ({ type: e.type, name: e.data.name, isError: e.data.isError }))
    const settled = dispatch.filter(e => e.type === 'tool/ptc-dispatch')
    record('outlive.accepted_work_settled_with_execution', dispatch.length === 2 && settled.length === 1 && settled[0].data.isError === true, report.results.dispatch)
    report.results.slowClientOutput = slowText
    record('outlive.client_saw_failure', slowText.length > 0 && !slowText.includes('SLOW_DONE_15000'), slowText.slice(0, 300))

    // Let the previous detached child release the console before the next
    // command runs; the persistent shell serializes commands, so this waits.
    await exec('barrier-1-' + (++i), "Write-Output 'BARRIER'")

    // Cancellation: the owning shell call is aborted while an accepted nested
    // call is still running. The nested call must be cancelled with it.
    const cancelOut = path.join(dir, 'cancel-out.txt')
    const cancelClient = path.join(dir, 'cancel-client.ps1')
    writeFileSync(cancelClient, [
      "Import-Module '" + esc(modulePath) + "' -Force",
      'try {',
      "  $value = Invoke-DshTool -Name probe_slow -Arguments @{ ms = 20000 } -ErrorAction Stop",
      "  ('COMPLETED: ' + $value) | Set-Content -LiteralPath '" + esc(cancelOut) + "'",
      '} catch {',
      "  ('FAILED: ' + $_.Exception.Message) | Set-Content -LiteralPath '" + esc(cancelOut) + "'",
      '}',
    ].join(String.fromCharCode(10)))
    const cancelCommand = command.replace("'slow-client.ps1'", "'cancel-client.ps1'").replace("Start-Sleep -Seconds 5", 'Start-Sleep -Seconds 60')
    const cancelController = new AbortController()
    const seqBeforeCancel = agent.session.seq
    const cancelRun = exec('cancel-owner-' + (++i), cancelCommand, cancelController.signal)
    await new Promise(resolve => setTimeout(resolve, 10000))
    cancelController.abort(new Error('probe cancellation'))
    await cancelRun.catch(() => {})
    await new Promise(resolve => setTimeout(resolve, 2000))
    const cancelDispatch = events().slice(seqBeforeCancel).filter(e => String(e.type).startsWith('tool/ptc-dispatch')).map(e => ({ type: e.type, name: e.data.name, isError: e.data.isError }))
    report.results.cancelDispatch = cancelDispatch
    const cancelSettled = cancelDispatch.filter(e => e.type === 'tool/ptc-dispatch')
    record('cancel.accepted_work_cancelled_with_execution', cancelDispatch.length === 2 && cancelSettled.length === 1 && cancelSettled[0]?.isError === true, cancelDispatch)
    let cancelText = ''
    for (let wait = 0; wait < 60; wait += 1) {
      cancelText = existsSync(cancelOut) ? readFileSync(cancelOut, 'utf8') : ''
      if (cancelText.trim().length > 0) break
      await new Promise(resolve => setTimeout(resolve, 200))
    }
    report.results.cancelClientOutput = cancelText
    record('cancel.client_saw_failure', cancelText.length > 0 && !cancelText.includes('SLOW_DONE_20000'), cancelText.slice(0, 300))

    await exec('barrier-2-' + (++i), "Write-Output 'BARRIER'")
    const controller = new AbortController()
    const abortedId = 'aborted-' + (++i)
    const longRun = exec(abortedId, 'Start-Sleep -Seconds 20', controller.signal)
    await new Promise(resolve => setTimeout(resolve, 2500))
    const during = await post(bridge.port, { 'x-dsh-cli-token': bridge.token }, { instance: bridge.instance, session: agent.id, call: abortedId, capability: 'x', op: 'list' })
    // Either the capability gate or the revoked execution refuses it; both are refusals of a call that is not validly in flight.
    record('aborted.rejects_list_while_live', typeof during.error === 'string', during)
    controller.abort(new Error('probe abort'))
    await longRun.catch(() => {})
    await new Promise(resolve => setTimeout(resolve, 500))
    const afterList = await post(bridge.port, { 'x-dsh-cli-token': bridge.token }, { instance: bridge.instance, session: agent.id, call: abortedId, capability: 'x', op: 'list' })
    const afterDescribe = await post(bridge.port, { 'x-dsh-cli-token': bridge.token }, { instance: bridge.instance, session: agent.id, call: abortedId, capability: 'x', op: 'describe', name: 'read' })
    const afterCall = await post(bridge.port, { 'x-dsh-cli-token': bridge.token }, { instance: bridge.instance, session: agent.id, call: abortedId, capability: 'x', op: 'call', name: 'read', arguments: {} })
    report.results.abortedAfter = { list: afterList, describe: afterDescribe, call: afterCall }
    record('aborted.rejects_every_entry_point', [afterList, afterDescribe, afterCall].every(r => typeof r.error === 'string'), report.results.abortedAfter)

    const holder = exec('holder-' + (++i), 'Start-Sleep -Seconds 4')
    await new Promise(resolve => setTimeout(resolve, 800))
    const waiting = new AbortController()
    const waiter = exec('waiter-' + (++i), "Write-Output 'WAITER'", waiting.signal)
    await new Promise(resolve => setTimeout(resolve, 500))
    waiting.abort(new Error('probe abort of the waiter'))
    const waiterResult = await waiter.then(value => value, error => ({ isError: true, content: [{ type: 'text', text: String((error && error.message) || error) }] }))
    await holder
    const after = await exec('after-abort-' + (++i), "Write-Output 'QUEUE_OK'")
    report.results.queue = { waiter: textOf(waiterResult).slice(0, 120), after: textOf(after).slice(0, 80) }
    record('lock.aborted_wait_releases_slot', waiterResult.isError === true && textOf(after).includes('QUEUE_OK'), report.results.queue)

    let sequential = 0
    for (let round = 0; round < 12; round += 1) {
      const r = await exec('seq-' + round + '-' + (++i), 'Write-Output ' + round)
      if (textOf(r).includes(String(round))) sequential += 1
    }
    record('lock.repeated_acquisition_stays_healthy', sequential === 12, sequential)

    report.completed = true
    save()
    await ctx.sessions.flush(agent.session)
    ctx.get('appExit')?.(report.checks.every(c => c.ok) ? 0 : 2)
  }

  run().catch(error => { report.error = error && error.stack ? error.stack : String(error); save(); ctx.get('appExit')?.(1) })
}
