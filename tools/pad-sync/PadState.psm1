# PadState.psm1 — the single definition of the runtime state directory
#
# Why one module: the lock file (PadLock.psm1) and the designer log (PadDesigner.psm1) each used to
# spell out %LOCALAPPDATA%\flow-ir on their own, so every rename had to be applied twice and the two
# copies could drift apart. The directory name now lives here and nowhere else.
#
# Migration: the directory used to be called "flow-ir". When the old directory exists and the new one
# does not, the content is moved over once and the old directory is removed; from then on the new
# directory is the only one in use. A failed migration is not fatal — the caller creates the new
# directory as usual and the leftover old directory is only a stale copy.

$script:StateDirName = 'flowwright'
$script:LegacyStateDirName = 'flow-ir'

function Get-PadStateDir {
    $new = Join-Path $env:LOCALAPPDATA $script:StateDirName
    $legacy = Join-Path $env:LOCALAPPDATA $script:LegacyStateDirName
    if (Test-Path -LiteralPath $new) { return $new }
    if (Test-Path -LiteralPath $legacy) {
        try {
            New-Item -ItemType Directory -Path $new -Force | Out-Null
            foreach ($item in @(Get-ChildItem -LiteralPath $legacy -Force -ErrorAction Stop)) {
                Move-Item -LiteralPath $item.FullName -Destination $new -Force -ErrorAction Stop
            }
            Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction Stop
        } catch {
            # Best effort: the new directory is usable either way, so a blocked move only leaves the
            # old content behind — it must never stop the caller
            Write-Verbose "state directory migration failed: $($_.Exception.Message)"
        }
    }
    return $new
}

Export-ModuleMember -Function Get-PadStateDir
