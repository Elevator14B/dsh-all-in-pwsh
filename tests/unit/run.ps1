<#
.SYNOPSIS
Account-free checks for dsh-all-in-pwsh.

.DESCRIPTION
Module argument fidelity, the argument types the module must reject, the
installer contract (default home, absolute paths, ownership, update/uninstall
safety, staging), and repository hygiene. Runs without a DSH host, a model or
network access. Checks that need the real DSH runtime live in ../integration.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'preset\plugin\DshCli.psm1'
$installer = Join-Path $repoRoot 'install.ps1'

$script:failures = @()
function Assert-That {
    param([string]$Name, [bool]$Condition, $Detail)
    if ($Condition) { Write-Host ('PASS  ' + $Name); return }
    Write-Host ('FAIL  ' + $Name)
    if ($null -ne $Detail) { Write-Host ('      ' + ([string]$Detail).Trim()) }
    $script:failures += $Name
}

# Every scratch root is created under the process temp path and re-checked
# before it is removed, so a bad path can never turn a test into a deletion.
$script:tempRoots = @()
function New-CheckedTempRoot {
    param([string]$Label)
    $base = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $root = Join-Path $base ('dsh-all-in-pwsh-' + $Label + '-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Assert-That ('temp.root_is_under_temp_path:' + $Label) ($root.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) $root
    $script:tempRoots += $root
    return $root
}
function Remove-CheckedTempRoot {
    param([string]$Root)
    $base = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $Root.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove the temp root $Root (outside $base)"
    }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- module argument fidelity ------------------------------------------------
$module = Import-Module $modulePath -Force -PassThru
# The reply echoes the arguments back as the tool value, so the round trip
# proves BOTH directions: what left as PowerShell arguments, and what the
# result object holds after decoding.
$fidelity = & $module {
    function Invoke-DshCliRpc {
        param($Payload)
        $reply = @{ ok = $true; hasValue = $true;
            valueJson = (ConvertTo-Json -InputObject $Payload['arguments'] -Depth 50 -Compress)
            displayText = ''; content = @(); error = $null; metadata = @{ tool = 'echo'; outcome = 'settled' } }
        ConvertFrom-DshJson -Json (ConvertTo-Json -InputObject $reply -Depth 60 -Compress)
    }
    function Get-DshCliBridge { @{ instance = 'unit-test' } }

    $caseSensitive = @{ nested = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal) }
    $caseSensitive.nested.Add('a', 1)
    $caseSensitive.nested.Add('A', 2)
    $results = [ordered]@{}
    foreach ($pair in @(
        @{ name = 'case-key'; value = $caseSensitive },
        @{ name = 'iso-date-string'; value = @{ content = '2026-09-17T23:35:11.1234567+08:00' } },
        @{ name = 'empty-key'; value = @{ '' = 'blank' } },
        @{ name = 'unicode'; value = @{ text = '中文 " quote ' + [char]96 + ' tick & (paren)' } }
    )) {
        try { $results[$pair.name] = (Invoke-DshTool echo $pair.value -PassThru -ErrorAction Stop).Value }
        catch { $results[$pair.name] = 'ERROR: ' + $_.Exception.Message }
    }
    $results
}
$caseKeys = $fidelity['case-key']['nested']
Assert-That 'module.case_sensitive_keys_survive' ($caseKeys.Contains('a') -and $caseKeys.Contains('A') -and [int]$caseKeys['a'] -eq 1 -and [int]$caseKeys['A'] -eq 2) (ConvertTo-Json -InputObject $fidelity['case-key'] -Depth 10 -Compress)
$isoValue = $fidelity['iso-date-string']['content']
Assert-That 'module.date_like_string_stays_string' (($isoValue -is [string]) -and $isoValue -eq '2026-09-17T23:35:11.1234567+08:00') ([string]$isoValue)
Assert-That 'module.empty_key_survives' ($fidelity['empty-key'].Contains('') -and $fidelity['empty-key'][''] -eq 'blank') (ConvertTo-Json -InputObject $fidelity['empty-key'] -Depth 10 -Compress)
Assert-That 'module.unicode_survives' ($fidelity['unicode']['text'] -eq ('中文 " quote ' + [char]96 + ' tick & (paren)')) (ConvertTo-Json -InputObject $fidelity['unicode'] -Depth 10 -Compress)

$rejections = & $module {
    $out = [ordered]@{}
    foreach ($pair in @(
        @{ name = 'datetime'; value = @{ when = (Get-Date) } },
        @{ name = 'timespan'; value = @{ span = [System.TimeSpan]::FromSeconds(1) } },
        @{ name = 'enum'; value = @{ day = [System.DayOfWeek]::Monday } },
        @{ name = 'non-string-key'; value = @{ map = @{ 1 = 'one' } } },
        @{ name = 'scriptblock'; value = @{ code = { 1 } } }
    )) {
        try { $null = Invoke-DshTool echo $pair.value -PassThru -ErrorAction Stop; $out[$pair.name] = 'NO-ERROR' }
        catch { $out[$pair.name] = $_.Exception.Message }
    }
    $cycle = @{}
    $cycle.self = $cycle
    try { $null = Invoke-DshTool echo $cycle -PassThru -ErrorAction Stop; $out['cycle'] = 'NO-ERROR' } catch { $out['cycle'] = $_.Exception.Message }
    $deep = @{ leaf = 'end' }
    for ($level = 0; $level -lt 60; $level = $level + 1) { $deep = @{ next = $deep } }
    try { $null = Invoke-DshTool echo $deep -PassThru -ErrorAction Stop; $out['depth'] = 'NO-ERROR' } catch { $out['depth'] = $_.Exception.Message }
    $out
}
Assert-That 'module.rejects_datetime' ($rejections['datetime'] -like '*ISO-8601*') $rejections['datetime']
Assert-That 'module.rejects_timespan' ($rejections['timespan'] -like '*TimeSpan*') $rejections['timespan']
Assert-That 'module.rejects_enum' ($rejections['enum'] -like '*enum*') $rejections['enum']
Assert-That 'module.rejects_non_string_key' ($rejections['non-string-key'] -like '*keys must be strings*') $rejections['non-string-key']
Assert-That 'module.rejects_scriptblock' ($rejections['scriptblock'] -like '*ScriptBlock*') $rejections['scriptblock']
Assert-That 'module.rejects_cycle' ($rejections['cycle'] -like '*cycle*') $rejections['cycle']
Assert-That 'module.rejects_depth' ($rejections['depth'] -like '*maximum JSON depth*') $rejections['depth']

# --- envelope depth accounting ----------------------------------------------
# The argument root is level 1 and the module allows 48 levels, so a chain of 46
# nested objects keeps its leaf inside the budget and must arrive whole, while
# one more level must be refused. The envelope adds its own level on the wire.
$depthBudget = & $module {
    function Invoke-DshCliRpc {
        param($Payload)
        $reply = @{ ok = $true; hasValue = $true;
            valueJson = (ConvertTo-Json -InputObject $Payload['arguments'] -Depth 50 -Compress)
            displayText = ''; content = @(); error = $null; metadata = @{ tool = 'echo'; outcome = 'settled' } }
        ConvertFrom-DshJson -Json (ConvertTo-Json -InputObject $reply -Depth 60 -Compress)
    }
    function Get-DshCliBridge { @{ instance = 'unit-test' } }
    $allowed = @{ leaf = 'bottom' }
    for ($level = 0; $level -lt 46; $level = $level + 1) { $allowed = @{ next = $allowed } }
    $rejectedValue = @{ next = $allowed }
    $out = [ordered]@{}
    try { $out['allowed'] = (Invoke-DshTool echo $allowed -PassThru -ErrorAction Stop).Value }
    catch { $out['allowed'] = 'ERROR: ' + $_.Exception.Message }
    try { $null = Invoke-DshTool echo $rejectedValue -PassThru -ErrorAction Stop; $out['rejected'] = 'NO-ERROR' }
    catch { $out['rejected'] = $_.Exception.Message }
    $out
}
$cursor = $depthBudget['allowed']
$nextCount = 0
while ($null -ne $cursor -and $cursor -is [System.Collections.IDictionary] -and $cursor.Contains('next')) { $cursor = $cursor['next']; $nextCount += 1 }
Assert-That 'module.depth_budget_serializes_the_limit' ($nextCount -eq 46 -and $cursor['leaf'] -eq 'bottom') ('next-count=' + $nextCount)
Assert-That 'module.depth_budget_rejects_one_more' ($depthBudget['rejected'] -like '*maximum JSON depth*') $depthBudget['rejected']
Remove-Module $module -ErrorAction SilentlyContinue

# --- installer ---------------------------------------------------------------
$root = New-CheckedTempRoot -Label 'installer'
try {
    $presetId = 'dsh-all-in-pwsh'
    $presetRoot = Join-Path $root '.agent-presets'
    $target = Join-Path $presetRoot $presetId

    $null = & $installer -DshHome $root -PresetId $presetId
    $composition = Get-Content -LiteralPath (Join-Path $target 'agent.cordis.yml') -Raw
    $bootstrap = Join-Path $target 'plugin\bootstrap.ps1'
    Assert-That 'installer.creates_composition' (Test-Path -LiteralPath (Join-Path $target 'agent.cordis.yml'))
    Assert-That 'installer.substitutes_bootstrap' ($composition.Contains($bootstrap) -and -not $composition.Contains('__DSH_ALL_IN_PWSH_BOOTSTRAP__')) ($composition -split [char]10 | Select-String -Pattern 'bootstrap' | Select-Object -First 1)
    Assert-That 'installer.bootstrap_path_is_absolute' ($composition -like ('*' + $root + '*')) $bootstrap
    $marker = Get-Content -LiteralPath (Join-Path $target '.installed.json') -Raw | ConvertFrom-Json
    Assert-That 'installer.marker_states_product_identity' ($marker.product -eq 'dsh-all-in-pwsh' -and [int]$marker.schema -eq 1 -and $marker.presetId -eq $presetId) $marker
    Assert-That 'installer.ships_no_legacy_client' (-not (Test-Path -LiteralPath (Join-Path $target 'plugin\dsh-tool.mjs')) -and -not (Test-Path -LiteralPath (Join-Path $target 'plugin\dsh-tool.cmd')))

    $null = & $installer -DshHome $root -PresetId $presetId
    Assert-That 'installer.is_idempotent' (Test-Path -LiteralPath (Join-Path $target 'agent.cordis.yml'))

    # A relative home must still produce an absolute bootstrap path.
    $relativeRoot = New-CheckedTempRoot -Label 'relative'
    try {
        Push-Location $relativeRoot
        try { $null = & $installer -DshHome 'relative-home' -PresetId 'relative-preset' }
        finally { Pop-Location }
        $relativeComposition = Get-Content -LiteralPath (Join-Path $relativeRoot 'relative-home\.agent-presets\relative-preset\agent.cordis.yml') -Raw
        $relativeBootstrap = [regex]::Match($relativeComposition, 'plugin.bootstrap\.ps1').Value
        Assert-That 'installer.relative_home_becomes_absolute' ($relativeComposition -like ('*' + $relativeRoot + '*') -and [System.IO.Path]::IsPathRooted((Join-Path $relativeRoot 'relative-home'))) $relativeBootstrap
    }
    finally { Remove-CheckedTempRoot -Root $relativeRoot }

    # A foreign directory is never claimed or overwritten without -Force.
    $foreign = Join-Path $presetRoot 'foreign'
    New-Item -ItemType Directory -Force -Path $foreign | Out-Null
    Set-Content -LiteralPath (Join-Path $foreign 'keep.txt') -Value 'mine'
    $refused = $false
    try { $null = & $installer -DshHome $root -PresetId 'foreign' } catch { $refused = $true }
    Assert-That 'installer.protects_foreign_directory' ($refused -and (Test-Path -LiteralPath (Join-Path $foreign 'keep.txt')))

    # A marker that is JSON but not ours does not grant ownership.
    Set-Content -LiteralPath (Join-Path $foreign '.installed.json') -Value '{"hello":"world"}'
    $refusedUninstall = $false
    try { $null = & $installer -DshHome $root -PresetId 'foreign' -Uninstall } catch { $refusedUninstall = $true }
    Assert-That 'installer.rejects_foreign_marker' ($refusedUninstall -and (Test-Path -LiteralPath (Join-Path $foreign 'keep.txt')))

    # A user file inside our own installation survives an update as a backup.
    Set-Content -LiteralPath (Join-Path $target 'mine.txt') -Value 'user data'
    $null = & $installer -DshHome $root -PresetId $presetId
    $backups = @(Get-ChildItem -LiteralPath $presetRoot -Directory -Filter ($presetId + '.backup-*'))
    $preserved = @($backups | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'mine.txt') })
    Assert-That 'installer.update_preserves_user_files' ($preserved.Count -ge 1 -and -not (Test-Path -LiteralPath (Join-Path $target 'mine.txt'))) ($backups | ForEach-Object { $_.Name })

    # A modified file is preserved on uninstall too.
    Set-Content -LiteralPath (Join-Path $target 'preset.yml') -Value 'name: edited by user'
    $null = & $installer -DshHome $root -PresetId $presetId -Uninstall
    $afterUninstall = @(Get-ChildItem -LiteralPath $presetRoot -Directory -Filter ($presetId + '.backup-*') | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'preset.yml') })
    Assert-That 'installer.uninstall_preserves_modified_files' ((-not (Test-Path -LiteralPath $target)) -and $afterUninstall.Count -ge 1) ($afterUninstall | ForEach-Object { $_.Name })

    # A broken bundle must fail before the working installation is touched.
    $brokenRoot = New-CheckedTempRoot -Label 'broken'
    try {
        $brokenInstaller = Join-Path $brokenRoot 'install.ps1'
        Copy-Item -LiteralPath $installer -Destination $brokenInstaller
        Copy-Item -Path (Join-Path $repoRoot 'preset') -Destination (Join-Path $brokenRoot 'preset') -Recurse
        Remove-Item -LiteralPath (Join-Path $brokenRoot 'preset\plugin\DshCli.psm1') -Force
        $null = & $installer -DshHome $root -PresetId $presetId
        $beforeText = Get-Content -LiteralPath (Join-Path $target 'agent.cordis.yml') -Raw
        $stagingFailed = $false
        try { $null = & $brokenInstaller -DshHome $root -PresetId $presetId } catch { $stagingFailed = $true }
        $afterText = Get-Content -LiteralPath (Join-Path $target 'agent.cordis.yml') -Raw
        $strayStaging = @(Get-ChildItem -LiteralPath $presetRoot -Directory -Force | Where-Object { $_.Name -like '.dsh-all-in-pwsh.staging-*' })
        Assert-That 'installer.broken_bundle_leaves_installation_intact' ($stagingFailed -and $beforeText -eq $afterText -and $strayStaging.Count -eq 0) ('failed=' + $stagingFailed + ' stray=' + $strayStaging.Count)
    }
    finally { Remove-CheckedTempRoot -Root $brokenRoot }

    # Two updates in the same second must leave two backups. A timestamp-only
    # name makes Move-Item nest the second inside the first.
    $backupRoot = New-CheckedTempRoot -Label 'backups'
    try {
        $backupId = 'bk'
        $backupTarget = Join-Path (Join-Path $backupRoot '.agent-presets') $backupId
        $null = & $installer -DshHome $backupRoot -PresetId $backupId
        $reported = @()
        foreach ($name in @('mine-a.txt', 'mine-b.txt')) {
            Set-Content -LiteralPath (Join-Path $backupTarget $name) -Value $name
            $output = (& $installer -DshHome $backupRoot -PresetId $backupId *>&1) -join [char]10
            $reported += @([regex]::Matches($output, [regex]::Escape($backupId) + '\.backup-\d{14}-[0-9a-f]{8}') | ForEach-Object { $_.Value })
        }
        $distinct = @($reported | Sort-Object -Unique)
        Assert-That 'installer.same_second_backups_are_distinct' ($reported.Count -eq 2 -and $distinct.Count -eq 2) ($reported -join ', ')
        $carried = @()
        foreach ($name in $distinct) {
            $dir = Join-Path (Join-Path $backupRoot '.agent-presets') $name
            $present = @(@('mine-a.txt', 'mine-b.txt') | Where-Object { Test-Path -LiteralPath (Join-Path $dir $_) })
            $nested = Test-Path -LiteralPath (Join-Path $dir $backupId)
            if ($present.Count -eq 1 -and (-not $nested)) { $carried += $present[0] }
        }
        $allCarried = (@($carried | Sort-Object -Unique).Count -eq 2)
        Assert-That 'installer.backups_are_independently_readable' ($distinct.Count -eq 2 -and $allCarried) ('carried=' + ($carried -join ',') + ' distinct=' + $distinct.Count)
    }
    finally { Remove-CheckedTempRoot -Root $backupRoot }

    # A home whose path needs YAML quoting: spaces, CJK and an apostrophe. The
    # apostrophe is doubled inside the single-quoted YAML scalar, which is also
    # what the staged validation must compare against.
    $quotedRoot = New-CheckedTempRoot -Label 'quoted'
    try {
        $quotedHome = Join-Path $quotedRoot "O'Brien 中文 home"
        $quotedTarget = Join-Path (Join-Path $quotedHome '.agent-presets') 'quoted'
        $quotedBootstrap = Join-Path $quotedTarget 'plugin\bootstrap.ps1'
        $quotedError = $null
        try { $null = & $installer -DshHome $quotedHome -PresetId 'quoted' } catch { $quotedError = $_.Exception.Message }
        $quotedInstalled = Test-Path -LiteralPath (Join-Path $quotedTarget 'plugin\DshCli.psm1')
        Assert-That 'installer.installs_under_apostrophe_path' ($null -eq $quotedError -and $quotedInstalled) ([string]$quotedError)
        $rowMatch = [regex]::Match('', '^$')
        if ($quotedInstalled) {
            $quotedComposition = Get-Content -LiteralPath (Join-Path $quotedTarget 'agent.cordis.yml') -Raw
            $row = @($quotedComposition -split [char]10 | Where-Object { $_ -like '*bootstrap.ps1*' })
            $rowMatch = [regex]::Match([string]$row[0], "^\s*- '(?<value>.*)'\s*$")
        }
        $roundTripped = ([string]$rowMatch.Groups['value'].Value).Replace("''", "'")
        Assert-That 'installer.bootstrap_row_round_trips_yaml_quotes' ($rowMatch.Success -and $roundTripped -eq $quotedBootstrap) ('row=' + [string]$rowMatch.Value)
    }
    finally { Remove-CheckedTempRoot -Root $quotedRoot }

    # A swap that fails must put the previous installation back.
    $swapRoot = New-CheckedTempRoot -Label 'swap'
    try {
        $null = & $installer -DshHome $swapRoot -PresetId 'swap-id'
        $swapTarget = Join-Path (Join-Path $swapRoot '.agent-presets') 'swap-id'
        $beforeComposition = Get-Content -LiteralPath (Join-Path $swapTarget 'agent.cordis.yml') -Raw
        $beforeMarker = Get-Content -LiteralPath (Join-Path $swapTarget '.installed.json') -Raw
        $savedHook = $env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP
        $swapFailed = $false
        try {
            $env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP = '1'
            try { $null = & $installer -DshHome $swapRoot -PresetId 'swap-id' } catch { $swapFailed = $true }
        }
        finally {
            if ($null -eq $savedHook) { Remove-Item Env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP -ErrorAction SilentlyContinue }
            else { $env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP = $savedHook }
        }
        $leftovers = @(Get-ChildItem -LiteralPath (Join-Path $swapRoot '.agent-presets') -Directory -Force | Where-Object { $_.Name -like '.dsh-all-in-pwsh.*' })
        $restored = (Test-Path -LiteralPath (Join-Path $swapTarget 'agent.cordis.yml')) -and
            ((Get-Content -LiteralPath (Join-Path $swapTarget 'agent.cordis.yml') -Raw) -eq $beforeComposition) -and
            ((Get-Content -LiteralPath (Join-Path $swapTarget '.installed.json') -Raw) -eq $beforeMarker)
        Assert-That 'installer.failed_swap_restores_installation' ($swapFailed -and $restored -and $leftovers.Count -eq 0) ('failed=' + $swapFailed + ' restored=' + $restored + ' leftovers=' + (($leftovers | ForEach-Object { $_.Name }) -join ','))
    }
    finally { Remove-CheckedTempRoot -Root $swapRoot }

    # The same must hold when the old installation carries user changes: they are
    # kept as a backup only after the new installation is in place.
    $modifiedRoot = New-CheckedTempRoot -Label 'swap-modified'
    try {
        $modifiedId = 'swap-modified'
        $null = & $installer -DshHome $modifiedRoot -PresetId $modifiedId
        $modifiedTarget = Join-Path (Join-Path $modifiedRoot '.agent-presets') $modifiedId
        Set-Content -LiteralPath (Join-Path $modifiedTarget 'mine.txt') -Value 'user data'
        Set-Content -LiteralPath (Join-Path $modifiedTarget 'preset.yml') -Value 'name: edited by user'
        $modifiedBefore = @(Get-ChildItem -LiteralPath $modifiedTarget -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($modifiedTarget.Length + 1) + '=' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        $savedHook = $env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP
        $modifiedFailed = $false
        try {
            $env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP = '1'
            try { $null = & $installer -DshHome $modifiedRoot -PresetId $modifiedId } catch { $modifiedFailed = $true }
        }
        finally {
            if ($null -eq $savedHook) { Remove-Item Env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP -ErrorAction SilentlyContinue }
            else { $env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP = $savedHook }
        }
        $modifiedAfter = @(Get-ChildItem -LiteralPath $modifiedTarget -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($modifiedTarget.Length + 1) + '=' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        $modifiedLeftovers = @(Get-ChildItem -LiteralPath (Join-Path $modifiedRoot '.agent-presets') -Directory -Force | Where-Object { $_.Name -like '.dsh-all-in-pwsh.*' })
        Assert-That 'installer.failed_swap_restores_modified_install' ($modifiedFailed -and ($modifiedBefore -join '|') -eq ($modifiedAfter -join '|') -and $modifiedLeftovers.Count -eq 0) ('failed=' + $modifiedFailed + ' files=' + $modifiedAfter.Count + '/' + $modifiedBefore.Count + ' leftovers=' + (($modifiedLeftovers | ForEach-Object { $_.Name }) -join ','))

        # Nothing was installed, so the update path must still report the backup
        # only once it really has one.
        $modifiedRetry = (& $installer -DshHome $modifiedRoot -PresetId $modifiedId *>&1) -join [char]10
        $modifiedBackups = @(Get-ChildItem -LiteralPath (Join-Path $modifiedRoot '.agent-presets') -Directory -Filter ($modifiedId + '.backup-*'))
        Assert-That 'installer.retry_after_a_failed_swap_keeps_user_files' (($modifiedBackups | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'mine.txt') }).Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $modifiedTarget 'mine.txt'))) (($modifiedBackups | ForEach-Object { $_.Name }) -join ',')
    }
    finally { Remove-CheckedTempRoot -Root $modifiedRoot }

    # And when a foreign directory is replaced with -Force it must come back too,
    # with every file it had, and no preset installed.
    $forcedRoot = New-CheckedTempRoot -Label 'swap-forced'
    try {
        $forcedTarget = Join-Path (Join-Path $forcedRoot '.agent-presets') 'foreign-forced'
        New-Item -ItemType Directory -Force -Path (Join-Path $forcedTarget 'nested') | Out-Null
        Set-Content -LiteralPath (Join-Path $forcedTarget 'keep.txt') -Value 'mine'
        Set-Content -LiteralPath (Join-Path $forcedTarget 'nestedmore.txt') -Value 'still mine'
        $forcedBefore = @(Get-ChildItem -LiteralPath $forcedTarget -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($forcedTarget.Length + 1) + '=' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        $savedHook = $env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP
        $forcedFailed = $false
        try {
            $env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP = '1'
            try { $null = & $installer -DshHome $forcedRoot -PresetId 'foreign-forced' -Force } catch { $forcedFailed = $true }
        }
        finally {
            if ($null -eq $savedHook) { Remove-Item Env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP -ErrorAction SilentlyContinue }
            else { $env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP = $savedHook }
        }
        $forcedAfter = @(Get-ChildItem -LiteralPath $forcedTarget -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($forcedTarget.Length + 1) + '=' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        $forcedLeftovers = @(Get-ChildItem -LiteralPath (Join-Path $forcedRoot '.agent-presets') -Directory -Force | Where-Object { $_.Name -like '.dsh-all-in-pwsh.*' -or $_.Name -like 'foreign-forced.backup-*' })
        Assert-That 'installer.failed_swap_restores_forced_foreign_directory' ($forcedFailed -and -not (Test-Path -LiteralPath (Join-Path $forcedTarget '.installed.json')) -and ($forcedBefore -join '|') -eq ($forcedAfter -join '|') -and $forcedLeftovers.Count -eq 0) ('failed=' + $forcedFailed + ' files=' + $forcedAfter.Count + '/' + $forcedBefore.Count + ' leftovers=' + (($forcedLeftovers | ForEach-Object { $_.Name }) -join ','))
    }
    finally { Remove-CheckedTempRoot -Root $forcedRoot }

    # A reparse point on the destination path is refused before anything is
    # created through it: the old order created the preset root first.
    $junctionRoot = New-CheckedTempRoot -Label 'junction'
    try {
        $realDir = Join-Path $junctionRoot 'real'
        $linkDir = Join-Path $junctionRoot 'link'
        New-Item -ItemType Directory -Force -Path $realDir | Out-Null
        New-Item -ItemType Junction -Path $linkDir -Target $realDir | Out-Null
        $junctionRefused = $false
        try { $null = & $installer -DshHome $linkDir -PresetId 'junction-preset' } catch { $junctionRefused = $true }
        $createdThroughLink = Test-Path -LiteralPath (Join-Path $realDir '.agent-presets')
        Assert-That 'installer.rejects_reparse_home_before_creating' ($junctionRefused -and (-not $createdThroughLink)) ('refused=' + $junctionRefused + ' created=' + $createdThroughLink)
    }
    finally { Remove-CheckedTempRoot -Root $junctionRoot }

    # The default branch: no -DshHome and no DSH_HOME falls back to the profile.
    $defaultHome = New-CheckedTempRoot -Label 'default-home'
    try {
        $savedDshHome = $env:DSH_HOME
        $savedProfile = $env:USERPROFILE
        try {
            Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue
            $env:USERPROFILE = $defaultHome
            $null = & $installer -PresetId 'default-branch'
        }
        finally {
            $env:USERPROFILE = $savedProfile
            if ($null -ne $savedDshHome) { $env:DSH_HOME = $savedDshHome }
        }
        Assert-That 'installer.default_branch_uses_user_profile' (Test-Path -LiteralPath (Join-Path $defaultHome '.dsh\.agent-presets\default-branch\agent.cordis.yml'))
        $null = & $installer -PresetId 'default-branch' -Uninstall -DshHome (Join-Path $defaultHome '.dsh')
        Assert-That 'installer.default_branch_uninstall' (-not (Test-Path -LiteralPath (Join-Path $defaultHome '.dsh\.agent-presets\default-branch')))
    }
    finally { Remove-CheckedTempRoot -Root $defaultHome }
}
finally { Remove-CheckedTempRoot -Root $root }

# --- tool and result objects --------------------------------------------------
# The object surface is deterministic without a host: the bridge request is
# mocked inside the module scope, so these checks exercise the real decoder,
# result shaping, method surface, error policy and handle rules.
$module = Import-Module $modulePath -Force -PassThru
$objectModel = & $module {
    $script:savedSession = $env:DSH_SESSION_ID
    $env:DSH_SESSION_ID = 'unit-session'
    $script:rpcCalls = 0
    $script:replyMode = 'success'
    $script:toolDetail = @{
        name = 'read'
        summary = 'Read a UTF-8 text file.'
        description = 'Read a UTF-8 text file and return line-numbered content.'
        inputSchema = @{ type = 'object'; properties = [ordered]@{ file_path = @{ type = 'string' }; offset = @{ type = 'number' } }; required = @('file_path') }
        outputSchema = @{ type = 'object' }
        returnContract = @{ value = @{ source = 'preset-read-contract'; text = 'the complete decoded text of the requested scope' }; limits = @{ readFullMaxBytes = 8388608 } }
        examples = @(@{ arguments = @{ file_path = 'orders.json' }; note = 'preview' })
        definitionVersion = 'v1'
    }
    function Get-DshCliBridge { @{ instance = 'unit-test'; port = 1; token = 'x' } }
    function Invoke-DshCliRpc {
        param($Payload)
        $script:rpcCalls = $script:rpcCalls + 1
        if ($Payload['op'] -eq 'list') {
            $tools = @(@{ name = 'read'; summary = 'Read a UTF-8 text file.' }, @{ name = 'write'; summary = 'Write a file.' })
            return ConvertFrom-DshJson -Json (ConvertTo-Json -InputObject @{ tools = $tools } -Depth 20 -Compress)
        }
        if ($Payload['op'] -eq 'get') {
            $tools = @()
            foreach ($requested in $Payload['names']) {
                $detail = @{} + $script:toolDetail
                $detail['name'] = $requested
                $tools += $detail
            }
            return ConvertFrom-DshJson -Json (ConvertTo-Json -InputObject @{ tools = $tools } -Depth 20 -Compress)
        }
        switch ($script:replyMode) {
            'failure' {
                $reply = @{ ok = $false; hasValue = $false; valueJson = $null; displayText = 'Error: cannot read missing.txt: not found'; content = @()
                    error = @{ kind = 'Tool'; code = 'FS_NOT_FOUND'; message = 'cannot read missing.txt: not found'; tool = 'read'; parameterPath = $null }
                    metadata = @{ tool = 'read'; callId = 'c1:cli:1'; outcome = 'settled'; durationMs = 4 } }
            }
            'drift' {
                $reply = @{ ok = $false; hasValue = $false; valueJson = $null; displayText = ''; content = @()
                    error = @{ kind = 'DefinitionChanged'; code = 'TOOL_DEFINITION_CHANGED'; message = 'the definition changed after this tool object was created; run Refresh() before calling it'; tool = 'read'; parameterPath = $null }
                    metadata = @{ tool = 'read'; callId = 'c1:cli:1'; outcome = 'not-executed'; durationMs = 1 } }
            }
            'refusal' { return ConvertFrom-DshJson -Json '{"error":"the capability does not match the call in flight","code":"IDENTITY_REVOKED"}' }
            'blocks-0' {
                $reply = @{ ok = $true; hasValue = $true; valueJson = 'null'; displayText = 'no blocks'; content = @(); error = $null; metadata = @{ tool = 'probe'; outcome = 'settled' } }
            }
            'blocks-1' {
                $reply = @{ ok = $true; hasValue = $true; valueJson = 'null'; displayText = 'one block'; content = @(@{ type = 'text'; text = 'ONE-BLOCK' }); error = $null; metadata = @{ tool = 'probe'; outcome = 'settled' } }
            }
            'blocks-2' {
                $reply = @{ ok = $true; hasValue = $true; valueJson = 'null'; displayText = 'two blocks'; content = @(@{ type = 'text'; text = 'FIRST-BLOCK' }, @{ type = 'text'; text = 'SECOND-BLOCK' }); error = $null; metadata = @{ tool = 'probe'; outcome = 'settled' } }
            }
            'blocks-large' {
                $reply = @{ ok = $true; hasValue = $true; valueJson = 'null'; displayText = ('L' * 20000); content = @(@{ type = 'text'; text = ('T' * 20000) }); error = $null; metadata = @{ tool = 'probe'; outcome = 'settled' } }
            }
            'friendly' {
                $reply = @{ ok = $true; hasValue = $true
                    valueJson = (ConvertTo-Json -InputObject @{ text = 'declared lower-case key'; totalLines = 3; path = 'orders.json'; nothing = $null } -Depth 10 -Compress)
                    displayText = 'friendly'; content = @(); error = $null; metadata = @{ tool = 'read'; outcome = 'settled'; durationMs = 1 } }
            }
            default {
                $value = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
                $value.Add('a', 1)
                $value.Add('A', 2)
                $value.Add('iso', '2026-09-17T23:35:11.1234567+08:00')
                $value.Add('nothing', $null)
                $value.Add('empty', @())
                $value.Add('one', @(7))
                $value.Add('big', [int64]9007199254740993)
                $value.Add('nested', @{ inner = @('x', $null, $true) })
                $value.Add('text', 'declared lower-case key')
                $reply = @{ ok = $true; hasValue = $true; valueJson = (ConvertTo-Json -InputObject $value -Depth 20 -Compress)
                    displayText = ('content line' + [char]10 + '[preview]'); content = @(@{ type = 'text'; text = 'content line' })
                    error = $null; metadata = @{ tool = 'read'; callId = 'c1:cli:1'; outcome = 'settled'; durationMs = 9 } }
            }
        }
        return ConvertFrom-DshJson -Json (ConvertTo-Json -InputObject $reply -Depth 20 -Compress)
    }

    $out = [ordered]@{}
    $catalog = @(Get-DshTool)
    $out['catalogCount'] = $catalog.Count
    $out['catalogType'] = $catalog[0].GetType().Name
    $out['catalogSummary'] = $catalog[0].Summary
    $out['catalogHasNoCallMethod'] = (@($catalog[0] | Get-Member -MemberType Method | Where-Object { $_.Name -in @('Invoke', 'TryInvoke', 'Refresh') }).Count -eq 0)

    $tool = Get-DshTool -Name read
    $rpcAfterGet = $script:rpcCalls
    $methodNames = @($tool | Get-Member -MemberType Method | ForEach-Object { $_.Name })
    $out['toolType'] = $tool.GetType().Name
    $out['hasAllMethods'] = ($methodNames -contains 'Invoke') -and ($methodNames -contains 'TryInvoke') -and ($methodNames -contains 'Refresh')
    $out['parameterSummary'] = $tool.ParameterSummary
    $out['returnSummary'] = $tool.ReturnSummary
    $out['usage'] = $tool.Usage
    $null = $tool.Name; $null = $tool.Summary; $null = $tool.Description; $null = $tool.InputSchema
    $null = $tool.OutputSchema; $null = $tool.ReturnContract; $null = $tool.Examples; $null = $tool.DefinitionVersion
    $null = $tool.ParameterSummary; $null = $tool.ReturnSummary; $null = $tool.Usage
    $out['rpcAfterGet'] = $rpcAfterGet
    $out['rpcAfterPropertyReads'] = $script:rpcCalls

    $result = $tool.Invoke(@{ file_path = 'orders.json' })
    $out['ok'] = $result.Ok
    $out['hasValue'] = $result.HasValue
    $out['caseUpper'] = $result.Value['A']
    $out['caseLower'] = $result.Value['a']
    $out['isoIsString'] = ($result.Value['iso'] -is [string])
    $out['isoValue'] = [string]$result.Value['iso']
    $out['nullPresent'] = ($result.Value.Contains('nothing')) -and ($null -eq $result.Value['nothing'])
    $out['absentMissing'] = -not $result.Value.Contains('absent')
    $out['emptyArrayCount'] = @($result.Value['empty']).Count
    $out['emptyArrayIsArray'] = ($result.Value['empty'] -is [array])
    $out['oneArrayCount'] = @($result.Value['one']).Count
    $out['bigInt'] = $result.Value['big']
    $out['nestedNull'] = ($null -eq $result.Value['nested']['inner'][1])
    # Property access reads a declared key regardless of case - that is how the
    # documented $result.Value.Text works - as long as the object has no keys
    # that differ only by case. Such an object keeps both keys and switches to
    # exact lookup, which the case assertions above cover.
    $script:replyMode = 'friendly'
    $friendly = $tool.Invoke(@{ file_path = 'orders.json' })
    $out['declaredKeyByProperty'] = $friendly.Value.Text
    $out['declaredKeyByIndex'] = $friendly.Value['text']
    $out['friendlyKeyLookupByOtherCase'] = $friendly.Value.Contains('TEXT')
    $out['friendlyNullPresent'] = $friendly.Value.Contains('nothing') -and ($null -eq $friendly.Value['nothing'])
    $script:replyMode = 'success'
    $out['displayText'] = $result.DisplayText
    $out['textAlias'] = $result.Text
    $out['errorIsNull'] = ($null -eq $result.Error)
    $out['statusLine'] = $result.StatusLine
    $out['metadataTool'] = $result.Metadata['tool']
    $out['metadataOutcome'] = $result.Metadata['outcome']

    $script:replyMode = 'failure'
    $failed = $tool.TryInvoke(@{ file_path = 'missing.txt' })
    $out['failedOk'] = $failed.Ok
    $out['failedKind'] = $failed.Error['kind']
    $out['failedCode'] = $failed.Error['code']
    $out['failedHasValue'] = $failed.HasValue
    $raised = $false
    $raisedTargetIsResult = $false
    try { $null = $tool.Invoke(@{ file_path = 'missing.txt' }) } catch { $raised = $true; $raisedTargetIsResult = ($_.TargetObject -is [DshToolResult]) }
    $out['invokeRaised'] = $raised
    $out['raisedCarriesResult'] = $raisedTargetIsResult

    $script:replyMode = 'drift'
    $driftRaised = $false
    $driftMessage = ''
    try { $null = $tool.Invoke(@{ file_path = 'orders.json' }) } catch { $driftRaised = $true; $driftMessage = $_.Exception.Message }
    $out['driftRaised'] = $driftRaised
    $out['driftMentionsRefresh'] = $driftMessage -like '*Refresh()*'

    # Host control flow is raised even from TryInvoke: a revoked execution is
    # not an ordinary recoverable failure a script may branch past.
    $script:replyMode = 'refusal'
    $out['refusalThrew'] = $false
    $out['refusalKind'] = $null
    $out['refusalCode'] = $null
    try { $null = $tool.TryInvoke(@{ file_path = 'orders.json' }) } catch {
        $out['refusalThrew'] = $true
        $structured = $_.TargetObject
        if ($structured -is [DshToolResult]) {
            $out['refusalKind'] = $structured.Error['kind']
            $out['refusalCode'] = $structured.Error['code']
        }
    }

    # A handle is bound to the bridge AND the session that created it. Both
    # mismatches are host control flow: raised even from TryInvoke, no call made.
    $script:replyMode = 'success'
    $handle = Get-DshTool -Name read
    $out['handleSession'] = $handle.SessionId
    $out['foreignThrew'] = $false
    $out['foreignKind'] = $null
    $out['foreignCode'] = $null
    $foreign = Get-DshTool -Name read
    $foreign.Instance = 'other-instance'
    $callsBeforeForeign = $script:rpcCalls
    try { $null = $foreign.TryInvoke(@{ file_path = 'orders.json' }) }
    catch {
        $out['foreignThrew'] = $true
        if ($_.TargetObject -is [DshToolResult]) {
            $out['foreignKind'] = $_.TargetObject.Error['kind']
            $out['foreignCode'] = $_.TargetObject.Error['code']
        }
    }
    $out['foreignMadeNoCall'] = ($script:rpcCalls -eq $callsBeforeForeign)
    $out['sessionThrew'] = $false
    $out['sessionKind'] = $null
    $out['sessionCode'] = $null
    $callsBeforeSession = $script:rpcCalls
    $env:DSH_SESSION_ID = 'other-session'
    try { $null = $handle.TryInvoke(@{ file_path = 'orders.json' }) }
    catch {
        $out['sessionThrew'] = $true
        if ($_.TargetObject -is [DshToolResult]) {
            $out['sessionKind'] = $_.TargetObject.Error['kind']
            $out['sessionCode'] = $_.TargetObject.Error['code']
        }
    }
    $out['sessionMadeNoCall'] = ($script:rpcCalls -eq $callsBeforeSession)
    $env:DSH_SESSION_ID = 'unit-session'

    $script:toolDetail['definitionVersion'] = 'v2'
    $refreshed = $tool.Refresh()
    $out['refreshVersion'] = $refreshed.DefinitionVersion
    $out['oldHandleKeepsItsVersion'] = $tool.DefinitionVersion

    $passthru = Invoke-DshTool -Name read -Arguments @{ file_path = 'orders.json' } -PassThru
    $out['passThruIsResult'] = ($passthru -is [DshToolResult])
    $out['hasPassThruParameter'] = (Get-Command Invoke-DshTool).Parameters.ContainsKey('PassThru')

    $schema = Get-DshToolSchema -Name read
    $out['schemaType'] = [string]$schema['type']
    $out['schemaHasFilePath'] = $schema['properties'].Contains('file_path')

    $both = @(Get-DshTool -Name write, read)
    $out['order'] = (($both | ForEach-Object { $_.Name }) -join ',')

    # Content keeps its block array at every length: a bare if-expression would
    # flatten 0 blocks to $null and one block to the block itself.
    foreach ($mode in @('blocks-0', 'blocks-1', 'blocks-2', 'blocks-large')) {
        $script:replyMode = $mode
        $blocked = $tool.Invoke(@{ file_path = 'orders.json' })
        $count = @($blocked.Content).Count
        $out['content-' + $mode + '-count'] = $count
        $out['content-' + $mode + '-first'] = if ($count -gt 0) { [string]$blocked.Content[0]['text'] } else { '' }
        $out['content-' + $mode + '-firstlen'] = if ($count -gt 0) { ([string]$blocked.Content[0]['text']).Length } else { 0 }
        $out['content-' + $mode + '-viewlen'] = $blocked.ViewText.Length
        $out['content-' + $mode + '-displaylen'] = $blocked.DisplayText.Length
    }
    $script:replyMode = 'success'
    $env:DSH_SESSION_ID = $script:savedSession

    $decoded = ConvertFrom-DshJson -Json '{"A":1,"a":2,"iso":"2026-09-17T23:35:11.1234567+08:00","nothing":null,"empty":[],"one":[7],"unicode":"中文","nested":{"deep":[true,false]}}'
    $out['decodeCaseUpper'] = $decoded['A']
    $out['decodeCaseLower'] = $decoded['a']
    $out['decodeIsoIsString'] = ($decoded['iso'] -is [string])
    $out['decodeNullPresent'] = $decoded.Contains('nothing') -and ($null -eq $decoded['nothing'])
    $out['decodeEmptyArray'] = @($decoded['empty']).Count
    $out['decodeOneArray'] = @($decoded['one']).Count
    $out['decodeUnicode'] = [string]$decoded['unicode']
    $out['decodeDeepFalse'] = ($decoded['nested']['deep'][1] -eq $false)
    $out
}
Assert-That 'objects.catalog_is_info_only' ($objectModel['catalogCount'] -eq 2 -and $objectModel['catalogType'] -eq 'DshToolInfo' -and $objectModel['catalogHasNoCallMethod']) ($objectModel['catalogType'] + ' count=' + $objectModel['catalogCount'])
Assert-That 'objects.catalog_carries_summary' ($objectModel['catalogSummary'] -like 'Read a UTF-8*') $objectModel['catalogSummary']
Assert-That 'objects.handle_exposes_three_methods' ($objectModel['toolType'] -eq 'DshTool' -and $objectModel['hasAllMethods']) $objectModel['toolType']
Assert-That 'objects.handle_summarizes_parameters' ($objectModel['parameterSummary'] -like '*file_path: string (required)*') $objectModel['parameterSummary']
Assert-That 'objects.handle_states_the_read_contract' ($objectModel['returnSummary'] -like '*complete decoded text of the requested scope*') $objectModel['returnSummary']
Assert-That 'objects.handle_shows_validated_usage' ($objectModel['usage'] -like '*orders.json*') $objectModel['usage']
Assert-That 'objects.property_access_is_local' ([int]$objectModel['rpcAfterGet'] -eq [int]$objectModel['rpcAfterPropertyReads']) ('get=' + $objectModel['rpcAfterGet'] + ' after=' + $objectModel['rpcAfterPropertyReads'])
Assert-That 'objects.success_is_one_result' ($objectModel['ok'] -and $objectModel['hasValue']) ('ok=' + $objectModel['ok'] + ' hasValue=' + $objectModel['hasValue'])
Assert-That 'objects.case_distinct_keys_survive' ([int]$objectModel['caseUpper'] -eq 2 -and [int]$objectModel['caseLower'] -eq 1) ('A=' + $objectModel['caseUpper'] + ' a=' + $objectModel['caseLower'])
Assert-That 'objects.iso_string_stays_string' ($objectModel['isoIsString'] -and $objectModel['isoValue'] -eq '2026-09-17T23:35:11.1234567+08:00') $objectModel['isoValue']
Assert-That 'objects.null_value_differs_from_missing_key' ($objectModel['nullPresent'] -and $objectModel['absentMissing'])
Assert-That 'objects.arrays_keep_length' ([int]$objectModel['emptyArrayCount'] -eq 0 -and $objectModel['emptyArrayIsArray'] -and [int]$objectModel['oneArrayCount'] -eq 1) ('empty=' + $objectModel['emptyArrayCount'] + ' one=' + $objectModel['oneArrayCount'])
Assert-That 'objects.integers_stay_exact' ([int64]$objectModel['bigInt'] -eq [int64]9007199254740993) $objectModel['bigInt']
Assert-That 'objects.nested_null_survives' $objectModel['nestedNull']
Assert-That 'objects.declared_key_reads_with_any_case' ($objectModel['declaredKeyByProperty'] -eq 'declared lower-case key' -and $objectModel['declaredKeyByIndex'] -eq 'declared lower-case key' -and $objectModel['friendlyKeyLookupByOtherCase'] -and $objectModel['friendlyNullPresent']) ($objectModel['declaredKeyByProperty'])
Assert-That 'objects.display_text_and_alias_agree' ($objectModel['displayText'] -eq $objectModel['textAlias'] -and $objectModel['displayText'] -like 'content line*') $objectModel['displayText']
Assert-That 'objects.success_error_is_null' $objectModel['errorIsNull']
Assert-That 'objects.status_line_names_tool_and_outcome' ($objectModel['statusLine'] -like '*read*ok*') $objectModel['statusLine']
Assert-That 'objects.metadata_is_present' ($objectModel['metadataTool'] -eq 'read' -and $objectModel['metadataOutcome'] -eq 'settled') ($objectModel['metadataTool'] + '/' + $objectModel['metadataOutcome'])
Assert-That 'objects.tryinvoke_returns_failure' ((-not $objectModel['failedOk']) -and $objectModel['failedKind'] -eq 'Tool' -and $objectModel['failedCode'] -eq 'FS_NOT_FOUND' -and (-not $objectModel['failedHasValue'])) ($objectModel['failedKind'] + '/' + $objectModel['failedCode'])
Assert-That 'objects.invoke_raises_and_carries_result' ($objectModel['invokeRaised'] -and $objectModel['raisedCarriesResult'])
Assert-That 'objects.definition_drift_names_refresh' ($objectModel['driftRaised'] -and $objectModel['driftMentionsRefresh'])
Assert-That 'objects.identity_refusal_is_a_host_kind' ($objectModel['refusalThrew'] -and $objectModel['refusalKind'] -eq 'Host' -and $objectModel['refusalCode'] -eq 'IDENTITY_REVOKED') ($objectModel['refusalKind'] + '/' + $objectModel['refusalCode'])
Assert-That 'objects.handle_binds_its_creating_session' ($objectModel['handleSession'] -eq 'unit-session') $objectModel['handleSession']
Assert-That 'objects.foreign_handle_raises_from_tryinvoke' ($objectModel['foreignThrew'] -and $objectModel['foreignKind'] -eq 'Host' -and $objectModel['foreignCode'] -eq 'HANDLE_INSTANCE_MISMATCH' -and $objectModel['foreignMadeNoCall']) ($objectModel['foreignKind'] + '/' + $objectModel['foreignCode'])
Assert-That 'objects.session_mismatch_raises_from_tryinvoke' ($objectModel['sessionThrew'] -and $objectModel['sessionKind'] -eq 'Host' -and $objectModel['sessionCode'] -eq 'HANDLE_SESSION_MISMATCH' -and $objectModel['sessionMadeNoCall']) ($objectModel['sessionKind'] + '/' + $objectModel['sessionCode'])
Assert-That 'objects.refresh_returns_a_new_definition' ($objectModel['refreshVersion'] -eq 'v2' -and $objectModel['oldHandleKeepsItsVersion'] -eq 'v1') ($objectModel['refreshVersion'] + '/' + $objectModel['oldHandleKeepsItsVersion'])
Assert-That 'objects.passthru_is_a_noop' ($objectModel['passThruIsResult'] -and $objectModel['hasPassThruParameter'])
Assert-That 'objects.schema_entry_point_returns_an_object' ($objectModel['schemaType'] -eq 'object' -and $objectModel['schemaHasFilePath'])
Assert-That 'objects.multiple_names_keep_order' ($objectModel['order'] -eq 'write,read') $objectModel['order']

# One view must cover catalog rows, tool objects and result objects: the default
# formatter picks the view from the first object, so separate views would let a
# mixed pipeline fall back to a raw property list and dump the whole Value.
$viewTypes = @()
$formatData = Get-FormatData -TypeName 'DshToolResult' -ErrorAction SilentlyContinue
if ($formatData) { $viewTypes = @($formatData[0].TypeNames) }
Assert-That 'objects.one_view_covers_every_object_type' (($viewTypes -contains 'DshTool') -and ($viewTypes -contains 'DshToolResult') -and ($viewTypes -contains 'DshToolInfo')) ($viewTypes -join ',')
Assert-That 'objects.decoder_keeps_case' ([int]$objectModel['decodeCaseUpper'] -eq 1 -and [int]$objectModel['decodeCaseLower'] -eq 2) ('A=' + $objectModel['decodeCaseUpper'] + ' a=' + $objectModel['decodeCaseLower'])
Assert-That 'objects.decoder_keeps_iso_strings' $objectModel['decodeIsoIsString']
Assert-That 'objects.decoder_keeps_null_and_absence' $objectModel['decodeNullPresent']
Assert-That 'objects.decoder_keeps_array_lengths' ([int]$objectModel['decodeEmptyArray'] -eq 0 -and [int]$objectModel['decodeOneArray'] -eq 1)
Assert-That 'objects.decoder_keeps_unicode' ($objectModel['decodeUnicode'] -eq '中文') $objectModel['decodeUnicode']
Assert-That 'objects.decoder_keeps_booleans' $objectModel['decodeDeepFalse']
Assert-That 'objects.content_zero_blocks_is_an_empty_array' ([int]$objectModel['content-blocks-0-count'] -eq 0) $objectModel['content-blocks-0-count']
Assert-That 'objects.content_one_block_stays_an_array' ([int]$objectModel['content-blocks-1-count'] -eq 1 -and $objectModel['content-blocks-1-first'] -eq 'ONE-BLOCK') ($objectModel['content-blocks-1-count'].ToString() + '/' + $objectModel['content-blocks-1-first'])
Assert-That 'objects.content_two_blocks_keep_order' ([int]$objectModel['content-blocks-2-count'] -eq 2 -and $objectModel['content-blocks-2-first'] -eq 'FIRST-BLOCK') ($objectModel['content-blocks-2-count'].ToString() + '/' + $objectModel['content-blocks-2-first'])
Assert-That 'objects.content_large_text_is_whole_while_the_view_is_bounded' ([int]$objectModel['content-blocks-large-count'] -eq 1 -and [int]$objectModel['content-blocks-large-firstlen'] -eq 20000 -and [int]$objectModel['content-blocks-large-viewlen'] -lt 13000 -and [int]$objectModel['content-blocks-large-displaylen'] -eq 20000) ('count=' + $objectModel['content-blocks-large-count'] + ' text=' + $objectModel['content-blocks-large-firstlen'] + ' view=' + $objectModel['content-blocks-large-viewlen'])
Assert-That 'objects.handle_prints_the_read_limit' ($objectModel['returnSummary'] -like '*8388608*') $objectModel['returnSummary']
$catalogControl = & $module {
    function Invoke-DshCliRpc {
        param($Payload)
        if ($script:CatalogProbeReject) { return [ordered]@{ error = 'execution expired'; code = 'EXECUTION_ENDED' } }
        return [ordered]@{ tools = @() }
    }
    $script:CatalogProbeReject = $true
    $raised = $false
    try { $null = Get-DshTool } catch { $raised = $_.Exception.Message -eq 'execution expired' }
    $script:CatalogProbeReject = $false
    [pscustomobject]@{ RefusalRaised = $raised; EmptyCount = @(Get-DshTool).Count }
}
Assert-That 'objects.catalog_refusal_is_not_an_empty_catalog' $catalogControl.RefusalRaised
Assert-That 'objects.legitimate_empty_catalog_stays_empty' ($catalogControl.EmptyCount -eq 0)
Remove-Module $module -ErrorAction SilentlyContinue

# A failing Invoke must stop the block under the preset's default policy: the
# dependent write must not run. The check runs in a child pwsh because the
# failure terminates the statement, and it also records the documented
# limitation: an explicitly relaxed policy continues.
$stopRoot = New-CheckedTempRoot -Label 'failure-stop'
try {
    $probePath = Join-Path $stopRoot 'stop-probe.ps1'
    $probeText = @'
param([string]$ModulePath, [string]$MarkerPath, [string]$Policy)
$ErrorActionPreference = $Policy
$module = Import-Module $ModulePath -Force -PassThru
& $module {
    function Get-DshCliBridge { @{ instance = 'unit-test'; port = 1; token = 'x' } }
    function Invoke-DshCliRpc {
        param($Payload)
        $reply = @{ ok = $false; hasValue = $false; valueJson = $null; displayText = 'Error: nope'; content = @()
            error = @{ kind = 'Tool'; code = 'FS_NOT_FOUND'; message = 'nope'; tool = 'read'; parameterPath = $null }
            metadata = @{ tool = 'read'; outcome = 'settled'; durationMs = 1 } }
        return ConvertFrom-DshJson -Json (ConvertTo-Json -InputObject $reply -Depth 20 -Compress)
    }
    $tool = [DshTool]::new()
    $tool.Name = 'read'
    $tool.Instance = 'unit-test'
    $tool.DefinitionVersion = 'v1'
    $null = $tool.Invoke(@{ file_path = 'missing.txt' })
    Set-Content -LiteralPath $MarkerPath -Value 'dependent-write-ran'
    'BLOCK-CONTINUED'
}
'AFTER-BLOCK'
'@
    Set-Content -LiteralPath $probePath -Value $probeText
    foreach ($policy in @('Stop', 'Continue')) {
        $markerPath = Join-Path $stopRoot ('marker-' + $policy + '.txt')
        $null = & pwsh -NoLogo -NoProfile -File $probePath -ModulePath $modulePath -MarkerPath $markerPath -Policy $policy 2>&1
        $wrote = Test-Path -LiteralPath $markerPath
        if ($policy -eq 'Stop') {
            Assert-That 'objects.failure_stops_dependent_work_under_stop' (-not $wrote)
        }
        else {
            Assert-That 'objects.relaxed_policy_is_documented_to_continue' $wrote
        }
    }
}
finally { Remove-CheckedTempRoot -Root $stopRoot }

# The bootstrap installs the policy the object contract depends on, in the
# persistent shell's global scope rather than in a profile.
$bootstrapPath = Join-Path $repoRoot 'preset\plugin\bootstrap.ps1'
$policyScript = '& "' + $bootstrapPath + '"; Write-Output ("POLICY=" + $global:ErrorActionPreference); Write-Output ("NATIVE=" + $global:PSNativeCommandUseErrorActionPreference)'
$policyOutput = (& pwsh -NoLogo -NoProfile -Command $policyScript 2>&1) -join ' '
Assert-That 'objects.bootstrap_defaults_to_stop' ($policyOutput -like '*POLICY=Stop*') $policyOutput
Assert-That 'objects.bootstrap_keeps_native_exit_codes_as_data' ($policyOutput -like '*NATIVE=False*') $policyOutput

# The read contract must complete through the registered fs provider, never by
# reading a file directly in the bridge.
$bridgeSource = Get-Content -LiteralPath (Join-Path $repoRoot 'preset\plugin\dsh-all-in-pwsh.mjs') -Raw
Assert-That 'objects.read_contract_uses_the_fs_provider' (($bridgeSource -like '*ctx.fs.resolve(*') -and ($bridgeSource -like '*ctx.fs.stat(*') -and ($bridgeSource -like '*ctx.fs.streamText(*') -and ($bridgeSource -like '*ctx.fs.readBytes(*') -and ($bridgeSource -like "*'fs'*"))
Assert-That 'objects.bridge_never_reads_task_files_with_node_fs' (-not ($bridgeSource -match 'readFileSync\(\s*(target|filePath|requestedPath)'))
# Raw JSON schemas use object-level required arrays; the DSL's per-property
# `required: true` is invalid here and the registry rejects it at registration.
Assert-That 'objects.raw_schemas_use_object_level_required' (-not ($bridgeSource -match 'required: true'))

# --- repository hygiene ------------------------------------------------------
$tracked = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force | Where-Object { $_.FullName -notlike '*\.git\*' }
$legacy = @($tracked | Where-Object { $_.Name -in @('dsh-tool.mjs', 'dsh-tool.cmd', 'cli-mode.mjs') })
Assert-That 'repo.has_no_legacy_client' ($legacy.Count -eq 0) (($legacy | ForEach-Object { $_.Name }) -join ', ')
$artifacts = @($tracked | Where-Object { $_.Name -eq 'bridge.json' -or $_.Name -like '*.jsonl' -or $_.Name -like '*.log' })
Assert-That 'repo.has_no_run_artifacts' ($artifacts.Count -eq 0) (($artifacts | ForEach-Object { $_.Name }) -join ', ')
Assert-That 'repo.has_gitignore' (Test-Path -LiteralPath (Join-Path $repoRoot '.gitignore'))

# Every PowerShell snippet in the README must at least parse.
$readmeText = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
$fence = ([string][char]96) * 3
$blocks = [regex]::Matches($readmeText, '(?s)' + $fence + 'powershell\r?\n(.*?)' + $fence)
$snippetErrors = 0
foreach ($block in $blocks) {
    $tokens = $null
    $snippetParseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value, [ref]$tokens, [ref]$snippetParseErrors) | Out-Null
    $snippetErrors += $snippetParseErrors.Count
}
Assert-That 'repo.readme_snippets_parse' ($blocks.Count -ge 4 -and $snippetErrors -eq 0) ('blocks=' + $blocks.Count + ' parse-errors=' + $snippetErrors)
$personal = @($tracked | Where-Object { $_.Extension -in @('.ps1', '.mjs', '.js', '.cjs', '.yml', '.yaml', '.md', '.json') } | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'hq\.cao' })
Assert-That 'repo.has_no_personal_paths' ($personal.Count -eq 0) (($personal | ForEach-Object { $_.Name }) -join ', ')

Write-Host ''
if ($script:failures.Count -gt 0) {
    Write-Host ('FAILED: ' + $script:failures.Count + ' check(s): ' + ($script:failures -join ', '))
    exit 1
}
Write-Host 'All account-free checks passed.'
