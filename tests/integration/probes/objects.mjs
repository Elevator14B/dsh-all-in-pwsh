/**
 * Integration probe for the tool-object and result-object contract. Requires a
 * real DSH runtime and runs no model: the probe mounts the preset into a real
 * agent, drives the persistent shell through the registered pwsh tool, and
 * asserts what the shell sees. The preset id under test comes from PROBE_PRESET.
 */
const PRESET = process.env.PROBE_PRESET || 'dsh-all-in-pwsh'
import { writeFileSync, readFileSync, existsSync, statSync, rmSync } from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'

export const name = 'review-objects'
export const inject = ['agents', 'agentPresets', 'sessions', 'tools']

export function apply(ctx) {
  const out = process.env.PROBE_OUT
  const dir = process.cwd()
  const report = { checks: [], results: {} }
  const save = () => writeFileSync(out, JSON.stringify(report, null, 2))
  const record = (name, ok, detail) => {
    report.checks.push({ name, ok, detail: detail === undefined ? undefined : JSON.parse(JSON.stringify(detail)) })
    save()
  }

  const NL = String.fromCharCode(10)

  async function run() {
    await ctx.get('loader')?.await()
    const { agent } = await ctx.agents.create({
      sessionId: 'session-' + randomUUID(),
      meta: { cwd: dir, agentPreset: PRESET },
      setup: async c => { await ctx.agentPresets.mount(c, PRESET) },
    })
    await agent.whenIdle()

    // --- fixtures ------------------------------------------------------------
    const small = 'alpha' + NL + 'beta' + NL
    const manyLines = Array.from({ length: 5000 }, (_, index) => 'line ' + String(index + 1)).join(NL) + NL
    const longLine = 'x'.repeat(5000)
    const big = Array.from({ length: 4000 }, (_, index) => 'row ' + String(index + 1) + ' ' + 'y'.repeat(40)).join(NL) + NL
    const unicode = 'café' + NL + '中文' + NL.replace(NL, '\r\n') + 'last'
    const rangeLines = Array.from({ length: 10 }, (_, index) => 'L' + String(index + 1))
    const hugeSize = 9 * 1024 * 1024
    writeFileSync(path.join(dir, 'small.txt'), small)
    writeFileSync(path.join(dir, 'many-lines.txt'), manyLines)
    writeFileSync(path.join(dir, 'long-line.txt'), longLine + NL)
    writeFileSync(path.join(dir, 'big.txt'), big)
    writeFileSync(path.join(dir, 'empty.txt'), '')
    writeFileSync(path.join(dir, 'unicode.txt'), unicode)
    writeFileSync(path.join(dir, 'range.txt'), rangeLines.join(NL) + NL)
    // Multi-line on purpose: an explicit range well inside the file must
    // succeed without reading (or buffering) the whole 9 MiB scope.
    writeFileSync(path.join(dir, 'huge.txt'), (('z'.repeat(99) + NL).repeat(Math.ceil(hugeSize / 100))))
    writeFileSync(path.join(dir, 'notes.txt'), 'owner: ana' + NL + 'STATUS: draft' + NL + 'next: review' + NL)

    // A tool the probe can redefine, to prove the definition-version check.
    let driftVersion = 1
    let disposeDrift = registerDrift()
    function registerDrift() {
      return ctx.tools.register({
        name: 'probe_drift',
        description: 'Probe-only tool, definition ' + String(driftVersion) + '.',
        parameters: { note: { type: 'string', required: true, description: 'note to echo' } },
        output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: String(value) }] },
        async execute(args) { return 'DRIFT-' + String(driftVersion) + ':' + String(args.note) },
      })
    }

    let counter = 0
    const exec = command => agent.ctx.tools.execute({
      callId: 'objects-' + String(++counter),
      rootCallId: 'objects-' + String(counter),
      name: 'pwsh',
      arguments: { command },
      agent,
      signal: new AbortController().signal,
    })
    const textOf = value => ((value && value.content) || []).filter(block => block.type === 'text').map(block => block.text).join('')
    const events = () => {
      const list = []
      for (let index = 0; index < agent.session.seq; index += 1) {
        const event = agent.session.eventAt(index)
        if (event) list.push(event)
      }
      return list
    }
    const dispatchesSince = from => events().slice(from).filter(event => String(event.type).startsWith('tool/ptc-dispatch'))

    // --- catalog and handle --------------------------------------------------
    const shellVersion = textOf(await exec("'PSVERSION=' + $PSVersionTable.PSVersion.ToString(); '@@CHECK@@'"))
    report.results.shellVersion = shellVersion.trim()
    const catalogText = textOf(await exec('Get-DshTool | Out-String -Width 120'))
    report.results.catalog = catalogText.slice(0, 600)
    record('catalog.lists_names_and_summaries', catalogText.includes('read') && catalogText.includes('write'), report.results.catalog)
    record('catalog.omits_schema_details', !catalogText.includes('file_path'), report.results.catalog)

    const handleText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$read | Out-String -Width 120'))
    report.results.handle = handleText.slice(0, 900)
    record('handle.prints_parameters_contract_and_usage',
      handleText.includes('parameters:') && handleText.includes('file_path') && handleText.includes('returns:') && handleText.includes('usage:'),
      report.results.handle)

    const beforeMetadata = agent.session.seq
    const metadataText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$null = $read.ParameterSummary' + NL + '$null = $read.ReturnSummary' + NL + '$null = $read.InputSchema' + NL + "'METADATA-DONE'"))
    const metadataDispatches = dispatchesSince(beforeMetadata)
    report.results.metadata = { text: metadataText, dispatches: metadataDispatches.length }
    record('metadata.makes_no_tool_call', metadataText.includes('METADATA-DONE') && metadataDispatches.length === 0, report.results.metadata)

    // --- result object and full text ----------------------------------------
    const smallText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$r = $read.Invoke(@{ file_path = \'small.txt\' })' + NL + "'TEXT=[' + $r.Value['text'] + ']'" + NL + "'LINES=' + $r.Value['totalLines'] + ' OFFSET=' + $r.Value['offset'] + ' END=' + $r.Value['endLine'] + ' HASVALUE=' + $r.HasValue + ' OK=' + $r.Ok"))
    report.results.small = smallText.slice(0, 400)
    record('read.small_file_is_complete_in_value', smallText.includes('TEXT=[alpha' + NL + 'beta' + NL + ']') && smallText.includes('LINES=2'), report.results.small)

    const previewText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$r = $read.Invoke(@{ file_path = \'many-lines.txt\' })' + NL + "'VALUELEN=' + $r.Value['text'].Length" + NL + "'LINES=' + $r.Value['totalLines']" + NL + "'PREVIEW=' + [bool]($r.DisplayText -match 'preview') + ' DISPLAY_HAS_TAIL=' + $r.DisplayText.Contains('line 5000') + ' DISPLAY_LINES=' + ([regex]::Matches($r.DisplayText, 'line ')).Count"))
    const manyValueLength = Number((/VALUELEN=(\d+)/.exec(previewText) || [])[1])
    report.results.preview = { text: previewText.slice(0, 700), expected: manyLines.length }
    record('read.many_lines_value_is_complete', manyValueLength === manyLines.length, report.results.preview)
    record('read.display_is_a_preview_with_a_note',
      previewText.includes('PREVIEW=True') && previewText.includes('DISPLAY_HAS_TAIL=False'),
      report.results.preview)

    const longLineText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$r = $read.Invoke(@{ file_path = \'long-line.txt\' })' + NL + "'LEN=' + $r.Value['text'].Length" + NL + "'HAS_MARKER=' + $r.Value['text'].Contains('line truncated')"))
    record('read.long_line_value_is_not_truncated',
      longLineText.includes('LEN=' + String(longLine.length + 1)) && longLineText.includes('HAS_MARKER=False'),
      longLineText.slice(0, 300))

    // .Value keeps the scope's own untruncated lines beside the text.
    const lineArrayText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$r = $read.Invoke(@{ file_path = \'long-line.txt\' })' + NL + "'COUNT=' + @($r.Value['lines']).Count + ' FIRSTLEN=' + $r.Value['lines'][0]['text'].Length + ' NUMBER=' + $r.Value['lines'][0]['number'] + ' TEXTLEN=' + $r.Value['text'].Length"))
    report.results.lineArray = lineArrayText.slice(0, 300)
    record('read.value_lines_are_untruncated',
      lineArrayText.includes('COUNT=1') && lineArrayText.includes('FIRSTLEN=' + String(longLine.length)) && lineArrayText.includes('NUMBER=1') && lineArrayText.includes('TEXTLEN=' + String(longLine.length + 1)),
      report.results.lineArray)

    const bigText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$r = $read.Invoke(@{ file_path = \'big.txt\' })' + NL + "'LEN=' + $r.Value['text'].Length" + NL + "'LINES=' + $r.Value['totalLines']"))
    record('read.over_display_budget_value_is_complete',
      bigText.includes('LEN=' + String(big.length)) && bigText.includes('LINES=4000'),
      bigText.slice(0, 300))

    const emptyText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$r = $read.Invoke(@{ file_path = \'empty.txt\' })' + NL + "'EMPTY=[' + $r.Value['text'] + '] LINES=' + $r.Value['totalLines'] + ' HASVALUE=' + $r.HasValue"))
    record('read.empty_file_is_a_complete_empty_value', emptyText.includes('EMPTY=[] LINES=0 HASVALUE=True'), emptyText.slice(0, 300))

    const unicodeText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$r = $read.Invoke(@{ file_path = \'unicode.txt\' })' + NL + "'CRLF=' + $r.Value['text'].Contains([char]13 + [char]10) + ' LEN=' + $r.Value['text'].Length"))
    record('read.crlf_and_unicode_survive', unicodeText.includes('CRLF=True') && unicodeText.includes('LEN=' + String(unicode.length)), unicodeText.slice(0, 300))

    const rangeText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$r = $read.Invoke(@{ file_path = \'range.txt\'; offset = 3; limit = 2 })' + NL + "'RANGE=[' + $r.Value['text'] + ']' + ' OFFSET=' + $r.Value['offset'] + ' END=' + $r.Value['endLine'] + ' LIMIT=' + $r.Value['limit'] + ' LINES=' + @($r.Value['lines']).Count + ' FIRST=' + $r.Value['lines'][0]['number']"))
    report.results.range = rangeText.slice(0, 300)
    record('read.explicit_range_returns_exactly_that_range',
      rangeText.includes('RANGE=[L3' + NL + 'L4' + NL + ']') && rangeText.includes('OFFSET=3') && rangeText.includes('END=4') && rangeText.includes('LIMIT=2') && rangeText.includes('LINES=2') && rangeText.includes('FIRST=3'),
      report.results.range)

    // The mounted tool reported FS_NOT_FOUND for an out-of-range offset. This
    // preset's operation cannot construct the harness error type (a preset
    // plugin may not import harness packages), so it reports the condition with
    // a message and no code rather than claiming a code it cannot produce.
    // An offset without a limit is "from that line to end of file", not a
    // whole-file read: it must keep exact CRLF text and correct coordinates.
    // The comparison happens inside the shell: the terminal normalizes carriage
    // returns on display, so the captured text is not a faithful copy of the data.
    const offsetOnlyText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$r = $read.Invoke(@{ file_path = \'unicode.txt\'; offset = 2 })' + NL + "'CRLFTEXT=' + ($r.Value['text'] -ceq ('中文' + [char]13 + [char]10 + 'last')) + ' FIRSTLINE=' + ($r.Value['lines'][0]['text'] -ceq '中文') + ' LASTLINE=' + ($r.Value['lines'][1]['text'] -ceq 'last') + ' LINES=' + @($r.Value['lines']).Count + ' OFFSET=' + $r.Value['offset'] + ' END=' + $r.Value['endLine'] + ' TOTAL=' + $r.Value['totalLines'] + ' SCOPELINES=' + $r.Value['limit']"))
    report.results.offsetOnly = offsetOnlyText.slice(0, 400)
    record('read.offset_without_limit_reads_to_end_of_file',
      offsetOnlyText.includes('CRLFTEXT=True') && offsetOnlyText.includes('FIRSTLINE=True') && offsetOnlyText.includes('LASTLINE=True') && offsetOnlyText.includes('LINES=2') && offsetOnlyText.includes('OFFSET=2') && offsetOnlyText.includes('END=3') && offsetOnlyText.includes('TOTAL=3') && offsetOnlyText.includes('SCOPELINES=2'),
      report.results.offsetOnly)

    // An explicitly null field is not the same as an omitted one.
    const nullArgText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$a = $read.TryInvoke(@{ file_path = \'small.txt\'; offset = $null })' + NL + "'OK=' + $a.Ok + ' MENTIONS=' + [bool]($a.Error['message'] -match 'positive integer')"))
    record('read.explicit_null_argument_is_rejected', nullArgText.includes('OK=False') && nullArgText.includes('MENTIONS=True'), nullArgText.slice(0, 300))

    // Undecodable bytes must be refused on both paths: the range read may not
    // silently replace what the whole-file read refuses.
    writeFileSync(path.join(dir, 'binary.bin'), Buffer.from([0xff, 0xfe, 0x41, 0x0a, 0x42, 0x0a]))
    const binaryWhole = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$a = $read.TryInvoke(@{ file_path = \'binary.bin\' })' + NL + "'OK=' + $a.Ok + ' CODE=' + $a.Error['code'] + ' UTF8=' + [bool]($a.Error['message'] -match 'UTF-8')"))
    const binaryRange = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$a = $read.TryInvoke(@{ file_path = \'binary.bin\'; offset = 2; limit = 1 })' + NL + "'OK=' + $a.Ok + ' CODE=' + $a.Error['code'] + ' UTF8=' + [bool]($a.Error['message'] -match 'UTF-8')"))
    report.results.binary = { whole: binaryWhole.slice(0, 200), range: binaryRange.slice(0, 200) }
    record('read.undecodable_content_is_refused_on_both_paths',
      binaryWhole.includes('OK=False') && binaryRange.includes('OK=False') && binaryWhole.includes('UTF8=True') && binaryRange.includes('UTF8=True'),
      report.results.binary)

    const beyondText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$a = $read.TryInvoke(@{ file_path = \'range.txt\'; offset = 99 })' + NL + "'OK=' + $a.Ok + ' KIND=' + $a.Error['kind'] + ' HASVALUE=' + $a.HasValue + ' OUTOFRANGE=' + [bool]($a.Error['message'] -match 'out of range')"))
    record('read.offset_past_eof_fails_explicitly',
      beyondText.includes('OK=False') && beyondText.includes('HASVALUE=False') && beyondText.includes('KIND=Tool') && beyondText.includes('OUTOFRANGE=True'),
      beyondText.slice(0, 300))

    const hugeText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$a = $read.TryInvoke(@{ file_path = \'huge.txt\' })' + NL + "'OK=' + $a.Ok + ' CODE=' + $a.Error['code'] + ' KIND=' + $a.Error['kind']"))
    report.results.huge = hugeText.slice(0, 400)
    record('read.scope_over_the_resource_limit_fails_explicitly',
      hugeText.includes('OK=False') && hugeText.includes('CODE=FS_TOO_LARGE') && hugeText.includes('KIND='),
      report.results.huge)

    // A range request inside the limit must still succeed on that same huge file.
    const hugeRangeText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$r = $read.Invoke(@{ file_path = \'huge.txt\'; offset = 1; limit = 1 })' + NL + "'LEN=' + $r.Value['text'].Length + ' END=' + $r.Value['endLine']"))
    record('read.explicit_range_succeeds_on_a_file_over_the_limit',
      hugeRangeText.includes('LEN=100') && hugeRangeText.includes('END=1'),
      hugeRangeText.slice(0, 300))

    // --- content blocks ------------------------------------------------------
    // A tool whose whole result is ONE large text block: .Content must stay an
    // array of blocks through the real reply decoder, the block's own text must
    // be intact, and only the printed view may be bounded.
    ctx.tools.register({
      name: 'probe_bigblock',
      description: 'Probe-only tool returning one large text block.',
      parameters: {},
      output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: String(value) }] },
      async execute() { return 'B'.repeat(20000) },
    })
    const contentText = textOf(await exec('$t = Get-DshTool -Name probe_bigblock' + NL + '$r = $t.Invoke(@{})' + NL + "'COUNT=' + @($r.Content).Count + ' TEXTLEN=' + ([string]$r.Content[0]['text']).Length + ' DISPLAYLEN=' + $r.DisplayText.Length + ' VIEWBOUNDED=' + ($r.ViewText.Length -lt 13000)"))
    report.results.content = contentText.slice(0, 300)
    record('content.single_block_stays_an_array_with_its_text',
      contentText.includes('COUNT=1') && contentText.includes('TEXTLEN=20000') && contentText.includes('DISPLAYLEN=20000') && contentText.includes('VIEWBOUNDED=True'),
      report.results.content)

    // --- failure policy ------------------------------------------------------
    const stopMarker = path.join(dir, 'stop-marker.txt')
    rmSync(stopMarker, { force: true })
    const stopText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$null = $read.Invoke(@{ file_path = \'missing.txt\' })' + NL + "Set-Content -LiteralPath '" + stopMarker.replaceAll('\\', '\\\\') + "' -Value 'ran'" + NL + "'BLOCK-CONTINUED'"))
    report.results.stop = { text: stopText.slice(0, 300), marker: existsSync(stopMarker) }
    record('failure.stop_policy_prevents_dependent_writes', !existsSync(stopMarker) && !stopText.includes('BLOCK-CONTINUED'), report.results.stop)

    const branchText = textOf(await exec('$read = Get-DshTool -Name read' + NL + '$attempt = $read.TryInvoke(@{ file_path = \'missing.txt\' })' + NL + 'if ($attempt.Ok) { ' + "'UNEXPECTED'" + ' } else { ' + "'BRANCH-FAILED:' + $attempt.Error['kind'] + ':' + $attempt.Error['code'] + ':' + [bool]($attempt.Error['message'] -match 'missing')" + ' }'))
    record('failure.tryinvoke_supports_expected_branches', branchText.includes('BRANCH-FAILED:Tool:FS_NOT_FOUND:True'), branchText.slice(0, 300))

    // --- reuse across blocks -------------------------------------------------
    await exec('$held = Get-DshTool -Name read')
    const reuseText = textOf(await exec('$r = $held.Invoke(@{ file_path = \'small.txt\' })' + NL + "'REUSED=' + ($r.Value['text'] -eq (Get-Content -LiteralPath 'small.txt' -Raw))"))
    record('reuse.handle_works_in_a_later_block', reuseText.includes('REUSED=True'), reuseText.slice(0, 200))

    // --- definition drift ----------------------------------------------------
    const driftFirst = textOf(await exec('$t = Get-DshTool -Name probe_drift' + NL + '$t.Invoke(@{ note = \'one\' })'))
    record('drift.first_call_uses_the_cached_definition', driftFirst.includes('DRIFT-1:one'), driftFirst.slice(0, 300))
    disposeDrift()
    driftVersion = 2
    disposeDrift = registerDrift()
    // The handle from the previous block is reused deliberately: re-fetching it
    // here would pull the new definition and defeat the check.
    // The persistent shell wraps long output lines, which can split a word; the
    // shell therefore evaluates the message assertions and prints short tokens.
    const driftSecond = textOf(await exec('try { $null = $t.Invoke(@{ note = \'stale\' }); ' + "'DRIFT=NO-REFUSAL'" + ' } catch { $m = $_.Exception.Message; ' + "'DRIFT=REFUSED HAS-CHANGED=' + ($m -like '*changed*') + ' HAS-REFRESH=' + ($m -like '*Refresh()*')" + ' }'))
    report.results.drift = driftSecond.slice(0, 400)
    record('drift.stale_handle_is_refused_before_executing',
      driftSecond.includes('DRIFT=REFUSED') && driftSecond.includes('HAS-CHANGED=True') && driftSecond.includes('HAS-REFRESH=True'),
      report.results.drift)

    const driftRefresh = textOf(await exec('$t = Get-DshTool -Name probe_drift' + NL + '$t = $t.Refresh()' + NL + '$t.Invoke(@{ note = \'two\' })'))
    record('drift.refresh_then_call_succeeds', driftRefresh.includes('DRIFT-2:two'), driftRefresh.slice(0, 300))

    // --- the prompt's worked example, executed verbatim ----------------------
    writeFileSync(path.join(dir, 'orders.json'), JSON.stringify([
      { id: 'A-1001', amount: 15, paid: true },
      { id: 'A-1002', amount: 7.25, paid: false },
      { id: 'A-1003', amount: 30, paid: true },
      { id: 'A-1004', amount: 2.5, paid: true },
      { id: 'A-1005', amount: 3.75, paid: false },
    ], null, 2) + NL)
    const example = [
      '$read, $write, $edit = Get-DshTool -Name read, write, edit',
      '$source = $read.Invoke(@{ file_path = \'orders.json\' })',
      '$orders = $source.Value.Text | ConvertFrom-Json',
      '$total = ($orders | Where-Object paid | Measure-Object amount -Sum).Sum',
      '$line = \'total: \' + $total.ToString(\'0.00\', [cultureinfo]::InvariantCulture)',
      '$written = $write.Invoke(@{ file_path = \'summary.md\'; content = $line })',
      // The filesystem observation policy requires reading a file before editing
      // it, so the example reads notes.txt first - as a real task must.
      '$notes = $read.Invoke(@{ file_path = \'notes.txt\' })',
      '$edited = $edit.Invoke(@{ file_path = \'notes.txt\'; old_string = \'STATUS: draft\'; new_string = \'STATUS: final\' })',
      '$summaryCheck = $read.Invoke(@{ file_path = \'summary.md\' })',
      '$notesCheck = $read.Invoke(@{ file_path = \'notes.txt\' })',
      'if ($summaryCheck.Value.Text.TrimEnd() -cne $line) { throw \'summary.md does not match the computed total\' }',
      'if ($notesCheck.Value.Text -notmatch (\'(?m)^STATUS: final\' + [char]13 + \'?$\')) { throw \'notes.txt status verification failed\' }',
      '$summaryCheck',
      '$notesCheck',
    ].join(NL)
    const exampleResult = await exec(example)
    const exampleText = textOf(exampleResult)
    report.results.example = { text: exampleText.slice(0, 800), isError: exampleResult.isError, summary: existsSync(path.join(dir, 'summary.md')) ? readFileSync(path.join(dir, 'summary.md'), 'utf8') : null }
    record('example.worked_example_runs_verbatim',
      exampleResult.isError !== true &&
      report.results.example.summary === 'total: 47.50' &&
      readFileSync(path.join(dir, 'notes.txt'), 'utf8').includes('STATUS: final') &&
      exampleText.includes('47.50'),
      report.results.example)

    // --- media stays on its own channel -------------------------------------
    // read_image is composition-conditional: it registers only while the
    // attachment store is mounted. When it is mounted, image bytes must stay on
    // their own channel instead of degrading into text; when it is not mounted,
    // the object interface must refuse the name instead of inventing a text
    // contract for media it cannot read.
    if (catalogText.includes('read_image')) {
      const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64')
      writeFileSync(path.join(dir, 'dot.png'), png)
      // An image may only reach the model on its own channel: either the call
      // attaches an image block, or it fails and says why. It must never turn
      // into a text block that claims to be the picture.
      const mediaResult = await exec('try { $img = Get-DshTool -Name read_image; $r = $img.Invoke(@{ file_path = \'dot.png\' }); ' + "'MEDIA-OK blocks=' + $r.Content.Count + ' textblocks=' + (($r.Content | Where-Object { $_.type -eq 'text' }).Count)" + ' } catch { ' + "'MEDIA-ERR: ' + $_.Exception.Message" + ' }')
      const mediaText = textOf(mediaResult)
      const extraBlocks = (mediaResult.additionalContexts || []).flatMap(entry => entry.content || [])
      const attached = extraBlocks.some(block => block.type === 'image')
      const refused = mediaText.includes('MEDIA-ERR') && mediaText.includes('image')
      report.results.media = { mounted: true, attached, text: mediaText.slice(0, 300), additional: extraBlocks.length, types: extraBlocks.map(block => block.type) }
      record('media.image_stays_on_its_own_channel_or_fails_explicitly',
        attached || (refused && !mediaText.includes('MEDIA-OK')),
        report.results.media)
    }
    else {
      const absent = textOf(await exec("try { $null = Get-DshTool -Name read_image; 'UNEXPECTED-HANDLE' } catch { 'REFUSED: ' + $_.Exception.Message }"))
      report.results.media = { mounted: false, text: absent.slice(0, 300) }
      record('media.unmounted_image_tool_is_refused_not_faked', absent.includes('REFUSED') && absent.includes('unknown tool') && !absent.includes('UNEXPECTED-HANDLE'), report.results.media)
    }

    disposeDrift()
    report.completed = true
    save()
    await ctx.sessions.flush(agent.session)
    ctx.get('appExit')?.(report.checks.every(check => check.ok) ? 0 : 2)
  }

  run().catch(error => { report.error = error && error.stack ? error.stack : String(error); save(); ctx.get('appExit')?.(1) })
}
