<#
.SYNOPSIS
Proves that the installer checks fail against the behaviour they guard.

.DESCRIPTION
Each entry applies one small regression to a throwaway copy of install.ps1 and
runs the account-free suite against it. A mutation that no check catches is a
hole in the suite, so every expected check name must appear among the failures.
Slower than run.ps1 because it runs the suite once per mutation; it is not part
of the default unit run.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$suite = Join-Path $PSScriptRoot 'run.ps1'
$separator = [System.IO.Path]::DirectorySeparatorChar
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())

$mutations = @(
    [pscustomobject]@{
        Name    = 'backup-name-without-unique-suffix'
        Expects = @('installer.same_second_backups_are_distinct', 'installer.backups_are_independently_readable')
        From    = @('$backup = New-FreeSiblingPath -PresetRoot $PresetRoot -Leaf ($Id + ''.backup-'' + (Get-Date -Format ''yyyyMMddHHmmss''))')
        To      = @('$backup = Join-Path $PresetRoot ($Id + ''.backup-'' + (Get-Date -Format ''yyyyMMddHHmmss''))')
    }
    [pscustomobject]@{
        Name    = 'validate-unescaped-bootstrap-path'
        Expects = @('installer.installs_under_apostrophe_path', 'installer.bootstrap_row_round_trips_yaml_quotes')
        From    = @('    $expectedBootstrapRow = "- ''" + $serializedBootstrap + "''"', '    if (-not $stagedComposition.Contains($expectedBootstrapRow)) {')
        To      = @('    if (-not $stagedComposition.Contains($bootstrap)) {')
    }
    [pscustomobject]@{
        Name    = 'no-restore-after-a-failed-swap'
        Expects = @('installer.failed_swap_restores_installation', 'installer.failed_swap_restores_modified_install', 'installer.failed_swap_restores_forced_foreign_directory')
        From    = @('                Move-Item -LiteralPath $rollback -Destination $target -ErrorAction Stop')
        To      = @('        Write-Verbose ''mutation: no restore''')
    }
    [pscustomobject]@{
        Name    = 'reparse-check-after-creating-the-root'
        Expects = @('installer.rejects_reparse_home_before_creating')
        From    = @('Assert-NoReparsePoint -Path $target -What ''The preset destination''', 'New-Item -ItemType Directory -Force -Path $presetRoot | Out-Null')
        To      = @('New-Item -ItemType Directory -Force -Path $presetRoot | Out-Null', 'Assert-NoReparsePoint -Path $target -What ''The preset destination''')
    }
)

$script:failures = @()
function Assert-That {
    param([string]$Name, [bool]$Condition, $Detail)
    if ($Condition) { Write-Host ('PASS  ' + $Name); return }
    Write-Host ('FAIL  ' + $Name)
    if ($null -ne $Detail) { Write-Host ('      ' + ([string]$Detail).Trim()) }
    $script:failures += $Name
}

$script:tempRoots = @()
function New-CheckedTempRoot {
    param([string]$Label)
    $root = Join-Path $tempBase ('dsh-all-in-pwsh-mutation-' + $Label + '-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    if (-not $root.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to use $root" }
    $script:tempRoots += $root
    return $root
}

$lineFeed = [string][char]10
$carriageReturn = [string][char]13

try {
    foreach ($mutation in $mutations) {
        $root = New-CheckedTempRoot -Label $mutation.Name
        $copy = Join-Path $root 'repo'
        New-Item -ItemType Directory -Force -Path $copy | Out-Null
        foreach ($entry in Get-ChildItem -LiteralPath $repoRoot -Force | Where-Object { $_.Name -ne '.git' }) {
            Copy-Item -LiteralPath $entry.FullName -Destination $copy -Recurse -Force
        }
        $installerCopy = Join-Path $copy 'install.ps1'
        $text = [System.IO.File]::ReadAllText($installerCopy).Replace($carriageReturn + $lineFeed, $lineFeed)
        $from = $mutation.From -join $lineFeed
        $to = $mutation.To -join $lineFeed
        if (-not $text.Contains($from)) { throw ('The mutation ' + $mutation.Name + ' no longer matches install.ps1; update it.') }
        [System.IO.File]::WriteAllText($installerCopy, $text.Replace($from, $to))

        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($installerCopy, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors.Count -gt 0) { throw ('The mutation ' + $mutation.Name + ' produced an unparsable installer.') }

        $output = (& pwsh -NoLogo -NoProfile -File (Join-Path $copy ('tests' + $separator + 'unit' + $separator + 'run.ps1')) 2>&1 | Out-String)
        $failed = @($output -split $lineFeed | Where-Object { $_ -like 'FAIL  *' } | ForEach-Object { $_.Trim().Substring(6) })
        $missing = @($mutation.Expects | Where-Object { $failed -notcontains $_ })
        Assert-That ('mutation.' + $mutation.Name) ($missing.Count -eq 0) ('expected check(s) still passed: ' + ($missing -join ', ') + '; failures were: ' + ($failed -join ', '))
    }
}
finally {
    foreach ($root in $script:tempRoots) {
        if ($root.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
if ($script:failures.Count -gt 0) {
    Write-Host ('FAILED: ' + $script:failures.Count + ' mutation(s) went undetected: ' + ($script:failures -join ', '))
    exit 1
}
Write-Host 'Every mutation was caught by its own check.'
