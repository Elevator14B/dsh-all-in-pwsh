/**
 * dsh-all-in-pwsh: one persistent PowerShell 7 shell stays the only tool the
 * model can call directly, and every other mounted tool is reached from inside
 * it through the native object interface the shell imports at startup.
 *
 * Execution identity is per execution, not per "current call":
 *  - the bridge rendezvous holds STATIC configuration only (instance, host pid,
 *    port, token). No call id ever lands there, so a process that re-reads it
 *    cannot acquire a live identity.
 *  - before each shell command the host writes DSH_PWSH_BRIDGE, DSH_PWSH_CALL
 *    and a freshly minted random DSH_PWSH_CAP into that shell's environment. A
 *    command and everything it starts inherit exactly that identity.
 *  - the host keeps the identity in memory and revokes it when the command
 *    settles, so a background process started by an earlier command presents a
 *    revoked capability and is refused. It never upgrades to a later command.
 *  - one serial lock per agent covers activation, the shell execution, media
 *    collection and cleanup, so two executions of one session cannot overwrite
 *    each other's context. Accepted nested work is cancelled with the execution
 *    that owns it and settles before its identity is released.
 */

import { createServer } from 'node:http'
import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto'
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/** Cordis plugin name. */
export const name = 'dsh-all-in-pwsh'

/** The registries this row contributes to, and the PTY registry it drives. */
export const inject = ['tools', 'systemPrompt', 'terminals']

const TICK = '\u0060'
const HERE = path.dirname(fileURLToPath(import.meta.url))
const DSH_HOME = process.env.DSH_HOME ?? path.join(homedir(), '.dsh')
const ROOT = path.join(DSH_HOME, 'dsh-all-in-pwsh', 'instances')

/** Quote one value as a single-quoted PowerShell string literal. */
function psQuote(value) {
  return "'" + String(value).replaceAll("'", "''") + "'"
}

/** Read a whole request body. */
function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = []
    request.on('data', chunk => chunks.push(chunk))
    request.on('error', reject)
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
  })
}

/** Constant-time token comparison that tolerates a missing or wrong-length header. */
function tokenMatches(candidate, expected) {
  if (typeof candidate !== 'string') return false
  const left = Buffer.from(candidate)
  const right = Buffer.from(expected)
  return left.length === right.length && timingSafeEqual(left, right)
}

/** Whether a pid still belongs to a live process. */
function alive(pid) {
  if (typeof pid !== 'number' || !Number.isInteger(pid) || pid <= 0) return false
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error && error.code === 'EPERM'
  }
}

/** The media type of an image block, wherever the harness recorded it. */
function mediaTypeOf(block) {
  const attachment = block.attachment
  const candidate = (attachment && attachment.mediaType) ?? block.mimeType ?? block.mediaType
  return typeof candidate === 'string' && candidate.length > 0 ? candidate : 'image'
}

/**
 * Render one nested tool result as the text the shell prints. A non-text block
 * is named rather than dropped: the wrapper hands the block itself to the model
 * through additionalContexts, so the marker and the payload agree.
 */
function textOf(result) {
  if (result === undefined) return ''
  const parts = []
  for (const block of result.content ?? []) {
    if (block.type === 'text') parts.push(block.text)
    else if (block.type === 'image') parts.push('[image attached to this result: ' + mediaTypeOf(block) + ']')
    else parts.push('[' + String(block.type) + ' block attached to this result]')
  }
  return parts.join(String.fromCharCode(10))
}

/** The one-line parameter summary of the generated reference. */
function parameterSummary(parameters) {
  const properties = (parameters && parameters.properties) || {}
  const required = new Set((parameters && parameters.required) || [])
  const names = Object.keys(properties)
  if (names.length === 0) return 'none'
  return names.map(entry => (required.has(entry) ? entry : entry + '?')).join(', ')
}

/** First sentence of a tool description, for the one-line catalog. */
function summarize(description) {
  const text = String(description === undefined ? '' : description).replace(/\s+/g, ' ').trim()
  if (text.length === 0) return ''
  const stop = text.search(/\.\s|\.$/)
  const head = stop === -1 ? text : text.slice(0, stop + 1)
  return head.length > 160 ? head.slice(0, 157) + '...' : head
}

/**
 * The catalog-derived reference: the counterpart of PTC mode's generated SDK
 * block, at the same prompt slot and regenerated from the calling scope's live
 * catalog on every assembly.
 */
function renderReference(schemas, transport) {
  const others = schemas.filter(schema => schema.name !== transport)
  const lines = [
    "## Calling tools from the shell",
    "",
    "The `pwsh` tool is the only tool you can call directly: it runs PowerShell code in a persistent environment, and that code calls the session's other tools through the object interface this shell has imported.",
    "",
    "    Invoke-DshTool -Name read -Arguments @{ file_path = 'C:\\work\\note.txt' }",
    "    dsh-tool write @{ file_path = 'note.txt'; content = 'line one' }",
    "    Get-DshTool                      # every callable tool",
    "    Get-DshToolSchema -Name read     # that tool's exact parameter schema",
    "",
    "Prefer this order when a step needs work:",
    "",
    "1. Reach mounted capabilities with `Invoke-DshTool` or `dsh-tool`. Use PowerShell for variables, loops, branching, pipelines and in-memory transformation.",
    "2. For reading, writing, editing or searching task files use the `read`, `write`, `edit`, `glob` and `grep` tools. Do not substitute `Get-Content`, `Set-Content`, .NET or Python file I/O just to save calls.",
    "3. Native processes stay appropriate for real build, test and toolchain commands.",
    "",
    "Group related calls whose arguments are already known into one block. Dependencies can stay in one block whenever the code expresses them; come back to the model when the next step needs judgment. Sequential nested calls are valid batching - no need to spawn workers for it - and each nested call has its own UI and log row. Retain variables and results, emit concise evidence, and do not truncate fields the next decision needs.",
    "",
    "Arguments are a PowerShell object: a hashtable, an ordered dictionary or a PSCustomObject. Never build JSON text, never escape quotes by hand, and never write an arguments file. An omitted -Arguments means an empty object. Nested hashtables and arrays, $null, $true/$false, integers, decimals, Unicode, newlines, quotes and backslashes all cross unchanged.",
    "",
    "The command prints the tool result text and returns normally on success. Use -PassThru and check errors explicitly: for example try/catch with -ErrorAction Stop where dependent actions must stop, and do not continue past a failed prerequisite.",
    "",
    "This is not a rule that everything must happen in one block: keep a step's work together when the code can express it, and return to the model when the next step needs a decision.",
    "",
    "Every nested call must finish before the block returns: the execution identity belongs to the block that started it, and work that outlives the block is refused.",
    "",
  ]
  if (others.length === 0) {
    lines.push('No other tool is mounted in this composition.')
    return lines.join(String.fromCharCode(10))
  }
  lines.push('### Available tools', '')
  for (const schema of others) {
    const summary = summarize(schema.description)
    lines.push('- ' + TICK + schema.name + TICK + (summary.length > 0 ? ' - ' + summary : ''))
    lines.push('  parameters: ' + parameterSummary(schema.parameters))
  }
  lines.push('')
  lines.push('Run ' + TICK + 'Get-DshToolSchema -Name <tool>' + TICK + ' before a call whose arguments you are unsure of.')
  return lines.join(String.fromCharCode(10))
}

/**
 * A queue that serializes work per key while letting independent keys run in
 * parallel. An aborted wait releases its slot and drops the key's queue entry
 * once nothing is behind it, so abandoned waits cannot accumulate.
 */
export function createSerialLocks() {
  const tails = new Map()
  return {
    /** Live queue entries, one per key with a held or queued slot; used by tests. */
    pending() { return tails.size },
    /**
     * Wait for the key's predecessor, then hold it until the returned function
     * runs.
     * @param key - the agent this lock belongs to.
     * @param signal - cancels the wait, not the hold.
     * @returns the release function for the acquired hold.
     */
    async acquire(key, signal) {
      const previous = tails.get(key) ?? Promise.resolve()
      let release
      const held = new Promise(resolve => { release = resolve })
      const chained = previous.then(() => held, () => held)
      tails.set(key, chained)
      const settle = () => {
        release()
        if (tails.get(key) === chained) tails.delete(key)
      }
      let onAbort
      try {
        if (signal === undefined) {
          await previous
        } else {
          await Promise.race([previous, new Promise((_, reject) => {
            if (signal.aborted) { reject(signal.reason); return }
            onAbort = () => { reject(signal.reason ?? new Error('aborted while waiting for the shell lock')) }
            signal.addEventListener('abort', onAbort, { once: true })
          })])
        }
      } catch (error) {
        settle()
        throw error
      } finally {
        if (onAbort !== undefined && signal !== undefined) signal.removeEventListener('abort', onAbort)
      }
      return settle
    },
  }
}

/**
 * Install the mode into the calling composition scope.
 * @param ctx - the preset's standing scope context, inside the shell group.
 * @param config - the registered shell tool that stays directly callable.
 */
export function apply(ctx, config) {
  const transport = (config && config.transport) || 'pwsh'
  if (process.platform !== 'win32') {
    throw new Error('dsh-all-in-pwsh: only Windows with PowerShell 7 is supported; this host is ' + process.platform)
  }
  if (transport !== 'pwsh') {
    throw new Error('dsh-all-in-pwsh: the transport must be the persistent pwsh tool, not ' + JSON.stringify(transport))
  }
  const instance = randomBytes(6).toString('hex')
  const INSTALL = path.join(ROOT, instance)
  const BRIDGE_FILE = path.join(INSTALL, 'bridge.json')
  const token = randomBytes(24).toString('hex')

  mkdirSync(INSTALL, { recursive: true })
  pruneDeadInstances()

  /** Remove install directories left by hosts that are no longer running. */
  function pruneDeadInstances() {
    let entries
    try { entries = readdirSync(ROOT) } catch { return }
    for (const entry of entries) {
      if (entry === instance) continue
      const candidate = path.join(ROOT, entry, 'bridge.json')
      let published
      try { published = JSON.parse(readFileSync(candidate, 'utf8')) } catch { continue }
      if (published && published.pid !== undefined && !alive(published.pid)) {
        try { rmSync(path.join(ROOT, entry), { recursive: true, force: true }) } catch { /* another host may be racing the same cleanup */ }
      }
    }
  }

  const locks = createSerialLocks()
  /** Live executions by call id. The capability never leaves this map. */
  const active = new Map()
  /** The execution currently holding each agent's lock. */
  const holders = new Map()
  /** Exact call ids of this plugin's own shell warm-up invocations. */
  const warmups = new Set()
  /** Non-text result blocks collected for one transport execution. */
  const media = new Map()
  /** Per-execution sub-call counter. */
  const counters = new WeakMap()
  let bridge
  let port = null
  let bridgePromise
  let bridgeError

  /**
   * Publish the STATIC rendezvous: endpoint and instance identity only. Call
   * ids and capabilities are deliberately absent, so re-reading this file can
   * never refresh an execution identity.
   */
  function publish() {
    writeFileSync(BRIDGE_FILE, JSON.stringify({ instance, pid: process.pid, port, token }), { mode: 0o600 })
  }

  /** Start the loopback bridge once and publish its rendezvous. */
  function ensureBridge() {
    if (bridgeError !== undefined) return Promise.reject(bridgeError)
    if (bridgePromise === undefined) {
      bridgePromise = startBridge().catch(error => {
        bridgeError = error
        throw error
      })
    }
    return bridgePromise
  }

  /** Bind the endpoint and republish the rendezvous with its port. */
  async function startBridge() {
    const server = createServer((request, response) => {
      void (async () => {
        try {
          if (request.method !== 'POST' || request.url !== '/rpc') {
            response.writeHead(404).end('{}')
            return
          }
          if (!tokenMatches(request.headers['x-dsh-cli-token'], token)) {
            response.writeHead(403, { 'content-type': 'application/json' })
              .end(JSON.stringify({ error: 'bad bridge token' }))
            return
          }
          const payload = JSON.parse(await readBody(request))
          response.writeHead(200, { 'content-type': 'application/json' })
            .end(JSON.stringify(await handle(payload)))
        } catch (error) {
          response.writeHead(500, { 'content-type': 'application/json' })
            .end(JSON.stringify({ error: String((error && error.message) || error) }))
        }
      })()
    })
    await new Promise((resolve, reject) => {
      server.once('error', reject)
      server.listen(0, '127.0.0.1', resolve)
    })
    bridge = server
    port = server.address().port
    publish()
  }

  /** The live PTY session that runs this agent's shell, when one exists. */
  function shellSession(agent) {
    let sessions
    try { sessions = ctx.terminals.list(agent) } catch { return undefined }
    if (!Array.isArray(sessions)) return undefined
    const live = sessions.filter(candidate => candidate.status === undefined || candidate.status.kind !== 'exited')
    return live.find(candidate => candidate.type === 'shell') ?? live[0]
  }

  /**
   * Write the execution identity into the shell's own environment. A command and
   * every process it starts inherit exactly this value; the next execution
   * overwrites it in the shell but not in any already-running child.
   */
  async function injectIdentity(agent, record, signal) {
    const session = shellSession(agent)
    if (session === undefined) return false
    const text = [
      '$env:DSH_PWSH_BRIDGE=' + psQuote(BRIDGE_FILE),
      '$env:DSH_PWSH_CALL=' + psQuote(record.callId),
      '$env:DSH_PWSH_CAP=' + psQuote(record.capability),
    ].join('; ')
    const operation = ctx.terminals.startSend(agent, session.sessionId, { text, submit: true, signal })
    const result = await operation.done
    if (result !== undefined && result.sessionStatus !== undefined && result.sessionStatus.kind === 'exited') {
      throw new Error('the persistent shell exited while the execution identity was being published')
    }
    return true
  }

  /**
   * Create the agent's shell once, before the first identity is published. The
   * shell tool owns its creation, so this runs one cheap statement through it
   * and waits for the PTY session to appear. Only this exact invocation is
   * allowed to bypass the agent's lock.
   */
  async function ensureShell(agent, exec) {
    if (shellSession(agent) !== undefined) return
    const warmupCallId = exec.callId + ':warm'
    warmups.add(warmupCallId)
    let outcome
    try {
      outcome = await ctx.tools.execute({
        callId: warmupCallId,
        rootCallId: exec.rootCallId,
        name: transport,
        arguments: { command: '$null = $null' },
        agent,
        signal: exec.signal,
      })
    } finally {
      warmups.delete(warmupCallId)
    }
    for (let attempt = 0; attempt < 100 && shellSession(agent) === undefined; attempt += 1) {
      await new Promise(resolve => setTimeout(resolve, 20))
    }
    if (shellSession(agent) === undefined) {
      throw new Error('dsh-all-in-pwsh: the persistent shell did not start, so the execution identity could not be published' + (outcome !== undefined && outcome.isError === true ? ': ' + textOf(outcome) : ''))
    }
  }

  /** Identity keys one agent answers to. */
  function keysFor(agent) {
    const keys = []
    const id = String(agent.id ?? '')
    if (id.length > 0) keys.push(id)
    const sessionId = String((agent.session && agent.session.id) ?? '')
    if (sessionId.length > 0 && !keys.includes(sessionId)) keys.push(sessionId)
    return keys
  }

  /**
   * Answer one bridged request. Every operation, discovery included, must carry
   * the complete identity of an execution that is still active.
   */
  async function handle(payload) {
    if (payload === null || typeof payload !== 'object') return { error: 'malformed bridge request' }
    if (payload.instance !== instance) {
      return { error: 'this bridge belongs to dsh-all-in-pwsh instance ' + JSON.stringify(instance) + ', not ' + JSON.stringify(payload.instance) + '; use the entry point this shell was given' }
    }
    const session = typeof payload.session === 'string' ? payload.session : ''
    const call = typeof payload.call === 'string' ? payload.call : ''
    const capability = typeof payload.capability === 'string' ? payload.capability : ''
    if (session.length === 0 || call.length === 0 || capability.length === 0) {
      return { error: 'this request carries no complete execution identity: instance, session, call and capability are all required, and the shell supplies them for the command it is running' }
    }
    const record = active.get(call)
    if (record === undefined || !record.keys.includes(session)) {
      return { error: 'no ' + transport + ' call named ' + JSON.stringify(call) + ' is in flight for session ' + JSON.stringify(session) + ': a bridged call only works inside the shell command that started it' }
    }
    if (record.capability !== capability) {
      return { error: 'the capability does not match the call in flight; this caller inherited an execution identity that has already been revoked, most likely a background process started by an earlier command' }
    }
    const exec = record.exec
    if (record.closed || exec.signal.aborted) {
      return { error: 'this execution is no longer active: the shell command that owned call ' + JSON.stringify(call) + ' has finished or was cancelled' }
    }
    const schemas = ctx.tools.schemas(exec.agent)
    if (payload.op === 'list') {
      return {
        tools: schemas
          .filter(schema => schema.name !== transport)
          .map(schema => ({ name: schema.name, description: summarize(schema.description) })),
      }
    }
    if (payload.op === 'describe') {
      const schema = schemas.find(candidate => candidate.name === payload.name)
      return schema === undefined ? { error: 'unknown tool ' + JSON.stringify(payload.name) } : { schema }
    }
    const toolName = payload.name
    if (typeof toolName !== 'string' || toolName.length === 0) return { error: 'a tool name is required' }
    if (toolName === transport) return { error: 'the ' + transport + ' tool cannot be called through the bridge; run the command directly' }
    if (!schemas.some(schema => schema.name === toolName)) return { error: 'unknown tool ' + JSON.stringify(toolName) }
    const agent = exec.agent
    if (agent === undefined) return { error: 'the shell call has no owning agent session' }

    // Accepted work is tied to the execution that accepted it: the wrapper
    // cancels and settles everything in flight before the identity is released,
    // so nothing can append to the log or to the media map afterwards.
    const operation = dispatchNested(record, agent, toolName, payload.arguments)
    record.running.add(operation)
    try {
      return await operation
    } finally {
      record.running.delete(operation)
    }
  }

  /** Run one bridged tool call and record its durable dispatch pair. */
  async function dispatchNested(record, agent, toolName, argumentValue) {
    const exec = record.exec
    const ordinal = (counters.get(exec) || 0) + 1
    counters.set(exec, ordinal)
    const subCallId = exec.callId + ':cli:' + String(ordinal)
    const start = {
      rootCallId: exec.rootCallId,
      parentCallId: exec.callId,
      subCallId,
      name: toolName,
      arguments: argumentValue === undefined ? {} : argumentValue,
    }
    agent.session.append('tool/ptc-dispatch-start', start)
    const signal = AbortSignal.any([exec.signal, record.nested.signal])
    let result
    try {
      result = await ctx.tools.execute({
        callId: subCallId,
        rootCallId: exec.rootCallId,
        name: toolName,
        arguments: start.arguments,
        agent,
        parent: exec.token,
        signal,
      })
    } catch (error) {
      result = { isError: true, content: [{ type: 'text', text: 'Error: ' + String((error && error.message) || error) }] }
    }
    const info = result && result.error && result.error.info
    agent.session.append('tool/ptc-dispatch', Object.assign({}, start, {
      isError: result.isError === true,
      content: result.content,
    }, info === undefined ? {} : {
      error: Object.assign({ name: String(info.name), code: String(info.code) },
        info.reason === undefined ? {} : { reason: String(info.reason) }),
    }))
    const extra = (result.content ?? []).filter(block => block.type !== 'text')
    if (extra.length > 0) {
      const collected = media.get(exec.callId)
      if (collected === undefined) media.set(exec.callId, extra.slice())
      else collected.push(...extra)
    }
    return { isError: result.isError === true, text: textOf(result) }
  }

  ctx.effect(() => () => {
    if (bridge !== undefined) bridge.close()
    bridge = undefined
    try { rmSync(INSTALL, { recursive: true, force: true }) } catch { /* the install directory may already be gone */ }
  }, 'dsh-all-in-pwsh.bridge()')

  publish()
  ensureBridge().catch(() => {})

  // 1. Narrow the wire catalog. The registry view stays complete, so bridging
  //    reaches every mounted tool and the reference lists every mounted tool.
  ctx.on('system-prompt/assemble', async (assembly, context, next) => {
    const assembled = await next()
    const tools = assembled.tools.filter(schema => schema.name === transport)
    return tools.length === assembled.tools.length ? assembled : Object.assign({}, assembled, { tools })
  })

  // 2. The collapse rule, at PTC mode's own slot, so it lands before every tool
  //    guidance section the mounted tool rows contribute.
  ctx.systemPrompt.section({
    name: 'dsh-all-in-pwsh:only',
    order: ctx.systemPrompt.getSectionOrder('PTC_ONLY'),
    text: TICK + transport + TICK + ' is the only tool you can call directly - a tool call naming any other tool fails. That code calls the other tools through the object interface the reference below documents.',
  })

  // 3. The catalog-derived reference, at the slot PTC mode's SDK uses.
  ctx.systemPrompt.section({
    name: 'dsh-all-in-pwsh:reference',
    order: ctx.systemPrompt.getSectionOrder('TOOLS_SDK'),
    interpolate: false,
    text: context => renderReference(ctx.tools.schemas(context.scope), transport),
  })

  // 4. Deny a model-direct call to any other tool, naming the route. A bridged
  //    sub-dispatch carries a parent token and is deliberately exempt.
  ctx.tools.guard(exec => {
    if (exec.name === transport || exec.parent !== undefined) return undefined
    return TICK + transport + TICK + ' is the only tool you can call directly; call ' + TICK + exec.name + TICK + ' through Invoke-DshTool inside that shell instead'
  })

  // 5. One serial lock per agent around the whole transport lifetime: identity
  //    activation, the shell execution, media collection and cleanup.
  ctx.on('tools/execute', async (exec, next) => {
    if (exec.name !== transport) return next()
    // Only this plugin's own shell warm-up bypasses the queue; it is the one
    // invocation that must run while its owner still holds the lock.
    if (warmups.has(exec.callId)) return next()
    const agent = exec.agent
    if (agent === undefined) return next()
    const key = String(agent.id ?? '')
    if (key.length === 0) return next()
    // A transport dispatch nested inside the execution that already holds this
    // agent's lock belongs to that command; queueing it would deadlock.
    const holder = holders.get(key)
    if (exec.parent !== undefined && holder !== undefined && holder.exec.token === exec.parent) return next()

    const release = await locks.acquire(key, exec.signal)
    let record
    try {
      exec.signal.throwIfAborted()
      await ensureShell(agent, exec)
      exec.signal.throwIfAborted()
      record = {
        callId: exec.callId,
        keys: keysFor(agent),
        capability: randomBytes(18).toString('hex'),
        exec,
        nested: new AbortController(),
        running: new Set(),
        closed: false,
      }
      active.set(record.callId, record)
      holders.set(key, record)
      try {
        await injectIdentity(agent, record, exec.signal)
        const result = await next()
        const collected = media.get(exec.callId)
        if (collected === undefined || collected.length === 0) return result
        // additionalContexts is the only channel that survives normalization:
        // for a SUCCESSFUL result the registry re-renders content from the
        // tool's own value projection, so an appended block there is discarded.
        const prior = (result && result.additionalContexts) || []
        return Object.assign({}, result, {
          additionalContexts: [...prior, {
            id: randomUUID(),
            role: 'user',
            content: [
              { type: 'text', text: 'Image content returned by a tool called through the shell bridge:' },
              ...collected,
            ],
            source: { kind: 'plugin', plugin: 'dsh-all-in-pwsh' },
          }],
        })
      } finally {
        // Cancel and settle accepted nested work BEFORE the identity and the
        // media it may still contribute are released.
        record.closed = true
        record.nested.abort(new Error('the shell command that owned this execution ended'))
        await Promise.allSettled([...record.running])
        active.delete(record.callId)
        media.delete(exec.callId)
        if (holders.get(key) === record) holders.delete(key)
      }
    } finally {
      release()
    }
  })
}
