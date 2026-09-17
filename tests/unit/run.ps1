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
$fidelity = & $module {
    function Invoke-DshCliRpc {
        param($Payload)
        @{ isError = $false; text = (ConvertTo-Json -InputObject $Payload -Depth 50 -Compress) }
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
        try { $results[$pair.name] = (Invoke-DshTool echo $pair.value -PassThru -ErrorAction Stop).Text }
        catch { $results[$pair.name] = 'ERROR: ' + $_.Exception.Message }
    }
    $results
}
Assert-That 'module.case_sensitive_keys_survive' ($fidelity['case-key'] -like '*"a":1*' -and $fidelity['case-key'] -like '*"A":2*') $fidelity['case-key']
Assert-That 'module.date_like_string_stays_string' ($fidelity['iso-date-string'] -like '*2026-09-17T23:35:11.1234567+08:00*') $fidelity['iso-date-string']
Assert-That 'module.empty_key_survives' ($fidelity['empty-key'] -like '*"":"blank"*') $fidelity['empty-key']
Assert-That 'module.unicode_survives' ($fidelity['unicode'] -like '*tick*') $fidelity['unicode']

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
        @{ isError = $false; text = (ConvertTo-Json -InputObject $Payload -Depth 50 -Compress) }
    }
    function Get-DshCliBridge { @{ instance = 'unit-test' } }
    $allowed = @{ leaf = 'bottom' }
    for ($level = 0; $level -lt 46; $level = $level + 1) { $allowed = @{ next = $allowed } }
    $rejectedValue = @{ next = $allowed }
    $out = [ordered]@{}
    try { $out['allowed'] = (Invoke-DshTool echo $allowed -PassThru -ErrorAction Stop).Text }
    catch { $out['allowed'] = 'ERROR: ' + $_.Exception.Message }
    try { $null = Invoke-DshTool echo $rejectedValue -PassThru -ErrorAction Stop; $out['rejected'] = 'NO-ERROR' }
    catch { $out['rejected'] = $_.Exception.Message }
    $out
}
$allowedWire = [string]$depthBudget['allowed']
$nextCount = ([regex]::Matches($allowedWire, '"next"')).Count
Assert-That 'module.depth_budget_serializes_the_limit' ($allowedWire -like '*bottom*' -and $nextCount -eq 46) ('next-count=' + $nextCount)
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
