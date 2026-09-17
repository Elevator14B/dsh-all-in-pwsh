/**
 * Integration probe ported from the development harness. Requires a real DSH
 * runtime; it does not need a model account unless it says so.
 * The preset id under test comes from PROBE_PRESET.
 */
const PRESET = process.env.PROBE_PRESET || 'dsh-all-in-pwsh'
import { writeFileSync, readFileSync, existsSync } from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { pathToFileURL } from 'node:url'

export const name = 'review-cold-pwsh'
export const inject = ['agents', 'agentPresets', 'sessions']

export function apply(ctx) {
  const out = process.env.PROBE_OUT
  const dir = process.cwd()
  const report = { checks: [], results: {} }
  const save = () => writeFileSync(out, JSON.stringify(report, null, 2))
  const record = (name, ok, detail) => { report.checks.push({ name, ok, detail }); save() }

  async function run() {
    await ctx.get('loader')?.await()
    const { agent } = await ctx.agents.create({
      sessionId: 'session-' + randomUUID(),
      meta: { cwd: dir, agentPreset: PRESET },
      setup: async c => { await ctx.agentPresets.mount(c, PRESET) },
    })
    await agent.whenIdle()
    writeFileSync(path.join(dir, 'one.txt'), 'ONE')
    writeFileSync(path.join(dir, 'two.txt'), 'TWO')
    const call = (id, file) => agent.ctx.tools.execute({
      callId: id,
      rootCallId: id,
      name: 'pwsh',
      arguments: { command: "dsh-tool read @{ file_path = '" + file + "' } -ErrorAction Stop" },
      agent,
      signal: new AbortController().signal,
    })
    const settled = await Promise.allSettled([call('cold-one', 'one.txt'), call('cold-two', 'two.txt')])
    const textOf = value => (value.content || []).filter(b => b.type === 'text').map(b => b.text).join('')
    report.results.results = settled.map(entry => entry.status === 'fulfilled'
      ? { status: entry.status, isError: entry.value.isError, text: textOf(entry.value) }
      : { status: entry.status, error: String(entry.reason) })
    report.results.nested = agent.session.snapshotEvents().filter(e => e.type === 'tool/ptc-dispatch').map(e => ({ name: e.data.name, parent: e.data.parentCallId, isError: e.data.isError }))
    save()

    const outputs = report.results.results.map(entry => entry.text ?? '')
    record('cold.both_calls_fulfilled', settled.every(entry => entry.status === 'fulfilled'), report.results.results)
    record('cold.first_reads_one', outputs.some(text => text.includes('ONE')), outputs)
    record('cold.second_reads_two', outputs.some(text => text.includes('TWO')), outputs)
    const parents = report.results.nested.map(entry => entry.parent + ':' + entry.name)
    record('cold.each_nested_has_own_parent',
      report.results.nested.length === 2 && parents.includes('cold-one:read') && parents.includes('cold-two:read'),
      report.results.nested)
    record('cold.no_shell_error', outputs.every(text => !text.includes('not active in this shell')), outputs)

    // The same concurrency on an ALREADY WARM shell must behave identically; a
    // passing cold round alone would not prove the queue, and a warm round alone
    // would not prove the first-use path.
    const warmBefore = agent.session.seq
    const warmSettled = await Promise.allSettled([call('warm-one', 'one.txt'), call('warm-two', 'two.txt')])
    const warmTexts = warmSettled.map(entry => entry.status === 'fulfilled' ? textOf(entry.value) : '')
    const warmNested = []
    for (let n = warmBefore; n < agent.session.seq; n += 1) {
      const e = agent.session.eventAt(n)
      if (e && e.type === 'tool/ptc-dispatch') warmNested.push({ parent: e.data.parentCallId, name: e.data.name })
    }
    report.results.warm = { texts: warmTexts, nested: warmNested }
    record('warm.both_calls_fulfilled', warmSettled.every(entry => entry.status === 'fulfilled') && warmTexts.some(t => t.includes('ONE')) && warmTexts.some(t => t.includes('TWO')), report.results.warm)
    record('warm.each_nested_has_own_parent',
      warmNested.length === 2 && warmNested.some(e => e.parent === 'warm-one') && warmNested.some(e => e.parent === 'warm-two'),
      warmNested)

    report.completed = true
    save()
    await ctx.sessions.flush(agent.session)
    ctx.get('appExit')?.(report.checks.every(c => c.ok) ? 0 : 2)
  }

  run().catch(error => { report.error = error && error.stack ? error.stack : String(error); save(); ctx.get('appExit')?.(1) })
}
