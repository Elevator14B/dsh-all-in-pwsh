<#
DshCli - the Windows tool entry for dsh-all-in-pwsh.

Every function here talks to the host bridge over HTTP with an explicit UTF-8
JSON body. The per-execution identity (bridge path, call id and capability)
comes from the environment the host writes into this shell before each command
runs; nothing is read back from a shared "current call" file, so a background
process started by an earlier command keeps the identity it inherited and is
refused once that execution ends.

An argument object is validated in its ORIGINAL form and serialized exactly
once, as part of the request envelope. It is never round-tripped through
ConvertFrom-Json, which would collide case-differing dictionary keys and coerce
date-like strings.
#>

# Preferences stay with the caller: a tool failure writes an ErrorRecord that
# the caller can turn into a terminating error with -ErrorAction Stop, and the
# shell itself is never ended by a failed call.

$script:DshCliBridgePath = $null
$script:DshCliBridge = $null
$script:DshCliClient = $null

$script:DshCliMaxDepth = 48

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
        $script:DshCliBridge = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
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

function Invoke-DshCliRpc {
    <#
    .SYNOPSIS
    Send one request to the host bridge and return its parsed reply.

    .DESCRIPTION
    The payload carries the caller's argument object in its original form and is
    serialized exactly ONCE, as the complete request envelope, at an explicit
    depth that accounts for the envelope level.

    Throws for anything that is not an answered request: a missing execution
    identity, an unreachable endpoint, a non-200 status or an unreadable body.
    A tool-level failure is NOT thrown here; it comes back as a reply field so
    the caller can raise it with the tool context intact.
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
        instance   = $bridge.instance
        session    = $session
        call       = $call
        capability = $capability
    }
    foreach ($key in $Payload.Keys) { $envelope[$key] = $Payload[$key] }
    $json = ConvertTo-Json -InputObject $envelope -Depth ($script:DshCliMaxDepth + 2) -Compress

    $uri = 'http://127.0.0.1:' + $bridge.port + '/rpc'
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
    $response = $null
    try {
        $request.Headers.Add('x-dsh-cli-token', [string]$bridge.token)
        $request.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
        $response = (New-DshCliClient).Send($request)
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
    }
    catch [System.Net.Http.HttpRequestException] {
        throw [System.Net.Http.HttpRequestException]::new(
            "The bridge at $uri is unreachable: $($_.Exception.Message). The host that owns this shell is gone or its bridge stopped.", $_.Exception)
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
    }

    if ($status -ne 200) {
        throw [System.InvalidOperationException]::new("The bridge answered HTTP $status for a request it should have accepted: $text")
    }
    try {
        $reply = $text | ConvertFrom-Json
    }
    catch {
        throw [System.InvalidOperationException]::new("The bridge answered with unreadable JSON: $text")
    }
    if ($reply.PSObject.Properties.Name -contains 'error') {
        throw [System.InvalidOperationException]::new([string]$reply.error)
    }
    return $reply
}

function Invoke-DshTool {
    <#
    .SYNOPSIS
    Call any tool mounted in this session from the shell.

    .DESCRIPTION
    Arguments are a PowerShell object, not JSON text: pass a hashtable, an
    ordered dictionary or a PSCustomObject. Omit -Arguments to call a tool that
    takes none. Nested objects, arrays, null, booleans, numbers, Unicode,
    newlines, quotes and backslashes cross the bridge unchanged.

    Without -PassThru the function writes the tool result text. With -PassThru
    it writes a structured response object with these fields:

      Tool        the tool that was called
      Ok          $true when the host answered and the tool succeeded
      IsError     the tool result's own error flag
      Text        the tool result text, exactly as the model would see it
      ErrorKind   $null, 'Protocol' (the bridge refused the request) or 'Tool'
      Error       $null or the failure message
      Call        the host call id this request was bound to
      Instance    the instance that served it
      Session     the session id
      DurationMs  round-trip time in milliseconds

    Failures are raised as PowerShell errors, so -ErrorAction Stop turns any of
    them into a terminating error. Protocol failures and tool failures are
    distinguished by ErrorKind and by the error category.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Position = 1)]
        [object]$Arguments,

        [switch]$PassThru
    )

    $started = [System.Diagnostics.Stopwatch]::StartNew()
    $failure = $null
    $reply = $null
    try {
        $payload = [ordered]@{
            op        = 'call'
            name      = $Name
            arguments = (Test-DshCliArguments -Value $Arguments)
        }
        $reply = Invoke-DshCliRpc -Payload $payload
    }
    catch {
        $failure = [pscustomobject]@{ Kind = 'Protocol'; Message = $_.Exception.Message }
    }
    $started.Stop()

    if ($null -ne $failure) {
        $response = [pscustomobject]@{
            Tool       = $Name
            Ok         = $false
            IsError    = $true
            Text       = ''
            ErrorKind  = 'Protocol'
            Error      = $failure.Message
            Call       = $env:DSH_PWSH_CALL
            Instance   = $env:DSH_PWSH_BRIDGE
            Session    = $env:DSH_SESSION_ID
            DurationMs = [int]$started.ElapsedMilliseconds
        }
    }
    else {
        $response = [pscustomobject]@{
            Tool       = $Name
            Ok         = (-not [bool]$reply.isError)
            IsError    = [bool]$reply.isError
            Text       = [string]$reply.text
            ErrorKind  = $null
            Error      = $null
            Call       = $env:DSH_PWSH_CALL
            Instance   = (Get-DshCliBridge).instance
            Session    = $env:DSH_SESSION_ID
            DurationMs = [int]$started.ElapsedMilliseconds
        }
        if ($response.IsError) {
            $response.ErrorKind = 'Tool'
            $response.Error = $response.Text
        }
    }

    if ($PassThru) { $response }

    if ($response.IsError) {
        $category = [System.Management.Automation.ErrorCategory]::InvalidResult
        if ($response.ErrorKind -eq 'Protocol') { $category = [System.Management.Automation.ErrorCategory]::ConnectionError }
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new($response.Error),
            "DshTool.$($response.ErrorKind)",
            $category,
            $Name)
        $PSCmdlet.WriteError($record)
        return
    }

    if (-not $PassThru) { $response.Text }
}

function Get-DshTool {
    <#
    .SYNOPSIS
    List every tool the bridge can run in this session.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param()

    $reply = Invoke-DshCliRpc -Payload ([ordered]@{ op = 'list' })
    foreach ($tool in $reply.tools) {
        [pscustomobject]@{ Name = [string]$tool.name; Description = [string]$tool.description }
    }
}

function Get-DshToolSchema {
    <#
    .SYNOPSIS
    Print one tool's exact JSON parameter schema.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $reply = Invoke-DshCliRpc -Payload ([ordered]@{ op = 'describe'; name = $Name })
    return (ConvertTo-Json -InputObject $reply.schema -Depth $script:DshCliMaxDepth)
}

Set-Alias -Name dsh-tool -Value Invoke-DshTool -Force

# Release the cached loopback client with the module rather than leaking it for
# the life of the shell.
$ExecutionContext.SessionState.Module.OnRemove = {
    if ($null -ne $script:DshCliClient) {
        $script:DshCliClient.Dispose()
        $script:DshCliClient = $null
    }
}

Export-ModuleMember -Function Invoke-DshTool, Get-DshTool, Get-DshToolSchema -Alias dsh-tool
