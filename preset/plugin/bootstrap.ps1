# Import the CLI mode module into this persistent shell.
# The host passes this file through the pwsh -File argument, so the module path
# is resolved from the script location rather than from a profile.
Import-Module (Join-Path $PSScriptRoot "DshCli.psm1") -Force -DisableNameChecking
