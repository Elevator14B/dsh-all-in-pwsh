/**
 * Account-free checks for the per-agent serial queue exported by the plugin.
 *
 * This is the mechanism that keeps two executions of one session from
 * overwriting each other's identity, so its cleanup behaviour is verified
 * directly here rather than inferred: an aborted wait must release its slot and
 * must not leave the key's queue entry behind.
 *
 * Run: node ./tests/unit/serial-locks.mjs
 */
import { createSerialLocks } from '../../preset/plugin/dsh-all-in-pwsh.mjs'

const failures = []
const record = (name, ok, detail) => {
  console.log((ok ? 'PASS  ' : 'FAIL  ') + name)
  if (!ok) {
    if (detail !== undefined) console.log('      ' + JSON.stringify(detail))
    failures.push(name)
  }
}
const tick = () => new Promise(resolve => setTimeout(resolve, 0))
const settled = promise => { let done = false; promise.then(() => { done = true }, () => { done = true }); return tick().then(() => done) }
const aborted = (reason) => { const c = new AbortController(); c.abort(new Error(reason)); return c.signal }

// Independent keys do not wait for each other.
{
  const locks = createSerialLocks()
  const releaseA = await locks.acquire('a')
  const releaseB = await locks.acquire('b')
  record('locks.independent_keys_parallel', locks.pending() === 2, locks.pending())
  releaseA(); releaseB()
  record('locks.drains_to_empty', locks.pending() === 0, locks.pending())
}

// One key serializes, and the queued waiter runs only after the release.
{
  const locks = createSerialLocks()
  const releaseFirst = await locks.acquire('k')
  const second = locks.acquire('k')
  const finishedEarly = await settled(second)
  releaseFirst()
  const releaseSecond = await second
  record('locks.same_key_serializes', finishedEarly === false, { finishedEarly })
  releaseSecond()
  record('locks.same_key_drains', locks.pending() === 0, locks.pending())
}

// An already-aborted signal never acquires, and releases the slot it took.
{
  const locks = createSerialLocks()
  const releaseHeld = await locks.acquire('k')
  let rejected = false
  try { await locks.acquire('k', aborted('pre-aborted')) } catch { rejected = true }
  const other = await locks.acquire('other')
  record('locks.pre_aborted_wait_rejected', rejected, rejected)
  releaseHeld(); other === undefined
  record('locks.pre_aborted_wait_leaves_no_entry', locks.pending() === 1, locks.pending())
  releaseHeld === undefined
}

// An aborted wait releases its queue slot instead of stranding it.
{
  const locks = createSerialLocks()
  const releaseHolder = await locks.acquire('k')
  const controller = new AbortController()
  const waiter = locks.acquire('k', controller.signal)
  await tick()
  controller.abort(new Error('aborted while queued'))
  let rejected = false
  try { await waiter } catch { rejected = true }
  releaseHolder()
  const releaseNext = await locks.acquire('k')
  record('locks.aborted_wait_rejected', rejected, rejected)
  record('locks.aborted_wait_did_not_strand_queue', releaseNext !== undefined && locks.pending() === 1, locks.pending())
  releaseNext()
  record('locks.aborted_wait_drains', locks.pending() === 0, locks.pending())
}

// Many interleaved cycles on several keys leave nothing behind.
{
  const locks = createSerialLocks()
  for (let round = 0; round < 50; round += 1) {
    const key = 'agent-' + (round % 4)
    const release = await locks.acquire(key)
    if (round % 7 === 0) {
      try { await locks.acquire(key, aborted('cycle abort')) } catch { /* expected */ }
    }
    release()
  }
  record('locks.many_cycles_drain_to_empty', locks.pending() === 0, locks.pending())
}

// A long same-key queue still lets other keys through immediately.
{
  const locks = createSerialLocks()
  const releaseHeld = await locks.acquire('busy')
  const queued = [locks.acquire('busy'), locks.acquire('busy'), locks.acquire('busy')]
  const releaseOther = await locks.acquire('free')
  record('locks.busy_key_does_not_block_others', releaseOther !== undefined, locks.pending())
  releaseHeld()
  for (const entry of queued) (await entry)()
  releaseOther()
  record('locks.busy_key_queue_drains', locks.pending() === 0, locks.pending())
}

console.log('')
if (failures.length > 0) {
  console.log('FAILED: ' + failures.length + ' check(s): ' + failures.join(', '))
  process.exit(1)
}
console.log('All serial-queue checks passed.')
