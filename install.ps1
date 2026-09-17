<#
.SYNOPSIS
Install, update or remove the dsh-all-in-pwsh agent preset.

.DESCRIPTION
Copies the bundled preset into a DSH home as <PresetId>, substituting the
absolute path of the preset's own PowerShell bootstrap into the composition.
The global PowerShell profile is never touched.

The bundle is staged and validated beside the destination first, and the working
installation is renamed aside for the final swap and restored if that swap
fails, so a failure never leaves a half-written or destroyed installation. A directory this script
did not install is never overwritten without -Force, and anything the user added
or changed inside an installed preset is preserved as a timestamped backup
rather than deleted.

.PARAMETER DshHome
DSH home directory. Relative paths are resolved against the current directory
and stored absolute. Defaults to $env:DSH_HOME, then to the user profile's
.dsh directory.

.PARAMETER PresetId
Preset id, which is also the installed directory name. Must match
[a-z0-9][a-z0-9-]*.

.PARAMETER Force
Replace a preset directory this script did not install, after backing it up.

.PARAMETER Uninstall
Remove the preset this script installed and leave everything else alone.

.EXAMPLE
./install.ps1
.EXAMPLE
./install.ps1 -DshHome C:\dsh -PresetId dsh-all-in-pwsh
.EXAMPLE
./install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$DshHome,
    [string]$PresetId = 'dsh-all-in-pwsh',
    [switch]$Force,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$ProductId = 'dsh-all-in-pwsh'
$MarkerName = '.installed.json'
$MarkerSchema = 1
$Placeholder = '__DSH_ALL_IN_PWSH_BOOTSTRAP__'
$RequiredFiles = @(
    'preset.yml',
    'agent.cordis.yml',
    'plugin\dsh-all-in-pwsh.mjs',
    'plugin\DshCli.psm1',
    'plugin\bootstrap.ps1'
)

$sourceRoot = Join-Path $PSScriptRoot 'preset'
$separator = [System.IO.Path]::DirectorySeparatorChar

# A relative path is resolved against the CALLER's PowerShell location. .NET's
# GetFullPath uses the process working directory, which PowerShell's Set-Location
# does not update, so using it alone would resolve relative to an unrelated
# directory.
function Resolve-AbsolutePath {
    param([string]$Path)
    $candidate = $Path
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $location = $PWD
        if ($null -ne $location -and $location.Provider.Name -eq 'FileSystem') {
            $candidate = Join-Path $location.ProviderPath $candidate
        }
    }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Resolve-DshHomePath {
    param([string]$Requested)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        return (Resolve-AbsolutePath -Path $Requested)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
        return (Resolve-AbsolutePath -Path $env:DSH_HOME)
    }
    # $userHomePath, never $home: PowerShell variable names are case-insensitive
    # and $HOME is a read-only automatic variable.
    $userHomePath = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($userHomePath)) { $userHomePath = $env:HOME }
    if ([string]::IsNullOrWhiteSpace($userHomePath)) {
        throw 'Cannot determine a DSH home. Pass -DshHome, or set DSH_HOME or USERPROFILE.'
    }
    return (Resolve-AbsolutePath -Path (Join-Path $userHomePath '.dsh'))
}

# Refuse to write through a junction or symlink: a recursive remove or move on a
# reparse point can act on whatever it points at.
function Assert-NoReparsePoint {
    param([string]$Path, [string]$What)
    $current = $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$What ($current) is a reparse point (junction or symlink); refusing to touch it."
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Read-Marker {
    param([string]$Directory)
    $path = Join-Path $Directory $MarkerName
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return $null }
}

# Ownership is an explicit product identity, not "some JSON parsed".
function Test-OwnedByThisProduct {
    param($Marker, [string]$ExpectedPresetId)
    if ($null -eq $Marker) { return $false }
    if ($Marker.PSObject.Properties.Name -notcontains 'product') { return $false }
    if ($Marker.PSObject.Properties.Name -notcontains 'schema') { return $false }
    if ($Marker.PSObject.Properties.Name -notcontains 'presetId') { return $false }
    return ($Marker.product -eq $ProductId) -and ([int]$Marker.schema -eq $MarkerSchema) -and ($Marker.presetId -eq $ExpectedPresetId)
}

function Get-FileMap {
    param([string]$Directory)
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Directory)) { return $map }
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Recurse -File -Force) {
        $relative = $file.FullName.Substring($Directory.Length + 1)
        if ($relative -eq $MarkerName) { continue }
        $map[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $map
}

# Files the user added or changed since this script wrote the preset.
function Compare-InstalledFiles {
    param([string]$Directory, $Marker)
    $recorded = [ordered]@{}
    if ($null -ne $Marker -and $Marker.PSObject.Properties.Name -contains 'files') {
        foreach ($property in $Marker.files.PSObject.Properties) { $recorded[$property.Name] = [string]$property.Value }
    }
    $current = Get-FileMap -Directory $Directory
    $added = @($current.Keys | Where-Object { -not $recorded.Contains($_) })
    $modified = @($current.Keys | Where-Object { $recorded.Contains($_) -and $recorded[$_] -ne $current[$_] })
    $removed = @($recorded.Keys | Where-Object { -not $current.Contains($_) })
    return [ordered]@{ added = $added; modified = $modified; removed = $removed }
}

# A name nothing occupies yet. The GUID suffix keeps two moves made in the same
# second apart: Move-Item into an existing directory nests the source inside it,
# which would silently bury the first backup.
function New-FreeSiblingPath {
    param([string]$PresetRoot, [string]$Leaf)
    for ($attempt = 0; $attempt -lt 16; $attempt = $attempt + 1) {
        $candidate = Join-Path $PresetRoot ($Leaf + '-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "Could not find a free name for $Leaf in $PresetRoot."
}

function Move-ToBackup {
    param([string]$Directory, [string]$PresetRoot, [string]$Id)
    $backup = New-FreeSiblingPath -PresetRoot $PresetRoot -Leaf ($Id + '.backup-' + (Get-Date -Format 'yyyyMMddHHmmss'))
    Move-Item -LiteralPath $Directory -Destination $backup
    return $backup
}

if ($PresetId -notmatch '^[a-z0-9][a-z0-9-]*$') {
    throw "PresetId must match [a-z0-9][a-z0-9-]*; got '$PresetId'."
}
if (-not (Test-Path -LiteralPath $sourceRoot)) {
    throw "The bundled preset is missing: $sourceRoot"
}

$resolvedHome = Resolve-DshHomePath -Requested $DshHome
$presetRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedHome '.agent-presets'))
$target = [System.IO.Path]::GetFullPath((Join-Path $presetRoot $PresetId))
if (-not $target.StartsWith($presetRoot + $separator, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to work outside the preset root $presetRoot (resolved target was $target)."
}
$bootstrap = Join-Path $target 'plugin\bootstrap.ps1'

if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "Nothing to remove: $target does not exist."
        return
    }
    Assert-NoReparsePoint -Path $target -What 'The installed preset'
    $marker = Read-Marker -Directory $target
    if (-not (Test-OwnedByThisProduct -Marker $marker -ExpectedPresetId $PresetId)) {
        throw "$target was not installed by this script (no $MarkerName identifying $ProductId schema $MarkerSchema for preset '$PresetId'), so it is left untouched. Remove it yourself if you are sure."
    }
    $changes = Compare-InstalledFiles -Directory $target -Marker $marker
    $touched = @($changes.added) + @($changes.modified)
    if ($touched.Count -gt 0) {
        $backup = Move-ToBackup -Directory $target -PresetRoot $presetRoot -Id $PresetId
        Write-Host "Removed preset '$PresetId'. Files you added or changed were preserved at $backup"
        return
    }
    Remove-Item -LiteralPath $target -Recurse -Force
    Write-Host "Removed preset '$PresetId' from $presetRoot."
    return
}

# Checked before anything is created: a junction anywhere on this path must be
# refused, not have a directory created through it.
Assert-NoReparsePoint -Path $target -What 'The preset destination'
New-Item -ItemType Directory -Force -Path $presetRoot | Out-Null

$existingMarker = Read-Marker -Directory $target
$owned = Test-OwnedByThisProduct -Marker $existingMarker -ExpectedPresetId $PresetId
if ((Test-Path -LiteralPath $target) -and (-not $owned) -and (-not $Force)) {
    throw "$target already exists and was not installed by this script. Re-run with -Force to back it up and replace it."
}

# --- stage and validate beside the destination -------------------------------
$staging = New-FreeSiblingPath -PresetRoot $presetRoot -Leaf ('.' + $ProductId + '.staging')
$stagingBackup = $null
$rollback = $null
try {
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    # Literal enumeration, so a checkout path containing [ ] or * still copies.
    foreach ($entry in Get-ChildItem -LiteralPath $sourceRoot -Force) {
        Copy-Item -LiteralPath $entry.FullName -Destination $staging -Recurse -Force
    }

    $composition = Join-Path $staging 'agent.cordis.yml'
    $compositionText = Get-Content -LiteralPath $composition -Raw
    if (-not $compositionText.Contains($Placeholder)) {
        throw "The composition does not contain the bootstrap placeholder $Placeholder; the bundle is inconsistent."
    }
    # The placeholder sits in a YAML single-quoted scalar, where an apostrophe in
    # the path is doubled. Both the substitution and its check use that
    # serialized form, so a home such as ...\O'Brien installs as well.
    $serializedBootstrap = $bootstrap.Replace("'", "''")
    $compositionText = $compositionText.Replace($Placeholder, $serializedBootstrap)
    Set-Content -LiteralPath $composition -Value $compositionText -NoNewline

    foreach ($relative in $RequiredFiles) {
        $path = Join-Path $staging $relative
        if (-not (Test-Path -LiteralPath $path)) { throw "The bundle is missing $relative" }
        if ((Get-Item -LiteralPath $path).Length -eq 0) { throw "The bundled $relative is empty" }
    }
    $stagedComposition = Get-Content -LiteralPath $composition -Raw
    if ($stagedComposition.Contains($Placeholder)) { throw 'The staged composition still contains the bootstrap placeholder.' }
    $expectedBootstrapRow = "- '" + $serializedBootstrap + "'"
    if (-not $stagedComposition.Contains($expectedBootstrapRow)) {
        throw "The staged composition does not name the installed bootstrap $bootstrap."
    }

    $marker = [ordered]@{
        schema      = $MarkerSchema
        product     = $ProductId
        presetId    = $PresetId
        installedAt = (Get-Date).ToString('o')
        source      = $PSScriptRoot
        bootstrap   = $bootstrap
        files       = (Get-FileMap -Directory $staging)
    }
    $marker | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $staging $MarkerName)
    $stagedMarker = Read-Marker -Directory $staging
    if (-not (Test-OwnedByThisProduct -Marker $stagedMarker -ExpectedPresetId $PresetId)) {
        throw 'The staged installation did not produce a readable ownership marker.'
    }

    # --- swap: only now is the working installation touched ------------------
    # Whatever was at the destination is renamed aside, never deleted, and it
    # stays there until the new installation is in place. A swap that fails can
    # therefore put it back exactly as it was; only a swap that succeeds turns
    # it into a permanent backup or drops it.
    $keepRollback = $false
    if (Test-Path -LiteralPath $target) {
        $rollback = New-FreeSiblingPath -PresetRoot $presetRoot -Leaf ('.' + $ProductId + '.rollback')
        Move-Item -LiteralPath $target -Destination $rollback
        if ($owned) {
            $changes = Compare-InstalledFiles -Directory $rollback -Marker $existingMarker
            $keepRollback = (@($changes.added) + @($changes.modified)).Count -gt 0
        }
        else {
            # A directory this script did not install is always kept, -Force or not.
            $keepRollback = $true
        }
    }
    if ($env:DSH_ALL_IN_PWSH_TEST_FAIL_SWAP -eq '1') {
        # Test hook. The account-free suite sets it to prove that a swap which
        # fails restores the previous installation; nothing else sets it.
        throw 'Injected swap failure (DSH_ALL_IN_PWSH_TEST_FAIL_SWAP).'
    }
    Move-Item -LiteralPath $staging -Destination $target

    if ($null -ne $rollback -and (Test-Path -LiteralPath $rollback)) {
        if ($keepRollback) {
            $stagingBackup = Move-ToBackup -Directory $rollback -PresetRoot $presetRoot -Id $PresetId
        }
        else {
            Remove-Item -LiteralPath $rollback -Recurse -Force
        }
        $rollback = $null
    }
}
catch {
    # Put the previous installation back, then drop the staging copy. A restore
    # that does not work is reported with the location of the copy, never hidden,
    # and the original error is rethrown either way.
    $cause = $_
    if ($null -ne $rollback -and (Test-Path -LiteralPath $rollback)) {
        if (Test-Path -LiteralPath $target) {
            Write-Warning "The swap failed and $target already exists, so the previous installation is left at $rollback."
        }
        else {
            try {
                Move-Item -LiteralPath $rollback -Destination $target -ErrorAction Stop
            }
            catch {
                Write-Warning "The swap failed and the previous installation could not be put back. It is preserved at $rollback. $($_.Exception.Message)"
            }
        }
    }
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    throw $cause
}

if ($null -ne $stagingBackup) {
    Write-Host "Files you added or changed were preserved at $stagingBackup"
}
Write-Host "Installed preset '$PresetId'."
Write-Host "  DSH home   : $resolvedHome"
Write-Host "  Preset dir : $target"
Write-Host "  Bootstrap  : $bootstrap"
Write-Host ''
Write-Host 'Next: start a host (dsh web) and choose the preset for a new session.'
Write-Host 'Update:   re-run this script.  Remove: ./install.ps1 -Uninstall'
