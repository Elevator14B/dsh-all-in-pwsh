# Import the CLI mode module into this persistent shell, and install the error
# policy the object contract depends on.
#
# A failed $tool.Invoke has to stop the block: dependent writes must not run on
# missing data. A MethodInvocationException only terminates under Stop, so the
# preset's shell defaults to Stop. The caller may still relax it explicitly,
# and then this guarantee no longer holds - TryInvoke is the entry point for
# calls whose failure is an expected branch.
#
# Native processes keep their own contract: a non-zero exit code is data on the
# result object, not a PowerShell exception.
$global:ErrorActionPreference = 'Stop'
$global:PSNativeCommandUseErrorActionPreference = $false

# The host passes this file through the pwsh -File argument, so the module path
# is resolved from the script location rather than from a profile.
Import-Module (Join-Path $PSScriptRoot "DshCli.psm1") -Force -DisableNameChecking
