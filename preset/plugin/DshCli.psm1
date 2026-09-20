<#
DshCli - tool objects and result objects for dsh-all-in-pwsh.

Every function here talks to the host bridge over HTTP with an explicit UTF-8
JSON body. The per-execution identity (bridge path, call id and capability)
comes from the environment the host writes into this shell before each command
runs; nothing is read back from a shared "current call" file, so a background
process started by an earlier command keeps the identity it inherited and is
refused once that execution ends.

An argument object is validated in its ORIGINAL form and serialized exactly
once, as part of the request envelope. It is never round-tripped through
ConvertFrom-Json, which would collide case-differing dictionary keys and coerce
date-like strings. Replies are decoded by ConvertFrom-DshJson, which keeps
strings as strings, keeps case-differing keys apart, and distinguishes a null
value from an absent key.
#>

$script:DshCliBridgePath = $null
$script:DshCliBridge = $null
$script:DshCliClient = $null

$script:DshCliMaxDepth = 48
$script:DshCliMaxJsonDepth = 64

# --- bridge rendezvous and client --------------------------------------------

function Get-DshCliBridge {
    <#
    .SYNOPSIS
    Read the per-instance bridge rendezvous this shell was pointed at.
    #>
    [CmdletBinding()]
    param()

    $path = $env:DSH_PWSH_BRIDGE
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw [System.InvalidOperationException]::new(
            'dsh-all-in-pwsh is not active in this shell: DSH_PWSH_BRIDGE is not set. It is written by the host before each command runs, so this shell was not started by the preset, or the command is running outside its host call.')
    }
    if ($script:DshCliBridgePath -ne $path -or $null -eq $script:DshCliBridge) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw [System.InvalidOperationException]::new("The bridge file named by DSH_PWSH_BRIDGE does not exist: $path")
        }
        $script:DshCliBridge = ConvertFrom-DshJson -Json (Get-Content -LiteralPath $path -Raw -ErrorAction Stop)
        $script:DshCliBridgePath = $path
    }
    return $script:DshCliBridge
}

function New-DshCliClient {
    <#
    .SYNOPSIS
    One cached HttpClient for every call in this shell.

    .DESCRIPTION
    The bridge is a loopback endpoint, so the client never consults a proxy:
    an ambient corporate or SOCKS proxy would otherwise capture 127.0.0.1
    traffic. The client is disposed when the module is removed.
    #>
    [CmdletBinding()]
    param()
    if ($null -eq $script:DshCliClient) {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [System.TimeSpan]::FromMinutes(10)
        $script:DshCliClient = $client
    }
    return $script:DshCliClient
}

# --- exact JSON decoding ------------------------------------------------------

function ConvertFrom-DshJsonValue {
    <#
    .SYNOPSIS
    Convert one System.Text.Json element into PowerShell values without losing fidelity.

    .DESCRIPTION
    Objects become case-sensitive, order-preserving dictionaries so keys that
    differ only in case stay apart, a null value is a present key holding
    $null, arrays keep their length (including 1 and 0), numbers stay integers
    when they fit and strings are never reinterpreted as dates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][int]$Depth
    )

    if ($Depth -gt $script:DshCliMaxJsonDepth) {
        throw [System.InvalidOperationException]::new("The JSON value exceeds the maximum depth of $($script:DshCliMaxJsonDepth).")
    }
    $kind = $Element.ValueKind
    if ($kind -eq [System.Text.Json.JsonValueKind]::Object) {
        # Property access stays case-insensitive in the ordinary case, so
        # $result.Value.Text reads the key the tool declared. An object whose
        # keys differ only by case keeps BOTH keys and switches to exact lookup:
        # there, an ambiguous key is read by index, never silently merged.
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $ambiguous = $false
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) { $ambiguous = $true; break }
        }
        $comparer = if ($ambiguous) { [System.StringComparer]::Ordinal } else { [System.StringComparer]::OrdinalIgnoreCase }
        $map = [System.Collections.Specialized.OrderedDictionary]::new($comparer)
        foreach ($property in $Element.EnumerateObject()) {
            $map[$property.Name] = ConvertFrom-DshJsonValue -Element $property.Value -Depth ($Depth + 1)
        }
        return $map
    }
    if ($kind -eq [System.Text.Json.JsonValueKind]::Array) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Element.EnumerateArray()) {
            $items.Add((ConvertFrom-DshJsonValue -Element $item -Depth ($Depth + 1)))
        }
        # The unary comma keeps the array one pipeline object, so an empty or
        # single-element array stays an array at the assignment site.
        return ,$items.ToArray()
    }
    if ($kind -eq [System.Text.Json.JsonValueKind]::String) { return $Element.GetString() }
    if ($kind -eq [System.Text.Json.JsonValueKind]::Number) {
        $asLong = [int64]0
        if ($Element.TryGetInt64([ref]$asLong)) { return $asLong }
        $asDecimal = [decimal]0
        if ($Element.TryGetDecimal([ref]$asDecimal)) { return $asDecimal }
        return $Element.GetDouble()
    }
    if ($kind -eq [System.Text.Json.JsonValueKind]::True) { return $true }
    if ($kind -eq [System.Text.Json.JsonValueKind]::False) { return $false }
    return $null
}

function ConvertFrom-DshJson {
    <#
    .SYNOPSIS
    Decode one JSON document with ConvertFrom-DshJsonValue's fidelity rules.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
        # The unary comma keeps a top-level array one pipeline object: without it a
        # root [] arrives as $null and a root [1] unwraps to a scalar.
        return ,(ConvertFrom-DshJsonValue -Element $document.RootElement -Depth 1)
    }
    finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}

# --- argument validation ------------------------------------------------------

function Test-DshCliScalar {
    <#
    .SYNOPSIS
    Test whether one value is a JSON scalar this module accepts.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [bool]) { return $true }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]) { return $true }
    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) { return $true }
    return $false
}

function Assert-DshCliJsonValue {
    <#
    .SYNOPSIS
    Validate one subtree against the JSON subset the bridge accepts.

    .DESCRIPTION
    Rejects cycles, over-deep nesting, non-string dictionary keys and every
    type that has no lossless JSON form, naming the path and the type so the
    caller can fix the argument instead of silently sending a stringified
    value.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$Value,
        [Parameter(Mandatory)][int]$Depth,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Ancestors
    )

    if ($Depth -gt $script:DshCliMaxDepth) {
        throw [System.ArgumentException]::new("$Path exceeds the maximum JSON depth of $($script:DshCliMaxDepth). Flatten the arguments before calling.")
    }
    if ($null -eq $Value) { return }

    if (Test-DshCliScalar -Value $Value) {
        if ($Value -is [single] -or $Value -is [double]) {
            if ([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value)) {
                throw [System.ArgumentException]::new("$Path is a non-finite number, which JSON cannot carry.")
            }
        }
        return
    }

    $type = $Value.GetType()

    $rejected = @{
        'System.DateTime'         = 'a DateTime; send an ISO-8601 string instead'
        'System.DateTimeOffset'   = 'a DateTimeOffset; send an ISO-8601 string instead'
        'System.TimeSpan'         = 'a TimeSpan; send a string or a number of seconds instead'
        'System.Guid'             = 'a Guid; send its string form instead'
        'System.Management.Automation.ScriptBlock' = 'a ScriptBlock, which cannot cross the bridge'
        'System.Type'             = 'a Type, which cannot cross the bridge'
    }
    $full = $type.FullName
    if ($rejected.ContainsKey($full)) {
        throw [System.ArgumentException]::new("$Path is $($rejected[$full]).")
    }
    if ($type.IsEnum) {
        throw [System.ArgumentException]::new("$Path is the enum $full; send its string or numeric value instead.")
    }

    foreach ($ancestor in $Ancestors) {
        if ([object]::ReferenceEquals($ancestor, $Value)) {
            throw [System.ArgumentException]::new("$Path contains a cycle; a value already appears in its own ancestry.")
        }
    }

    $isDictionary = $Value -is [System.Collections.IDictionary]
    $isCustom = $full -eq 'System.Management.Automation.PSCustomObject'
    $isEnumerable = (-not $isDictionary) -and (-not ($Value -is [string])) -and ($Value -is [System.Collections.IEnumerable])

    if (-not ($isDictionary -or $isCustom -or $isEnumerable)) {
        throw [System.ArgumentException]::new("$Path is a $full, which has no lossless JSON form. Use a string, number, boolean, null, array, hashtable, ordered dictionary or PSCustomObject.")
    }

    $Ancestors.Add($Value)
    try {
        if ($isDictionary) {
            foreach ($key in $Value.Keys) {
                if (-not ($key -is [string])) {
                    throw [System.ArgumentException]::new("$Path has a key of type $($key.GetType().FullName); JSON object keys must be strings. Convert the key before calling.")
                }
                Assert-DshCliJsonValue -Value $Value[$key] -Depth ($Depth + 1) -Path "$Path.$key" -Ancestors $Ancestors
            }
        }
        elseif ($isCustom) {
            foreach ($property in $Value.PSObject.Properties) {
                Assert-DshCliJsonValue -Value $property.Value -Depth ($Depth + 1) -Path "$Path.$($property.Name)" -Ancestors $Ancestors
            }
        }
        else {
            $index = 0
            foreach ($item in $Value) {
                Assert-DshCliJsonValue -Value $item -Depth ($Depth + 1) -Path "$Path[$index]" -Ancestors $Ancestors
                $index = $index + 1
            }
        }
    }
    finally {
        $Ancestors.RemoveAt($Ancestors.Count - 1)
    }
}

function Test-DshCliArguments {
    <#
    .SYNOPSIS
    Validate one argument object and return it unchanged.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)

    if ($null -eq $Value) { return [ordered]@{} }

    $isDictionary = $Value -is [System.Collections.IDictionary]
    $isCustom = $Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject'
    if (-not ($isDictionary -or $isCustom)) {
        throw [System.ArgumentException]::new("Arguments must be a hashtable, ordered dictionary or PSCustomObject with named members; got $($Value.GetType().FullName).")
    }

    $ancestors = [System.Collections.Generic.List[object]]::new()
    Assert-DshCliJsonValue -Value $Value -Depth 1 -Path 'arguments' -Ancestors $ancestors
    return $Value
}

# --- the bridge request -------------------------------------------------------

function Invoke-DshCliRpc {
    <#
    .SYNOPSIS
    Send one request to the host bridge and return its decoded reply.

    .DESCRIPTION
    The payload carries the caller's argument object in its original form and is
    serialized exactly ONCE, as the complete request envelope, at an explicit
    depth that accounts for the envelope level.

    Throws for anything that is not an answered request: a missing execution
    identity, an unreachable endpoint, a non-200 status or an unreadable body.
    A refused or failed operation is NOT thrown here; it comes back decoded so
    the caller can shape it into one result object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Payload)

    $bridge = Get-DshCliBridge
    $session = $env:DSH_SESSION_ID
    if ([string]::IsNullOrWhiteSpace($session)) {
        throw [System.InvalidOperationException]::new('DSH_SESSION_ID is not set, so this shell cannot prove which session it belongs to.')
    }
    $call = $env:DSH_PWSH_CALL
    $capability = $env:DSH_PWSH_CAP
    if ([string]::IsNullOrWhiteSpace($call) -or [string]::IsNullOrWhiteSpace($capability)) {
        throw [System.InvalidOperationException]::new(
            'This process has no execution identity: DSH_PWSH_CALL/DSH_PWSH_CAP were not inherited. A bridged call only works inside the shell command that started it; a background process started by an earlier command keeps that earlier identity and is refused once it ends.')
    }

    $envelope = [ordered]@{
        instance   = $bridge['instance']
        session    = $session
        call       = $call
        capability = $capability
    }
    foreach ($key in $Payload.Keys) { $envelope[$key] = $Payload[$key] }
    $json = ConvertTo-Json -InputObject $envelope -Depth ($script:DshCliMaxDepth + 2) -Compress

    $uri = 'http://127.0.0.1:' + $bridge['port'] + '/rpc'
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
    $response = $null
    try {
        $request.Headers.Add('x-dsh-cli-token', [string]$bridge['token'])
        $request.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
        $response = (New-DshCliClient).Send($request)
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
    }
    catch [System.Net.Http.HttpRequestException] {
        throw [System.Net.Http.HttpRequestException]::new(
            "The bridge at $uri is unreachable: $($_.Exception.Message). The host that owns this shell is gone or its bridge stopped; a call that had already started may or may not have taken effect.", $_.Exception)
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
    }

    if ($status -ne 200) {
        throw [System.InvalidOperationException]::new("The bridge answered HTTP $status for a request it should have accepted: $text")
    }
    try {
        $reply = ConvertFrom-DshJson -Json $text
    }
    catch {
        throw [System.InvalidOperationException]::new("The bridge answered with unreadable JSON: $text")
    }
    if ($null -eq $reply) {
        throw [System.InvalidOperationException]::new('The bridge answered with an empty document.')
    }
    return $reply
}

# --- result and tool objects --------------------------------------------------

class DshToolInfo {
    <#
    .SYNOPSIS
    One catalog row: what a tool is called and what it is for.
    #>
    [string]$Name
    [string]$Summary
}

class DshToolResult {
    <#
    .SYNOPSIS
    The single object every tool call returns.

    .DESCRIPTION
    Printing it shows DisplayText; assigning it keeps the structured fields.
    Value holds the tool's structured data (for read, the complete decoded text
    of the requested scope), HasValue distinguishes "no structured value" from
    "a value that is null", and Error is structured whenever Ok is false.
    #>
    [bool]$Ok
    [bool]$HasValue
    [object]$Value
    [object]$Content
    [string]$DisplayText
    [object]$Error
    [object]$Metadata
}

class DshTool {
    <#
    .SYNOPSIS
    A reusable, callable tool: one definition fetched once, callable from any
    later block of the same shell.

    .DESCRIPTION
    Property access is local and never talks to the bridge. Invoke, TryInvoke
    and Refresh are the only members that execute anything; Invoke raises a
    failure, TryInvoke returns it as a result object.
    #>
    [string]$Name
    [string]$Summary
    [string]$Description
    [object]$InputSchema
    [object]$OutputSchema
    [object]$ReturnContract
    [object]$Examples
    [string]$DefinitionVersion
    [string]$Instance
    [string]$SessionId

    [DshToolResult] Invoke([object]$Arguments) {
        return (Invoke-DshToolObject -Tool $this -Arguments $Arguments -Raise)
    }

    [DshToolResult] TryInvoke([object]$Arguments) {
        return (Invoke-DshToolObject -Tool $this -Arguments $Arguments)
    }

    [DshTool] Refresh() {
        return (Get-DshTool -Name $this.Name)
    }
}

function Test-DshCliEnvelopeRefusal {
    <#
    .SYNOPSIS
    Whether one bridge reply is a refusal rather than a tool result.

    .DESCRIPTION
    A refusal carries a string `error` and no `ok` field. A call reply always
    carries `ok`, and its `error` is a structured object or null, so the two can
    never be confused by key presence alone.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Reply)

    if (-not $Reply.Contains('error')) { return $false }
    if ($Reply['error'] -isnot [string]) { return $false }
    if ([string]::IsNullOrEmpty([string]$Reply['error'])) { return $false }
    return (-not $Reply.Contains('ok'))
}

function New-DshToolResult {
    <#
    .SYNOPSIS
    Shape one bridge reply into the single result object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Reply,
        [Parameter(Mandatory)][string]$Tool
    )

    $result = [DshToolResult]::new()
    $result.Ok = [bool]$Reply['ok']
    $result.HasValue = [bool]$Reply['hasValue']
    $result.Value = $null
    if ($result.HasValue -and $Reply.Contains('valueJson') -and ($Reply['valueJson'] -is [string])) {
        $result.Value = ConvertFrom-DshJson -Json ([string]$Reply['valueJson'])
    }
    # Direct assignments, never an if-expression: PowerShell enumerates an
    # if-expression's output, which would turn zero blocks into $null and a
    # single block into the block itself instead of a one-element array.
    $result.DisplayText = ''
    if ($Reply.Contains('displayText') -and $null -ne $Reply['displayText']) {
        $result.DisplayText = [string]$Reply['displayText']
    }
    $result.Content = @()
    if ($Reply.Contains('content') -and $null -ne $Reply['content']) {
        $blocks = $Reply['content']
        if (($blocks -is [System.Collections.IEnumerable]) -and -not ($blocks -is [string])) {
            $result.Content = $blocks
        }
        else {
            $result.Content = @($blocks)
        }
    }
    $result.Error = $null
    if ($Reply.Contains('error')) { $result.Error = $Reply['error'] }
    $result.Metadata = $null
    if ($Reply.Contains('metadata')) { $result.Metadata = $Reply['metadata'] }
    if (-not $result.Ok -and $null -eq $result.Error) {
        $result.Error = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        $result.Error['kind'] = 'Bridge'
        $result.Error['code'] = $null
        $result.Error['message'] = 'the bridge returned no error detail for this call'
        $result.Error['tool'] = $Tool
        $result.Error['parameterPath'] = $null
    }
    return $result
}

function New-DshToolFailure {
    <#
    .SYNOPSIS
    One result object describing a refusal that never reached a tool execution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][AllowNull()][object]$Code,
        [Parameter()][AllowNull()][string]$ParameterPath,
        [Parameter()][string]$Outcome = 'not-executed'
    )

    $result = [DshToolResult]::new()
    $result.Ok = $false
    $result.HasValue = $false
    $result.Value = $null
    $result.DisplayText = ''
    $result.Content = @()
    $error = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    $error['kind'] = $Kind
    $error['code'] = $Code
    $error['message'] = $Message
    $error['tool'] = $Tool
    $error['parameterPath'] = $ParameterPath
    $result.Error = $error
    $metadata = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    $metadata['tool'] = $Tool
    $metadata['callId'] = $null
    $metadata['rootCallId'] = $null
    $metadata['parentCallId'] = $null
    $metadata['session'] = $env:DSH_SESSION_ID
    $metadata['instance'] = $null
    $metadata['durationMs'] = 0
    $metadata['definitionVersion'] = $null
    $metadata['outcome'] = $Outcome
    $result.Metadata = $metadata
    return $result
}

function Get-DshTool {
    <#
    .SYNOPSIS
    List the session's tools, or obtain reusable tool objects for named tools.

    .DESCRIPTION
    Without -Name this returns one DshToolInfo per mounted tool: Name and
    Summary only, for discovery. With -Name it returns one DshTool object per
    requested name, in the order given; the definition is fetched once, here,
    and property access afterwards is local. A name that is not mounted fails
    explicitly instead of returning nothing.

    Print a returned tool object to see its parameters, its return contract and
    a short validated example; keep the variable to call it from any later
    block.

    .PARAMETER Name
    One or more exact tool names.

    .EXAMPLE
    Get-DshTool

    .EXAMPLE
    $read, $write = Get-DshTool -Name read, write
    #>
    [CmdletBinding()]
    [OutputType([DshToolInfo])]
    [OutputType([DshTool])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name
    )

    if (-not $PSBoundParameters.ContainsKey('Name')) {
        $reply = Invoke-DshCliRpc -Payload ([ordered]@{ op = 'list' })
        if ((Test-DshCliEnvelopeRefusal -Reply $reply)) {
            throw [System.InvalidOperationException]::new([string]$reply['error'])
        }
        foreach ($tool in $reply['tools']) {
            $info = [DshToolInfo]::new()
            $info.Name = [string]$tool['name']
            $info.Summary = [string]$tool['summary']
            $info
        }
        return
    }

    $reply = Invoke-DshCliRpc -Payload ([ordered]@{ op = 'get'; names = $Name })
    if ((Test-DshCliEnvelopeRefusal -Reply $reply)) {
        throw [System.InvalidOperationException]::new([string]$reply['error'])
    }
    $instance = [string](Get-DshCliBridge)['instance']
    foreach ($detail in $reply['tools']) {
        $tool = [DshTool]::new()
        $tool.Name = [string]$detail['name']
        $tool.Summary = [string]$detail['summary']
        $tool.Description = [string]$detail['description']
        $tool.InputSchema = $detail['inputSchema']
        $tool.OutputSchema = $detail['outputSchema']
        $tool.ReturnContract = $detail['returnContract']
        $tool.Examples = $detail['examples']
        $tool.DefinitionVersion = [string]$detail['definitionVersion']
        $tool.Instance = $instance
        # Bound at creation: the handle belongs to this session and this bridge,
        # and caches no execution capability.
        $tool.SessionId = [string]$env:DSH_SESSION_ID
        $tool
    }
}

function Get-DshToolSchema {
    <#
    .SYNOPSIS
    Return one tool's structured input schema.

    .DESCRIPTION
    Convenience entry point for (Get-DshTool -Name <name>).InputSchema. The
    result is an object, not JSON text: address fields directly, or serialize it
    explicitly with ConvertTo-Json when text is what you need.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    return (Get-DshTool -Name $Name).InputSchema
}

function Invoke-DshToolObject {
    <#
    .SYNOPSIS
    Execute one tool object call and shape the reply into a result object.

    .DESCRIPTION
    The tool's cached definition version travels with the request, so a
    definition that changed after the object was created is refused before
    anything executes. Arguments are validated in their original form.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][DshTool]$Tool,
        [Parameter()][AllowNull()][object]$Arguments,
        [switch]$Raise
    )

    $bridge = Get-DshCliBridge
    $currentInstance = [string]$bridge['instance']
    # A handle bound to another bridge, or to another session, is host control
    # flow: it is raised even from TryInvoke, so a script cannot branch past it.
    if (-not [string]::IsNullOrEmpty($Tool.Instance) -and $Tool.Instance -ne $currentInstance) {
        $message = "The tool object for '$($Tool.Name)' belongs to bridge instance $($Tool.Instance), but this shell is running under instance $currentInstance. A tool object is reusable across blocks of the session that created it and across no other; obtain a fresh object with Get-DshTool -Name $($Tool.Name)."
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new($message),
            'DshTool.Host.HANDLE_INSTANCE_MISMATCH',
            [System.Management.Automation.ErrorCategory]::ConnectionError,
            (New-DshToolFailure -Tool $Tool.Name -Kind 'Host' -Code 'HANDLE_INSTANCE_MISMATCH' -Message $message -Outcome 'not-executed'))
        $PSCmdlet.ThrowTerminatingError($record)
    }
    $currentSession = [string]$env:DSH_SESSION_ID
    if (-not [string]::IsNullOrEmpty($Tool.SessionId) -and $Tool.SessionId -ne $currentSession) {
        $message = "The tool object for '$($Tool.Name)' belongs to session $($Tool.SessionId), but this shell is running in session $currentSession. A tool object is reusable across blocks of the session that created it and across no other; obtain a fresh object with Get-DshTool -Name $($Tool.Name)."
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new($message),
            'DshTool.Host.HANDLE_SESSION_MISMATCH',
            [System.Management.Automation.ErrorCategory]::ConnectionError,
            (New-DshToolFailure -Tool $Tool.Name -Kind 'Host' -Code 'HANDLE_SESSION_MISMATCH' -Message $message -Outcome 'not-executed'))
        $PSCmdlet.ThrowTerminatingError($record)
    }

    # A rejected argument object is a call failure, not an escape from the
    # result contract: TryInvoke reports it, Invoke raises it.
    $validated = $null
    try {
        $validated = Test-DshCliArguments -Value $Arguments
    }
    catch {
        if ($Raise) { throw }
        return (New-DshToolFailure -Tool $Tool.Name -Kind 'Bridge' -Code 'INVALID_ARGUMENTS' -Message $_.Exception.Message -ParameterPath 'arguments' -Outcome 'not-executed')
    }
    $payload = [ordered]@{
        op        = 'call'
        name      = $Tool.Name
        arguments = $validated
    }
    if (-not [string]::IsNullOrEmpty($Tool.DefinitionVersion)) {
        $payload['definitionVersion'] = $Tool.DefinitionVersion
    }

    $reply = $null
    $transportFailure = $null
    try {
        $reply = Invoke-DshCliRpc -Payload $payload
    }
    catch {
        $transportFailure = $_
    }

    if ($null -ne $transportFailure) {
        # The bridge never answered: the call may or may not have taken effect.
        # This stays a result for TryInvoke, never a silent success.
        $result = New-DshToolFailure -Tool $Tool.Name -Kind 'Bridge' -Code 'BRIDGE_UNREACHABLE' -Message $transportFailure.Exception.Message -Outcome 'unknown'
        if (-not $Raise) { return $result }
        throw [System.Net.Http.HttpRequestException]::new($result.Error['message'], $transportFailure.Exception)
    }

    # An envelope refusal is a string error on a reply that has no "ok" field;
    # a call reply always carries "ok" and its own structured error object, so a
    # tool failure is never mistaken for a transport refusal.
    if ((Test-DshCliEnvelopeRefusal -Reply $reply)) {
        $code = if ($reply.Contains('code')) { [string]$reply['code'] } else { $null }
        # Host control flow - a revoked capability, an expired execution, a
        # foreign bridge - is not an ordinary recoverable failure: it is raised
        # even from TryInvoke so a script cannot branch past it.
        $hostControl = $code -in @('IDENTITY_REVOKED', 'EXECUTION_ENDED', 'NO_CALL_IN_FLIGHT', 'NO_EXECUTION_IDENTITY', 'INSTANCE_MISMATCH', 'BAD_TOKEN')
        $result = New-DshToolFailure -Tool $Tool.Name -Kind $(if ($hostControl) { 'Host' } else { 'Bridge' }) -Code $code -Message ([string]$reply['error']) -Outcome 'not-executed'
        if ($hostControl -or $Raise) {
            $record = [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new($result.Error['message']),
                "DshTool.$($result.Error['kind']).$code",
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $result)
            $PSCmdlet.ThrowTerminatingError($record)
        }
        return $result
    }

    $result = New-DshToolResult -Reply $reply -Tool $Tool.Name
    if (-not $result.Ok -and $Raise) {
        $message = [string]$result.Error['message']
        if ([string]::IsNullOrWhiteSpace($message)) { $message = "the call to '$($Tool.Name)' failed" }
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new($message),
            "DshTool.$($result.Error['kind'])",
            [System.Management.Automation.ErrorCategory]::InvalidResult,
            $result)
        $PSCmdlet.ThrowTerminatingError($record)
    }
    return $result
}

function Invoke-DshTool {
    <#
    .SYNOPSIS
    Call any tool mounted in this session from the shell.

    .DESCRIPTION
    Convenience entry point for one call when no reusable tool object is needed.
    It returns the same DshToolResult as $tool.Invoke(...), with the same error
    policy: a failed call terminates the statement, so dependent work does not
    run on missing data. Use TryInvoke on a tool object when a failure is an
    expected branch.

    Arguments are a PowerShell object, not JSON text: pass a hashtable, an
    ordered dictionary or a PSCustomObject. Omit -Arguments to call a tool that
    takes none. Nested objects, arrays, null, booleans, numbers, Unicode,
    newlines, quotes and backslashes cross the bridge unchanged.

    -PassThru is accepted for compatibility and changes nothing: every call
    already returns the result object.
    #>
    [CmdletBinding()]
    [OutputType([DshToolResult])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Position = 1)]
        [object]$Arguments,

        [switch]$PassThru
    )

    $payload = [ordered]@{
        op        = 'call'
        name      = $Name
        arguments = (Test-DshCliArguments -Value $Arguments)
    }
    $reply = Invoke-DshCliRpc -Payload $payload
    if ((Test-DshCliEnvelopeRefusal -Reply $reply)) {
        $message = [string]$reply['error']
        throw [System.InvalidOperationException]::new($message)
    }
    $result = New-DshToolResult -Reply $reply -Tool $Name
    if (-not $result.Ok) {
        $message = [string]$result.Error['message']
        if ([string]::IsNullOrWhiteSpace($message)) { $message = "the call to '$Name' failed" }
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new($message),
            "DshTool.$($result.Error['kind'])",
            [System.Management.Automation.ErrorCategory]::InvalidResult,
            $result)
        $PSCmdlet.ThrowTerminatingError($record)
    }
    return $result
}

Set-Alias -Name dsh-tool -Value Invoke-DshTool -Force

# --- type data and format views ----------------------------------------------

# .Text stays as a display alias: it returns exactly what printing the result
# shows, and it is never the data channel - use .Value for data.
Update-TypeData -TypeName 'DshToolResult' -MemberType ScriptProperty -MemberName 'Text' -Value { $this.DisplayText } -Force

# What printing shows: the tool's display text, or the failure message when the
# call never produced one. The printed view is bounded independently of the
# data: a generic tool that returns a very long display text is shortened here
# only, and .DisplayText still holds every character the tool produced.
Update-TypeData -TypeName 'DshToolResult' -MemberType ScriptProperty -MemberName 'ViewText' -Value {
    $text = $this.DisplayText
    if ([string]::IsNullOrEmpty($text)) {
        if ($null -ne $this.Error) { return [string]$this.Error['message'] }
        return ''
    }
    $limit = 12000
    if ($text.Length -le $limit) { return $text }
    return $text.Substring(0, $limit) + [char]10 + '... (display truncated at ' + $limit + ' characters; .DisplayText holds the full text and .Value holds the data)'
} -Force

# One status line: tool, outcome, and for a read the scope the value carries.
Update-TypeData -TypeName 'DshToolResult' -MemberType ScriptProperty -MemberName 'StatusLine' -Value {
    $metadata = $this.Metadata
    $tool = if ($null -ne $metadata -and $metadata.Contains('tool')) { [string]$metadata['tool'] } else { 'tool' }
    $parts = @($tool, $(if ($this.Ok) { 'ok' } else { 'failed' }))
    if ($this.Ok) {
        $value = $this.Value
        if (-not $this.HasValue) { $parts += 'no structured value' }
        elseif ($null -eq $value) { $parts += 'value is null' }
        elseif ($value -is [System.Collections.IDictionary] -and $value.Contains('text')) {
            $parts += ('text ' + ([string]$value['text']).Length + ' chars')
            if ($value.Contains('totalLines')) { $parts += ([string]$value['totalLines'] + ' lines total') }
            $parts += ('scope lines ' + [string]$value['offset'] + '-' + [string]$value['endLine'])
        }
        else { $parts += 'value present' }
    }
    else {
        $error = $this.Error
        if ($null -ne $error) {
            if ($error.Contains('kind')) { $parts += [string]$error['kind'] }
            if ($error.Contains('code') -and -not [string]::IsNullOrEmpty([string]$error['code'])) { $parts += [string]$error['code'] }
        }
    }
    if ($null -ne $metadata -and $metadata.Contains('durationMs')) { $parts += ([string]$metadata['durationMs'] + ' ms') }
    return ('[' + ($parts -join ' - ') + ']')
} -Force

# The compact parameter list a printed tool object shows.
Update-TypeData -TypeName 'DshTool' -MemberType ScriptProperty -MemberName 'ParameterSummary' -Value {
    $schema = $this.InputSchema
    if ($null -eq $schema) { return '(no schema declared)' }
    $properties = $schema['properties']
    if ($null -eq $properties -or $properties.Count -eq 0) { return '(none)' }
    $required = @($schema['required'])
    $parts = @()
    foreach ($key in $properties.Keys) {
        $entry = $properties[$key]
        $type = if ($null -ne $entry -and $entry.Contains('type') -and $null -ne $entry['type']) { [string]$entry['type'] } else { 'any' }
        $parts += ($key + ': ' + $type + $(if ($required -contains $key) { ' (required)' } else { '' }))
    }
    return ($parts -join '; ')
} -Force

# What the tool returns, in one line, taken from its declared return contract.
Update-TypeData -TypeName 'DshTool' -MemberType ScriptProperty -MemberName 'ReturnSummary' -Value {
    $contract = $this.ReturnContract
    if ($null -eq $contract) { return 'no return contract declared' }
    $value = $contract['value']
    $lines = @()
    if ($null -ne $value) {
        if ($value.Contains('text') -and $null -ne $value['text']) { $lines += [string]$value['text'] }
        if ($value.Contains('note') -and $null -ne $value['note']) { $lines += [string]$value['note'] }
        if ($value.Contains('schema') -and $null -ne $value['schema']) { $lines += 'value fields follow the declared output schema (see .OutputSchema)' }
        if ($value.Contains('source') -and [string]$value['source'] -eq 'preset-read-contract') {
            $lines += '.Value.Text is complete for the requested scope; the printed text may be a preview'
        }
    }
    if ($contract.Contains('limits') -and $null -ne $contract['limits']) {
        $limits = $contract['limits']
        if ($limits.Contains('readFullMaxBytes')) { $lines += ('full read limit: ' + [string]$limits['readFullMaxBytes'] + ' bytes') }
        elseif ($limits.Contains('fullReadMaxBytes')) { $lines += ('full read limit: ' + [string]$limits['fullReadMaxBytes'] + ' bytes') }
    }
    return ($lines -join '; ')
} -Force

# One validated usage line, from the tool's own examples when it has any.
Update-TypeData -TypeName 'DshTool' -MemberType ScriptProperty -MemberName 'Usage' -Value {
    $examples = $this.Examples
    if ($null -ne $examples -and $examples.Count -gt 0) {
        $arguments = $examples[0]['arguments']
        if ($null -ne $arguments) {
            $parts = @()
            foreach ($key in $arguments.Keys) {
                $value = $arguments[$key]
                $rendered = if ($value -is [string]) { "'" + ([string]$value).Replace("'", "''") + "'" } else { [string]$value }
                $parts += ($key + ' = ' + $rendered)
            }
            return ('$tool.Invoke(@{ ' + ($parts -join '; ') + ' })')
        }
    }
    return ('$tool.Invoke(@{ ... })')
} -Force

$script:DshCliFormatPath = Join-Path $PSScriptRoot 'DshCli.format.ps1xml'
if (Test-Path -LiteralPath $script:DshCliFormatPath) {
    $known = @(Get-FormatData -TypeName 'DshTool' -ErrorAction SilentlyContinue)
    if ($known.Count -eq 0) { Update-FormatData -PrependPath $script:DshCliFormatPath }
}

# Release the cached loopback client with the module rather than leaking it for
# the life of the shell.
$ExecutionContext.SessionState.Module.OnRemove = {
    if ($null -ne $script:DshCliClient) {
        $script:DshCliClient.Dispose()
        $script:DshCliClient = $null
    }
}

Export-ModuleMember -Function Get-DshTool, Get-DshToolSchema, Invoke-DshTool -Alias dsh-tool
