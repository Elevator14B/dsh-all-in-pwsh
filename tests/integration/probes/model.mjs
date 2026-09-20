/**
 * Model-backed acceptance for dsh-all-in-pwsh. Requires a real DSH runtime AND
 * a usable model route, so the runner only selects it with --with-model and only
 * then copies the caller's settings/credentials into the throwaway home.
 *
 * Covers the acceptance list end to end: object read/write/edit with a CJK and
 * spaced path plus quotes, apostrophes, dollars, backticks, ampersands,
 * backslashes and a multiline here-string; shell state across commands; a real
 * read_image whose pixels must reach the model; and a wire catalog that never
 * contains anything but the shell tool.
 */
import { writeFileSync, readFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs'
import { deflateSync } from 'node:zlib'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { pathToFileURL } from 'node:url'

export const name = 'dsh-all-in-pwsh-model'
export const inject = ['agents', 'agentPresets', 'sessions', 'agentDefaultModel']

const NL = String.fromCharCode(10)
const TICK = String.fromCharCode(96)
const PRESET = process.env.PROBE_PRESET || 'dsh-all-in-pwsh'

const CRC_TABLE = (() => {
  const table = new Int32Array(256)
  for (let n = 0; n < 256; n += 1) {
    let c = n
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c
  }
  return table
})()

function crc32(buffer) {
  let c = 0xffffffff
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

function chunk(type, data) {
  const length = Buffer.alloc(4)
  length.writeUInt32BE(data.length)
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data])
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(body))
  return Buffer.concat([length, body, crc])
}

/** Write a solid-colour PNG so the image round trip has one correct answer. */
function writePng(file, size, red, green, blue) {
  const header = Buffer.alloc(13)
  header.writeUInt32BE(size, 0)
  header.writeUInt32BE(size, 4)
  header[8] = 8
  header[9] = 2
  const raw = Buffer.alloc(size * (1 + size * 3))
  for (let y = 0; y < size; y += 1) {
    const row = y * (1 + size * 3)
    raw[row] = 0
    for (let x = 0; x < size; x += 1) {
      raw[row + 1 + x * 3] = red
      raw[row + 2 + x * 3] = green
      raw[row + 3 + x * 3] = blue
    }
  }
  writeFileSync(file, Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header),
    chunk('IDAT', deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]))
}

export function apply(ctx) {
  const report = { checks: [], results: {} }
  const out = process.env.PROBE_OUT
  const save = () => writeFileSync(out, JSON.stringify(report, null, 2))
  const record = (name, ok, detail) => {
    report.checks.push({ name, ok, detail: detail === undefined ? undefined : JSON.parse(JSON.stringify(detail)) })
    save()
  }
  const sameText = (left, right) => left.replace(/\r\n/g, NL).replace(/\n+$/, '') === right.replace(/\r\n/g, NL).replace(/\n+$/, '')

  async function run() {
    await ctx.get('loader')?.await()
    const { createUserMessage } = await import(pathToFileURL(path.join(process.env.PROBE_RUNTIME, 'node_modules/@deepseek-ai/dsh-llm/lib/index.js')).href)
    const { installModelSelection } = await import(pathToFileURL(path.join(process.env.PROBE_RUNTIME, 'node_modules/@deepseek-ai/dsh-agent/lib/index.js')).href)
    const selection = ctx.agentDefaultModel.currentSelection()
    const cwd = process.cwd()
    const dir = path.join(cwd, 'work A 中文')
    mkdirSync(dir, { recursive: true })
    const note = path.join(dir, '说明 note.txt')
    const swatch = path.join(dir, 'swatch.png')
    writePng(swatch, 48, 220, 20, 30)

    const line1 = '中文 "保留引号" O' + String.fromCharCode(39) + 'Brien & Sons'
    const line2 = 'C:' + String.fromCharCode(92) + 'folder' + String.fromCharCode(92) + 'file.txt $var ' + TICK + 'tick & (paren) [bracket]'
    const line3 = 'line3'
    const expectedFirst = [line1, line2, line3].join(NL)
    const appended = '追加行 & "quoted"'
    const expectedSecond = [line1, line2, line3, appended].join(NL)

    const { agent } = await ctx.agents.create({
      sessionId: 'session-' + randomUUID(),
      meta: { cwd, agentPreset: PRESET },
      agentOptions: { provider: selection.provider, model: selection.model },
      setup: async c => { await ctx.agentPresets.mount(c, PRESET); installModelSelection(c, { current: selection, assembled: undefined }) },
    })
    await agent.whenIdle()

    const turn = async text => {
      agent.followup(createUserMessage({ source: { kind: 'user' }, content: [{ type: 'text', text }] }))
      await agent.whenIdle()
      await ctx.sessions.flush(agent.session)
    }

    await turn([
      '授权测试。不要委派、不要浏览、不要访问当前工作目录以外的文件，不要改任何设置。',
      '只使用 shell 里的工具对象接口：Get-DshTool 取得工具对象，然后用 $tool.Invoke(@{ ... }) 调用，参数一律用 PowerShell 对象，不要手写 JSON、不要用 --%、不要创建临时 JSON 文件。',
      '请完成三件事：',
      '1) 建立目录 work A 中文。',
      '2) 用 write 写入 work A 中文' + String.fromCharCode(47) + '说明 note.txt，内容必须严格等于下面三行，一个字都不要改（注意双引号、撇号、反斜线、美元符号、反引号和 &）：',
      line1,
      line2,
      line3,
      '3) 用 read 读回该文件原样报告，并执行 $global:KeepMe = "KEEP_ACCEPT" 打印它。完成后停止。',
    ].join(NL))
    const afterFirst = existsSync(note) ? readFileSync(note, 'utf8') : ''
    report.results.afterFirst = afterFirst
    record('model.wrote_exact_hostile_text', sameText(afterFirst, expectedFirst), { expected: expectedFirst, actual: afterFirst })

    await turn([
      '授权测试，限制同上。只使用工具对象接口（Get-DshTool 取得对象，$tool.Invoke(@{ ... }) 调用）和 PowerShell 参数对象。',
      '1) 用 edit 把 work A 中文' + String.fromCharCode(47) + '说明 note.txt 里的第三行 line3 替换成 line3 换行后再加一行：' + appended,
      '2) 打印上一个命令里设置的变量 $global:KeepMe，证明 shell 状态跨命令保持。',
      '完成后停止。',
    ].join(NL))
    const afterSecond = existsSync(note) ? readFileSync(note, 'utf8') : ''
    report.results.afterSecond = afterSecond
    record('model.edited_without_corrupting', sameText(afterSecond, expectedSecond), { expected: expectedSecond, actual: afterSecond })

    await turn([
      '授权测试，限制同上。',
      '用 shell 里的工具对象接口调用 read_image（$img = Get-DshTool -Name read_image; $img.Invoke(@{ ... })），读取 work A 中文' + String.fromCharCode(47) + 'swatch.png。',
      '然后用一行简短回答：这张图的主要颜色是什么？请明确说出颜色词。完成后停止。',
    ].join(NL))

    const events = []
    for (let n = 0; n < agent.session.seq; n += 1) {
      const e = agent.session.eventAt(n)
      if (e) events.push(e)
    }
    const requests = events.filter(e => e.type === 'request/header').map(e => (e.data.header.tools || []).map(t => t.name))
    report.results.requests = requests
    record('wire.only_shell_tool', requests.length > 0 && requests.every(names => names.length === 1 && names[0] === 'pwsh'), requests)

    const commands = events.filter(e => e.type === 'tool/call').map(e => { try { return JSON.parse(e.data.arguments).command } catch { return undefined } }).filter(c => typeof c === 'string')
    // The object interface is the taught path: obtain a handle, then call it with
    // a PowerShell argument object. The compatibility entry points stay accepted.
    const objectCalls = commands.filter(c => c.includes('.Invoke(@{') || c.includes('.TryInvoke(@{'))
    const bridged = commands.filter(c => c.includes('Invoke-DshTool') || c.includes('dsh-tool') || objectCalls.includes(c))
    report.results.commands = commands
    record('model.used_object_interface', objectCalls.length > 0 && objectCalls.every(c => c.includes('@{')), { total: commands.length, objectCalls: objectCalls.length, bridged: bridged.length, sample: objectCalls.slice(0, 3) })
    record('model.no_json_workarounds', !commands.some(c => c.includes('ConvertTo-Json') || c.includes('--%')), commands.filter(c => c.includes('ConvertTo-Json') || c.includes('--%')).slice(0, 2))
    record('model.no_temp_json_files', readdirSync(dir).filter(name => name.endsWith('.json')).length === 0, readdirSync(dir))

    const contexts = events.filter(e => e.type === 'user/message').flatMap(e => e.data.content || [])
    const images = contexts.filter(b => b.type === 'image')
    report.results.imageBlocks = images.length
    record('multimodal.image_reached_model', images.length > 0, images.map(b => String((b.attachment && b.attachment.mediaType) || b.mimeType || 'image')))
    const assistantText = events.filter(e => e.type === 'assistant/message').map(e => (e.data.message.content || []).filter(b => b.type === 'text').map(b => b.text).join(' ')).join(' ')
    report.results.assistantText = assistantText.slice(-1200)
    record('model.identified_image', /\bred\b|红色/i.test(assistantText), report.results.assistantText.slice(-300))
    record('model.reported_persistence', assistantText.includes('KEEP_ACCEPT'), report.results.assistantText.slice(-300))
    record('dispatch.attributed', events.filter(e => e.type === 'tool/ptc-dispatch').length > 0 && events.filter(e => e.type === 'tool/ptc-dispatch').every(e => e.data.parentCallId !== undefined), events.filter(e => e.type === 'tool/ptc-dispatch').length)

    report.completed = true
    save()
    ctx.get('appExit')?.(report.checks.every(c => c.ok) ? 0 : 2)
  }

  run().catch(error => { report.error = error && error.stack ? error.stack : String(error); save(); ctx.get('appExit')?.(1) })
}
