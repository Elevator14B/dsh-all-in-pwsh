/**
 * dsh-all-in-pwsh: one persistent PowerShell 7 shell stays the only tool the
 * model can call directly, and every other mounted tool is reached from inside
 * it through native PowerShell tool objects and result objects.
 *
 * The bridge answers four operations, and only the last one executes a tool:
 *  - list:  name and one-line summary for the catalog (Get-DshTool)
 *  - get:   the full definition (schemas, return contract, version) for one or
 *           more names, so the shell can build reusable DshTool objects
 *  - call:  one nested tool execution returning ONE result object: the registry
 *           value, the rendered content, the display text, a structured error
 *           and per-call metadata
 *  - refresh is get for a single name; nothing else about a tool object is I/O
 *
 * The read tool keeps its registry dispatch, permissions, observation and UI
 * card, and this preset's read contract is completed here: the shell receives
 * the whole decoded text of the requested scope in .Value.Text through the
 * registered fs provider (ctx.fs.resolve/stat/readBytes/streamText, so sandbox
 * enforcement, cancellation and provider errors all still apply). A scope over
 * the configured limit fails explicitly instead of returning a prefix.
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
import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto'
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/** Cordis plugin name. */
export const name = 'dsh-all-in-pwsh'

/** The registries this row contributes to, and the services it drives. */
export const inject = ['tools', 'systemPrompt', 'terminals', 'fs', 'agents']

const TICK = '\u0060'
const HERE = path.dirname(fileURLToPath(import.meta.url))
const DSH_HOME = process.env.DSH_HOME ?? path.join(homedir(), '.dsh')
const ROOT = path.join(DSH_HOME, 'dsh-all-in-pwsh', 'instances')

/** The one tool whose value contract this preset completes beyond the registry value. */
const READ_TOOL = 'read'

/** Default ceiling for one full-text read scope; configurable on the preset row. */
const DEFAULT_READ_FULL_MAX_BYTES = 8 * 1024 * 1024

/**
 * Validated usage examples, keyed by tool name. Only calls this preset's test
 * suite actually executes appear here: an example that was never run is not
 * evidence of anything.
 */
const EXAMPLES = {
  read: [
    {
      arguments: { file_path: 'orders.json' },
      note: 'prints a bounded preview; .Value.Text holds the complete decoded text of the requested scope',
    },
  ],
  write: [
    {
      arguments: { file_path: 'summary.md', content: 'total: 47.50\n' },
      note: 'creates or replaces the file; .Value reports the written path and outcome',
    },
  ],
  edit: [
    {
      arguments: { file_path: 'notes.txt', old_string: 'STATUS: draft', new_string: 'STATUS: final' },
      note: 'replaces one literal string; the mounted observation policy requires reading the file first, and a missing match fails instead of silently succeeding',
    },
  ],
}

/** One bridge-level refusal: a string error, a stable code, and no "ok" field. */
function refusalReply(code, message) {
  return { error: message, code }
}

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

/**
 * One content block as JSON the shell can hold. A JSON-serializable block is
 * preserved whole, large fields included: .Content is the original content,
 * not a summary of it. A block that the wire cannot carry is named for what it
 * is instead of pretending to be the original.
 */
function jsonSafeBlock(block) {
  const type = String((block && block.type) ?? 'unknown')
  try {
    const encoded = JSON.stringify(block)
    if (typeof encoded === 'string') return JSON.parse(encoded)
  }
  catch {
    // Falls through to the explicit non-JSON representation below.
  }
  return {
    type,
    note: 'this content block does not survive JSON serialization; the original stays on the model/media channel unchanged',
  }
}

/** The JSON-safe projection of a result's content blocks, in order. */
function contentBlocksOf(result) {
  return (result.content ?? []).map(jsonSafeBlock)
}

/** First sentence of a tool description, for the one-line catalog. */
function summarize(description) {
  const text = String(description === undefined ? '' : description).replace(/\s+/g, ' ').trim()
  if (text.length === 0) return ''
  const stop = text.search(/\.\s|\.$/)
  const head = stop === -1 ? text : text.slice(0, stop + 1)
  return head.length > 160 ? head.slice(0, 157) + '...' : head
}

/** Deterministic JSON with sorted object keys, so a fingerprint cannot drift on key order. */
function canonicalJson(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value) ?? 'null'
  if (Array.isArray(value)) return '[' + value.map(entry => canonicalJson(entry)).join(',') + ']'
  const keys = Object.keys(value).sort()
  return '{' + keys.map(key => JSON.stringify(key) + ':' + canonicalJson(value[key])).join(',') + '}'
}

/** The version fingerprint of one tool definition, stable across processes. */
function definitionVersionOf(toolName, definition) {
  const material = canonicalJson({
    name: toolName,
    description: String(definition.description ?? ''),
    parameters: definition.parameters ?? null,
    outputSchema: (definition.output && definition.output.schema) ?? null,
  })
  return createHash('sha256').update(material, 'utf8').digest('hex').slice(0, 16)
}

/** The return contract stated for one tool: what a caller may rely on, and nothing more. */
function returnContractFor(toolName, definition, config) {
  const outputSchema = (definition.output && definition.output.schema) ?? null
  if (toolName === READ_TOOL) {
    return {
      value: {
        source: 'preset-read-contract',
        fields: ['path', 'text', 'lines', 'offset', 'limit', 'endLine', 'totalLines'],
        text: 'the complete decoded text of the requested scope: the whole file when no offset/limit is given, otherwise exactly the requested line range',
        lines: 'the same scope line by line, untruncated, without line terminators',
        preview: 'the printed text is a bounded preview; truncation never reaches .Value.Text',
      },
      scope: {
        default: 'the whole file',
        explicit: 'offset and limit select a line range that is returned complete',
      },
      limits: {
        readFullMaxBytes: config.readFullMaxBytes,
        note: 'a whole-file read over this limit fails with the provider\'s own FS_TOO_LARGE; a requested line range whose text exceeds it fails with a message and no structured code, because the provider owns no range cap',
      },
      failures: [
        'a missing path fails with the provider\'s own FS_NOT_FOUND',
        'a path that is not a regular file fails with a message and no code',
        'an offset past the last line fails with a message and no code',
        'a whole-file read over the byte limit fails with the provider\'s FS_TOO_LARGE',
        'a requested line range whose text exceeds the byte limit fails with a message and no code',
        'content the provider cannot decode as UTF-8 text fails with a message; images use read_image',
      ],
    }
  }
  return {
    value: {
      source: 'registry',
      schema: outputSchema,
      note: outputSchema === null
        ? 'the tool declares no output schema; HasValue reports whether a structured value was produced'
        : 'the registry declares this output schema; fields arrive exactly as the tool produced them',
    },
    display: 'the text the tool itself rendered',
    failures: ['tool failures are raised by Invoke and returned by TryInvoke; neither is retried automatically'],
  }
}

/**
 * The registered read operation's value as raw JSON Schema in the harness's
 * compiled form (object-level \`required\` arrays, never per-property flags):
 * the complete decoded text of the requested scope, that scope's own
 * line-numbered lines, its coordinates, and the exact file total. \`limit\` is
 * the number of lines in the returned scope (0 for an empty scope).
 */
const READ_VALUE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['path', 'text', 'lines', 'offset', 'limit', 'endLine', 'totalLines'],
  properties: {
    path: { type: 'string', description: 'the path the filesystem provider resolved' },
    text: { type: 'string', description: 'the complete decoded text of the requested scope' },
    lines: {
      type: 'array',
      description: 'the requested scope line by line, untruncated, without line terminators',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['number', 'text'],
        properties: {
          number: { type: 'integer', description: '1-based line number in the file' },
          text: { type: 'string', description: 'the line without its terminator' },
        },
      },
    },
    offset: { type: 'integer', description: '1-based first line of the returned scope' },
    limit: { type: 'integer', description: 'number of lines in the returned scope' },
    endLine: { type: 'integer', description: 'last line included in the returned scope' },
    totalLines: { type: 'integer', description: 'exact number of lines in the file' },
  },
}

/**
 * The read operation's parameters as raw JSON Schema, matching what the
 * harness's own defineTool compiles: an object root with declared properties
 * and required names. Unknown properties are rejected here (the mounted tool
 * ignores them), because the object contract promises an error for an unknown
 * parameter instead of silently calling with a typo.
 */
const READ_PARAMETERS = {
  type: 'object',
  additionalProperties: false,
  required: ['file_path'],
  properties: {
    file_path: { type: 'string', description: 'Path to read, resolved by the filesystem backend.' },
    // The supported schema subset has no numeric range keyword, so the
    // positive-integer constraint lives in the description and is enforced by
    // validation before any filesystem effect.
    offset: { type: 'integer', description: '1-based first line to return; a positive integer. Defaults to 1.' },
    limit: { type: 'integer', description: 'Number of lines to return; a positive integer. Omit to read from offset to the end of the file.' },
  },
}

/**
 * Validate read arguments against READ_PARAMETERS before any filesystem
 * effect: unknown properties, wrong JSON types and non-positive/absent values
 * are named with their parameter path.
 * @param args - the candidate arguments.
 * @returns the validated { filePath, offset, limit } request.
 */
function validateReadArguments(args) {
  const violations = []
  if (args === null || typeof args !== 'object' || Array.isArray(args)) {
    throw new Error('invalid arguments: arguments must be an object with a file_path (got ' + (args === null ? 'null' : Array.isArray(args) ? 'array' : typeof args) + ')')
  }
  const known = new Set(['file_path', 'offset', 'limit'])
  for (const key of Object.keys(args)) {
    if (!known.has(key)) violations.push('"' + key + '" is not a declared parameter')
  }
  const filePath = args.file_path
  if (typeof filePath !== 'string') violations.push('"file_path" must be a string')
  else if (filePath.trim().length === 0) violations.push('"file_path" must be a non-empty string')
  const hasOffset = Object.hasOwn(args, 'offset')
  const hasLimit = Object.hasOwn(args, 'limit')
  // An explicitly present field must hold a real value: null is rejected rather
  // than silently treated as "omitted", because a caller that sends null asked
  // for something this tool does not define.
  if (hasOffset && (args.offset === null || args.offset === undefined || typeof args.offset !== 'number' || !Number.isInteger(args.offset) || args.offset < 1)) {
    violations.push('"offset" must be a positive integer')
  }
  if (hasLimit && (args.limit === null || args.limit === undefined || typeof args.limit !== 'number' || !Number.isInteger(args.limit) || args.limit < 1)) {
    violations.push('"limit" must be a positive integer')
  }
  const offset = hasOffset ? args.offset : 1
  const limit = hasLimit ? args.limit : null
  if (violations.length > 0) throw new Error('invalid arguments: ' + violations.join('; '))
  return { filePath: filePath, offset: offset, limit: limit }
}

/** What this preset's read adds to the mounted tool's own description. */
const READ_DESCRIPTION_SUFFIX = ' The result value carries the complete decoded text of the requested scope in "text": the whole file when no offset/limit is given, otherwise exactly the requested range. The printed text is a bounded preview of that same read, and a scope over the configured byte limit fails explicitly instead of returning a prefix.'

/** Display ceilings for the printed preview. These bound the PREVIEW only; the value is complete. */
const PREVIEW_MAX_LINES = 400
const PREVIEW_MAX_LINE_LENGTH = 1200
const PREVIEW_MAX_BYTES = 8 * 1024

/** Exact line count of decoded text: each newline ends a line, and a trailing chunk without one is a line. */
function countLines(text) {
  if (text.length === 0) return 0
  let lines = 0
  let cursor = 0
  for (;;) {
    const index = text.indexOf(String.fromCharCode(10), cursor)
    if (index === -1) break
    lines += 1
    cursor = index + 1
  }
  return cursor < text.length ? lines + 1 : lines
}

/** Decode provider bytes as strict UTF-8 text; binary content is not text. */
function decodeUtf8(bytes) {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes)
  }
  catch {
    throw new Error('the file is not valid UTF-8 text; use read_image for image content')
  }
}

/**
 * Slice the exact text of lines [offset, offset+limit-1] out of already-decoded
 * text, keeping every terminator exactly as the file had it. Shared by every
 * range read that fits the byte ceiling, so a range read decodes exactly like a
 * whole-file read instead of relying on a second decoding path.
 * @param text - the complete decoded file text.
 * @param offset - 1-based first line of the scope.
 * @param limit - number of lines in the scope, or null for "to end of file".
 * @param totalLines - the file's exact line count.
 * @returns the scope text, its last line number, and whether the offset exists.
 */
function sliceScopeText(text, offset, limit, totalLines) {
  const lastWanted = limit === null ? Number.POSITIVE_INFINITY : offset + limit - 1
  let line = 1
  let cursor = 0
  let start = null
  let end = 0
  let endLine = offset - 1
  for (;;) {
    const index = text.indexOf(String.fromCharCode(10), cursor)
    const lineEnd = index === -1 ? text.length : index + 1
    const exists = index !== -1 || cursor < text.length
    if (!exists) break
    if (line === offset) start = cursor
    if (line >= offset && line <= lastWanted) { end = lineEnd; endLine = line }
    if (line >= lastWanted || index === -1) break
    cursor = lineEnd
    line += 1
  }
  if (start === null) return { text: '', endLine: offset - 1, totalLines, missing: totalLines > 0 || offset > 1 }
  return { text: text.slice(start, end), endLine, totalLines, missing: false }
}

/** Split decoded text into display lines, mirroring the provider's line model. */
function splitDisplayLines(text) {
  const out = []
  let start = 0
  for (;;) {
    const index = text.indexOf(String.fromCharCode(10), start)
    if (index === -1) {
      if (start < text.length) out.push(text.slice(start).replace(/\r$/, ''))
      break
    }
    out.push(text.slice(start, index).replace(/\r$/, ''))
    start = index + 1
    if (start === text.length) break
  }
  return out
}

/**
 * The bounded preview of one read value: the lines and footer shared by the
 * printed text and the UI card, computed from the SAME value the caller
 * receives, so display and data can never disagree.
 */
function computeReadPreview(value) {
  const lines = splitDisplayLines(value.text)
  const shown = []
  let bytes = 0
  let capped = false
  for (const line of lines) {
    if (shown.length >= PREVIEW_MAX_LINES) { capped = true; break }
    const text = line.length > PREVIEW_MAX_LINE_LENGTH
      ? line.slice(0, PREVIEW_MAX_LINE_LENGTH) + '... (line truncated to ' + PREVIEW_MAX_LINE_LENGTH + ' chars)'
      : undefined
    const rendered = text === undefined ? line : text
    const size = Buffer.byteLength(rendered, 'utf8') + (shown.length > 0 ? 1 : 0)
    if (bytes + size > PREVIEW_MAX_BYTES) { capped = true; break }
    bytes += size
    shown.push(rendered)
  }
  const first = value.offset
  const last = shown.length === 0 ? value.offset - 1 : first + shown.length - 1
  const total = value.totalLines
  let footer
  if (shown.length === lines.length && last >= total) footer = '(End of file - total ' + total + ' lines)'
  else if (capped) footer = '(Preview: lines ' + first + '-' + last + ' of ' + total + '. .Value.Text holds the complete text of the requested scope.)'
  else footer = '(Lines ' + first + '-' + last + ' of ' + total + ')'
  return { lines: shown.map((text, index) => ({ number: first + index, text })), footer, first, last, capped }
}

/** One read value as the model-facing envelope: a bounded, line-numbered preview. */
function renderReadPreview(value) {
  const preview = computeReadPreview(value)
  const body = preview.lines.length > 0
    ? preview.lines.map(line => line.number + ': ' + line.text).join(String.fromCharCode(10)) + String.fromCharCode(10) + String.fromCharCode(10) + preview.footer
    : preview.footer
  return '<path>' + value.path + '</path>' + String.fromCharCode(10) + '<type>file</type>' + String.fromCharCode(10) + '<content>' + String.fromCharCode(10) + body + String.fromCharCode(10) + '</content>'
}


/** The definition detail the shell needs to build one reusable tool object. */
function describeTool(ctx, agent, toolName, config) {
  const definition = ctx.tools.get(toolName, agent)
  if (definition === undefined) return undefined
  const baseDescription = String(definition.description ?? '')
  return {
    name: toolName,
    summary: summarize(baseDescription),
    description: baseDescription,
    inputSchema: definition.parameters ?? null,
    outputSchema: (definition.output && definition.output.schema) ?? null,
    returnContract: returnContractFor(toolName, definition, config),
    examples: EXAMPLES[toolName] ?? [],
    definitionVersion: definitionVersionOf(toolName, definition),
    metadataOnly: true,
  }
}

/**
 * Collect the exact decoded text of one line scope while streaming, keeping
 * only the requested lines and stopping as soon as they are complete, so a
 * range request never buffers the whole file.
 * @param chunks - provider text chunks in file order.
 * @param offset - 1-based first line of the scope.
 * @param limit - number of lines in the scope, or null for "to end of file".
 * @param maxBytes - inclusive byte ceiling for the collected text.
 * @returns the scope text and its last line number.
 */
export async function collectScopeText(chunks, offset, limit, maxBytes) {
  const newline = String.fromCharCode(10)
  const lastWanted = limit === null ? Number.POSITIVE_INFINITY : offset + limit - 1
  // Only an in-scope line keeps its text, but every line is counted: the scan
  // always reaches end of file so totalLines is the exact file total rather
  // than the scope's own line count.
  let pending = ''
  let line = 1
  let lineHasContent = false
  let text = ''
  let bytes = 0
  let endLine = offset - 1
  let overflow = false
  const inScope = () => line >= offset && line <= lastWanted
  for await (const chunk of chunks) {
    const buffer = pending + chunk
    pending = ''
    let cursor = 0
    for (;;) {
      const index = buffer.indexOf(newline, cursor)
      if (index === -1) {
        const rest = buffer.slice(cursor)
        if (rest.length > 0) {
          lineHasContent = true
          if (inScope() && !overflow) {
            // Check the ceiling BEFORE holding the partial line: one
            // newline-free giant line must fail at the limit, not after
            // buffering all of it.
            if (bytes + Buffer.byteLength(rest, 'utf8') > maxBytes) overflow = true
            else pending = rest
          }
        }
        break
      }
      if (index > cursor) lineHasContent = true
      if (inScope() && !overflow) {
        const segment = buffer.slice(cursor, index + 1)
        bytes += Buffer.byteLength(segment, 'utf8')
        if (bytes > maxBytes) overflow = true
        else { text += segment; endLine = line }
      }
      line += 1
      lineHasContent = false
      cursor = index + 1
    }
  }
  if (pending.length > 0 && !overflow && inScope()) {
    bytes += Buffer.byteLength(pending, 'utf8')
    if (bytes > maxBytes) overflow = true
    else { text += pending; endLine = line }
  }
  return { text, endLine, totalLines: lineHasContent ? line : line - 1, overflow }
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
  const requestedLimit = config && config.readFullMaxBytes
  const readFullMaxBytes = Number.isInteger(requestedLimit) && requestedLimit > 0 ? requestedLimit : DEFAULT_READ_FULL_MAX_BYTES
  const runtimeConfig = { readFullMaxBytes }
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
  /** Per-execution metadata-operation counter: discovery is counted separately from tool calls. */
  const metadataOps = new WeakMap()
  /** Per-agent disposers for this preset's registered read operation. */
  const readTools = new Map()

  /**
   * Register this preset's read for one agent, in that agent's own registry
   * layer so it shadows the mounted tool for this session only. The operation
   * resolves through ctx.fs, validates its arguments before any filesystem
   * effect, enforces the byte ceiling through the provider's own limit where
   * one exists, honours cancellation, emits the same presence/absence
   * observations the mounted tool emits, and returns the complete requested
   * scope - one provider read, one snapshot, preview included.
   *
   * Only a read the session can actually see is replaced: a name that is not
   * mounted, or is restricted away, stays unavailable. A registration failure
   * is raised rather than downgraded, because the alternative is advertising a
   * complete-text contract while serving the windowed one.
   * @param agent - the session's agent whose layer owns the replacement.
   */
  function ensureReadTool(agent) {
    if (readTools.has(agent)) return
    if (ctx.tools.get(READ_TOOL, agent) === undefined) return
    let dispose
    try {
      dispose = agent.ctx.tools.register({
        name: READ_TOOL,
        description: 'Read a UTF-8 text file and return its text with line numbers.' + READ_DESCRIPTION_SUFFIX,
        parameters: READ_PARAMETERS,
        output: {
          schema: READ_VALUE_SCHEMA,
          render: (_args, value) => [{ type: 'text', text: renderReadPreview(value) }],
          presentationMeta: (_args, value) => {
            const preview = computeReadPreview(value)
            return { path: value.path, offset: value.offset, lines: preview.lines, totalLines: value.totalLines }
          },
        },
        isConcurrencySafe: () => true,
        async execute(args, exec) {
          const request = validateReadArguments(args)
          const cwd = exec.agent && exec.agent.session && exec.agent.session.header ? exec.agent.session.header.cwd : undefined
          const target = await ctx.fs.resolve(request.filePath, { ...cwd === undefined ? {} : { cwd }, signal: exec.signal })
          const info = await ctx.fs.stat(target, exec.signal)
          if (info === undefined) {
            ctx.emit('fs/observed', target, { kind: 'absent' }, exec)
            // The provider owns the structured FS_NOT_FOUND; asking it keeps the
            // registry's own classification rather than a code invented here.
            await ctx.fs.readText(target, exec.signal)
            throw new Error('cannot read "' + target.displayPath + '": not found')
          }
          if (info.type !== 'file') throw new Error('cannot read "' + target.displayPath + '": not a regular file')
          let text
          let endLine
          let totalLines
          // The whole-file fast path applies only to the default request. An
          // offset without a limit is a scope from that line to end of file.
          const wholeFile = request.limit === null && request.offset === 1
          const sizeKnown = typeof info.size === 'number'
          let missingOffset = false
          if (wholeFile || (sizeKnown && info.size <= readFullMaxBytes)) {
            // One provider read whose own byte cap reports FS_TOO_LARGE, decoded
            // strictly, so a range read cannot silently replace undecodable bytes
            // that the whole-file read would have refused.
            const bytes = await ctx.fs.readBytes(target, exec.signal, readFullMaxBytes)
            const full = decodeUtf8(bytes)
            totalLines = countLines(full)
            if (wholeFile) {
              text = full
              endLine = totalLines
            }
            else {
              const sliced = sliceScopeText(full, request.offset, request.limit, totalLines)
              text = sliced.text
              endLine = sliced.endLine
              missingOffset = sliced.missing
            }
          }
          else {
            // Only a file already known to exceed the ceiling is streamed: the
            // provider decodes and rejects binary content across chunks, and the
            // range is bounded by its own text.
            const chunks = await ctx.fs.streamText(target, exec.signal)
            const collected = await collectScopeText(chunks, request.offset, request.limit, readFullMaxBytes)
            if (collected.overflow) {
              throw new Error('the requested scope of "' + target.displayPath + '" is over the full-text read limit of ' + readFullMaxBytes + ' bytes; request a smaller line range')
            }
            text = collected.text
            endLine = collected.endLine
            totalLines = collected.totalLines
            missingOffset = collected.endLine < request.offset
          }
          const emptyWholeFile = totalLines === 0 && wholeFile
          if ((missingOffset || endLine < request.offset) && !emptyWholeFile) {
            throw new Error('offset ' + request.offset + ' is out of range for "' + target.displayPath + '" (' + totalLines + ' lines)')
          }
          ctx.emit('fs/observed', target, { kind: 'present', version: info.version }, exec)
          const scopeLines = splitDisplayLines(text).map((line, index) => ({ number: request.offset + index, text: line }))
          return {
            path: target.displayPath,
            text,
            lines: scopeLines,
            offset: request.offset,
            limit: scopeLines.length,
            endLine,
            totalLines,
          }
        },
      })
    }
    catch (error) {
      readTools.delete(agent)
      throw new Error('dsh-all-in-pwsh: the complete-text read operation could not be registered for this session, so the read contract cannot be honoured: ' + String((error && error.message) || error))
    }
    readTools.set(agent, dispose)
  }
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
              .end(JSON.stringify(refusalReply('BAD_TOKEN', 'bad bridge token')))
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

  /** The per-call metadata every reply carries. */
  function metadataFor(record, exec, toolName, started, definitionVersion, outcome) {
    return {
      tool: toolName,
      callId: record.subCallId ?? null,
      rootCallId: exec.rootCallId ?? null,
      parentCallId: exec.callId ?? null,
      session: String((exec.agent && exec.agent.session && exec.agent.session.id) ?? ''),
      instance,
      durationMs: Math.max(0, Math.round(Date.now() - started)),
      definitionVersion,
      outcome,
      // Discovery and description reads are counted and reported separately from
      // tool executions: they never enter the tool-call count or the request log.
      metadataOps: metadataOps.get(exec) ?? 0,
    }
  }

  /** One refused call, with the reason and without executing anything. */
  function refusal(record, exec, toolName, started, definitionVersion, kind, code, message) {
    return {
      ok: false,
      hasValue: false,
      valueJson: null,
      displayText: '',
      content: [],
      error: { kind, code, message, tool: toolName, parameterPath: null },
      metadata: metadataFor(record, exec, toolName, started, definitionVersion, 'not-executed'),
    }
  }


  /**
   * Answer one bridged request. Every operation, discovery included, must carry
   * the complete identity of an execution that is still active.
   */
  async function handle(payload) {
    if (payload === null || typeof payload !== 'object') return refusalReply('MALFORMED_REQUEST', 'malformed bridge request')
    if (payload.instance !== instance) {
      return refusalReply('INSTANCE_MISMATCH', 'this bridge belongs to dsh-all-in-pwsh instance ' + JSON.stringify(instance) + ', not ' + JSON.stringify(payload.instance) + '; use the entry point this shell was given')
    }
    const session = typeof payload.session === 'string' ? payload.session : ''
    const call = typeof payload.call === 'string' ? payload.call : ''
    const capability = typeof payload.capability === 'string' ? payload.capability : ''
    if (session.length === 0 || call.length === 0 || capability.length === 0) {
      return refusalReply('NO_EXECUTION_IDENTITY', 'this request carries no complete execution identity: instance, session, call and capability are all required, and the shell supplies them for the command it is running')
    }
    const record = active.get(call)
    if (record === undefined || !record.keys.includes(session)) {
      return refusalReply('NO_CALL_IN_FLIGHT', 'no ' + transport + ' call named ' + JSON.stringify(call) + ' is in flight for session ' + JSON.stringify(session) + ': a bridged call only works inside the shell command that started it')
    }
    if (record.capability !== capability) {
      return refusalReply('IDENTITY_REVOKED', 'the capability does not match the call in flight; this caller inherited an execution identity that has already been revoked, most likely a background process started by an earlier command')
    }
    const exec = record.exec
    if (record.closed || exec.signal.aborted) {
      return refusalReply('EXECUTION_ENDED', 'this execution is no longer active: the shell command that owned call ' + JSON.stringify(call) + ' has finished or was cancelled')
    }
    const schemas = ctx.tools.schemas(exec.agent)
    if (payload.op === 'list' || payload.op === 'get' || payload.op === 'describe') {
      metadataOps.set(exec, (metadataOps.get(exec) ?? 0) + 1)
    }
    if (payload.op === 'list') {
      const listed = schemas
        .filter(schema => schema.name !== transport)
        .map(schema => ({ name: schema.name, summary: summarize(schema.description) }))
      recordMetadata(exec.agent, record, 'list', listed.map(entry => entry.name), true)
      return { tools: listed }
    }
    if (payload.op === 'get' || payload.op === 'describe') {
      const requested = Array.isArray(payload.names) ? payload.names : (typeof payload.name === 'string' ? [payload.name] : [])
      if (requested.length === 0) return refusalReply('NAME_REQUIRED', 'a tool name is required')
      const tools = []
      for (const requestedName of requested) {
        const detail = describeTool(ctx, exec.agent, requestedName, runtimeConfig)
        if (detail === undefined) {
          recordMetadata(exec.agent, record, payload.op, requested, false, 'unknown tool ' + JSON.stringify(requestedName))
          return refusalReply('UNKNOWN_TOOL', 'unknown tool ' + JSON.stringify(requestedName) + ': it is not registered or not mounted in this session; Get-DshTool lists what this session can call')
        }
        tools.push(detail)
      }
      recordMetadata(exec.agent, record, payload.op, requested, true)
      return { tools }
    }
    const toolName = payload.name
    if (typeof toolName !== 'string' || toolName.length === 0) return refusalReply('NAME_REQUIRED', 'a tool name is required')
    if (toolName === transport) return refusalReply('TRANSPORT_NOT_BRIDGEABLE', 'the ' + transport + ' tool cannot be called through the bridge; run the command directly')
    const definition = ctx.tools.get(toolName, exec.agent)
    if (definition === undefined) return refusalReply('UNKNOWN_TOOL', 'unknown tool ' + JSON.stringify(toolName) + ': it is not registered or not mounted in this session')
    const agent = exec.agent
    if (agent === undefined) return refusalReply('NO_AGENT', 'the shell call has no owning agent session')

    const started = Date.now()
    const currentVersion = definitionVersionOf(toolName, definition)
    if (typeof payload.definitionVersion === 'string' && payload.definitionVersion !== currentVersion) {
      return refusal(record, exec, toolName, started, currentVersion, 'DefinitionChanged', 'TOOL_DEFINITION_CHANGED',
        'the definition of "' + toolName + '" changed after this tool object was created (handle ' + payload.definitionVersion + ', current ' + currentVersion + '); run $tool = $tool.Refresh() before calling it')
    }

    // Accepted work is tied to the execution that accepted it: the wrapper
    // cancels and settles everything in flight before the identity is released,
    // so nothing can append to the log or to the media map afterwards.
    const operation = dispatchNested(record, agent, toolName, payload.arguments, started, currentVersion, runtimeConfig)
    record.running.add(operation)
    try {
      return await operation
    } finally {
      record.running.delete(operation)
    }
  }

  /** Run one bridged tool call, complete the read contract, and record its durable dispatch pair. */
  async function dispatchNested(record, agent, toolName, argumentValue, started, definitionVersion, runConfig) {
    const exec = record.exec
    const ordinal = (counters.get(exec) || 0) + 1
    counters.set(exec, ordinal)
    const subCallId = exec.callId + ':cli:' + String(ordinal)
    record.subCallId = subCallId
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
    let outcome = 'settled'
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
      // The dispatch never produced a settled result: the tool may still have
      // run, so the outcome is unknown and is never retried automatically.
      outcome = 'unknown'
      result = { isError: true, content: [{ type: 'text', text: 'Error: ' + String((error && error.message) || error) }] }
    }

    // Cancellation is host control flow, not a tool outcome. The registry may
    // return an error result instead of throwing once its signal aborts, so the
    // signal itself decides - never the text of an error.
    // A settled SUCCESS is kept: the tool completed before the abort. Only an
    // error result under an aborted signal is cancellation rather than a tool
    // failure, which is why the signal decides instead of the error text.
    if (signal.aborted && result.isError === true) {
      if (result.content === undefined || result.content.length === 0) {
        result = { isError: true, content: [{ type: 'text', text: 'Error: the call was cancelled with the shell command that owned it' }] }
      }
      collectMedia(exec, result)
      appendDispatch(agent, start, true, result.content)
      return refusalReply('EXECUTION_ENDED', 'the shell command that owned this execution was cancelled while "' + toolName + '" was in flight, and any nested work was cancelled and settled with it; whether the tool took effect is unknown')
    }

    let reply
    if (result.isError === true) {
      const info = result.error && result.error.info
      const message = (result.error && typeof result.error.message === 'string' ? result.error.message : undefined) ?? textOf(result)
      reply = {
        ok: false,
        hasValue: false,
        valueJson: null,
        displayText: textOf(result),
        content: contentBlocksOf(result),
        error: {
          kind: outcome === 'unknown' ? 'Transport' : 'Tool',
          code: info !== undefined && info.code !== undefined ? String(info.code) : null,
          message,
          tool: toolName,
          parameterPath: null,
        },
        metadata: metadataFor(record, exec, toolName, started, definitionVersion, outcome),
      }
    } else {
      // The tool's own value is the result value. For this preset's read that is
      // the complete requested scope, produced by the registered operation
      // before its preview was formatted - never rebuilt from display text.
      const value = result.value === undefined ? null : result.value
      reply = {
        ok: true,
        hasValue: result.value !== undefined,
        valueJson: JSON.stringify(value ?? null),
        displayText: textOf(result),
        content: contentBlocksOf(result),
        error: null,
        metadata: metadataFor(record, exec, toolName, started, definitionVersion, outcome),
      }
    }

    collectMedia(exec, result)
    appendDispatch(agent, start, reply.ok !== true, result.content)
    return reply
  }

  /**
   * Accumulate the non-text blocks of one nested result for this execution.
   * additionalContexts is the only channel that survives normalization, so the
   * payload is attached there when the shell command settles.
   */
  function collectMedia(exec, result) {
    const extra = (result.content ?? []).filter(block => block.type !== 'text')
    if (extra.length === 0) return
    const collected = media.get(exec.callId)
    if (collected === undefined) media.set(exec.callId, extra.slice())
    else collected.push(...extra)
  }

  /**
   * Record one discovery or description operation as its own trace event. It is
   * metadata access, not tool work: no capability, no arguments, no tool-call
   * count, and it never becomes a model request.
   */
  function recordMetadata(agent, record, op, names, ok, detail) {
    try {
      const session = agent.session
      session.append('dsh-all-in-pwsh/metadata', {
        op,
        names: names.slice(),
        parentCallId: record.callId,
        session: String(session.id ?? ''),
        ok,
        ...(detail === undefined ? {} : { detail }),
      })
    } catch {
      // A build that does not know this event type must not break discovery.
    }
  }

  /** Record one durable nested dispatch pair with the outcome the shell actually received. */
  function appendDispatch(agent, start, isError, content) {
    agent.session.append('tool/ptc-dispatch', Object.assign({}, start, { isError, content }))
  }

  // Install the read contract as early as the session exists, so the catalog
  // this session advertises carries the accurate description and schema. The
  // transport-time call covers a session whose preset mounts later.
  ctx.on('agent/created', event => {
    try { ensureReadTool(event.agent) }
    catch (error) { ctx.logger?.warn?.('dsh-all-in-pwsh: ' + String((error && error.message) || error)) }
  })

  ctx.effect(() => () => {
    for (const dispose of readTools.values()) {
      if (typeof dispose === 'function') dispose()
    }
    readTools.clear()
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
    text: TICK + transport + TICK + ' is the only tool you can call directly - a tool call naming any other tool fails. That code calls the other tools through the tool objects the reference below documents.',
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
    return TICK + transport + TICK + ' is the only tool you can call directly; call ' + TICK + exec.name + TICK + ' through its tool object inside that shell instead'
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
      ensureReadTool(agent)
      exec.signal.throwIfAborted()
      record = {
        callId: exec.callId,
        subCallId: null,
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

/**
 * The catalog-derived reference: the counterpart of PTC mode's generated SDK
 * block, at the same prompt slot and regenerated from the calling scope's live
 * catalog on every assembly.
 */
function renderReference(schemas, transport) {
  const others = schemas.filter(schema => schema.name !== transport)
  const lines = [
    "## Tools in this persistent PowerShell session",
    "",
    "Variables, functions, objects, the working directory and environment survive later code blocks and user turns in this session. Keep parsed data and tool handles in variables; use them directly in later blocks. A normal follow-up does not require a state file or another read of the same input.",
    "",
    "Discover names with Get-DshTool. Fetch selected tools and print their details when needed:",
    "",
    "    $read, $write = Get-DshTool -Name read, write",
    "    $read",
    "    $write",
    "",
    "A tool object contains its InputSchema and ReturnContract. Reading these properties and printing the object are local: they execute no work. Call .Invoke with a PowerShell hashtable. It returns one result object; assigning it preserves the object, while printing it shows a bounded preview.",
    "",
    "For text reads, .Value.Text contains the complete text of the requested scope: the whole file by default, or the requested offset/limit range. A request beyond the declared resource limit fails. A shortened preview does not mean shortened data. .DisplayText is presentation, never a data source to parse. Other tools retain their declared .Value shape; .HasValue distinguishes absent data from a present null.",
    "",
    "Keep known dependencies together: read, parse, compute, write and read-back verification can all run in one block. Once paths and the required transformation are known, pass computed variables into subsequent calls without returning to the model between each stage. Printing an intermediate value is not a reason to end the block. Return when inspecting the evidence will change the next action; otherwise finish the known work and emit concise evidence. Use retained data for verification instead of fetching the same input again.",
    "",
    "For example, after obtaining $read and $write, this whole block computes, writes and verifies a count:",
    "",
    "    $rows = $read.Invoke(@{ file_path = 'items.json' }).Value.Text | ConvertFrom-Json",
    "    $count = @($rows | Where-Object enabled).Count",
    "    $write.Invoke(@{ file_path = 'count.txt'; content = [string]$count }) | Out-Null",
    "    $actual = $read.Invoke(@{ file_path = 'count.txt' }).Value.Text",
    "    if ($actual -cne [string]$count) { throw 'count.txt verification failed' }",
    "    \"Verified count.txt: $count\"",
    "",
    "Apply the same data flow to the actual task. Do not copy source records or computed numbers from a displayed preview into new literals. Inspect a small sample in memory only when the data structure is unknown; do not print the whole input for a calculation that code can perform.",
    "",
    ".Invoke failures stop dependent statements under the session's default Stop policy and print one '[dsh] FAILED ...' line naming the tool, kind, code, parameter path and message before the block stops: read that line for the reason instead of inferring it from the exit code. For an expected failure, use .TryInvoke and branch on .Ok; inspect .Error for details. An argument name the tool's InputSchema does not declare is ignored by the harness, and the block prints one '[dsh] WARNING ...' line naming the ignored and the declared names, so pass only declared names and treat that line as a correction. Cancellation and expired execution identity still stop execution. Do not retry a write whose execution outcome is unknown.",
    "",
    "Use read/write/edit/glob/grep for task files, PowerShell for control flow and computation, and native processes for builds/tests. Directory searches also use glob, not Get-ChildItem. Supply argument objects directly; do not serialize tool arguments into JSON strings or argument files. Serializing task data, such as a computed summary into JSON file content, is ordinary in-memory work. Every nested call must finish inside its current code block.",
    "",
    "### Available tools",
    "",
  ]
  for (const schema of others) {
    lines.push("- " + TICK + schema.name + TICK + " - " + summarize(schema.description))
  }
  return lines.join(String.fromCharCode(10))
}
