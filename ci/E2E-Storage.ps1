<#
.SYNOPSIS
    The storage steps of the Windows e2e (see docs/ci.md): files that persist_to_workspace and
    save_cache carry from probe b1 to probe b2, and the check that they arrived intact.

.DESCRIPTION
    -Phase Create (b1)  Creates out\ and cache-dir\ in the current directory and records the
                        SHA-256 of every file in C:\e2e-evidence\storage-manifest.<workflow id>,
                        outside the workspace, so that b2's comparison does not trust what it
                        is checking. out\ holds a text file, files named so that a path
                        separator is followed by t or r (directories tmp and test-results, file
                        t.txt: names that a careless tar or a backslash escape corrupts) and a
                        symbolic link. cache-dir\ holds one file.
    -Phase Verify (b2)  After attach_workspace and restore_cache: every file exists and has the
                        recorded SHA-256, the link is a link (or a copy, which is noted), and
                        the cache file is there. Writes C:\e2e-evidence\storage.<workflow id>
                        with workspace=ok|fail cache=ok|fail symlink=link|copy|missing and exits
                        1 on any difference.

.EXAMPLE
    .\ci\E2E-Storage.ps1 -Phase Create
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Create', 'Verify')][string] $Phase,
    [string] $EvidenceDir = 'C:\e2e-evidence'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$wf = $env:CIRCLE_WORKFLOW_ID
if (-not $wf) { throw 'CIRCLE_WORKFLOW_ID is not set (run this as a CircleCI job)' }
$manifest = Join-Path $EvidenceDir "storage-manifest.$wf"
$result = Join-Path $EvidenceDir "storage.$wf"

function Get-Sha([string] $Path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash }

if ($Phase -eq 'Create') {
    New-Item -ItemType Directory -Force -Path 'out\tmp', 'out\test-results', 'cache-dir' | Out-Null
    Set-Content -LiteralPath 'out\hello.txt' -Value "workspace $wf $([guid]::NewGuid())" -Encoding ASCII
    Set-Content -LiteralPath 'out\t.txt' -Value 'starts with t' -Encoding ASCII
    Set-Content -LiteralPath 'out\tmp\a.txt' -Value 'in tmp' -Encoding ASCII
    Set-Content -LiteralPath 'out\test-results\r.txt' -Value 'in test-results' -Encoding ASCII
    Set-Content -LiteralPath 'cache-dir\cache.txt' -Value "cache $wf $([guid]::NewGuid())" -Encoding ASCII
    $linkMade = 'no'
    # mklink makes a link whose target is relative to the link's own directory.
    $mk = & cmd.exe /c 'mklink out\link.txt hello.txt' 2>&1
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath 'out\link.txt')) {
        $linkMade = 'yes'
    } else {
        Write-Host "note: cannot create a symbolic link: $($mk -join ' ')"
    }
    $lines = foreach ($f in @('out\hello.txt', 'out\t.txt', 'out\tmp\a.txt', 'out\test-results\r.txt', 'cache-dir\cache.txt')) { "$f=$(Get-Sha $f)" }
    @($lines) + @("symlink_made=$linkMade") | Set-Content -LiteralPath $manifest -Encoding ASCII
    Write-Host "created $(@($lines).Count) files for the workspace and the cache; symlink_made=$linkMade"
    exit 0
}

$expected = @{}
$linkMade = 'no'
foreach ($line in Get-Content -LiteralPath $manifest) {
    $name, $value = $line -split '=', 2
    if ($name -eq 'symlink_made') { $linkMade = $value } else { $expected[$name] = $value }
}
$failures = @()
$workspaceOk = $true
$cacheOk = $true
foreach ($f in $expected.Keys) {
    $got = if (Test-Path -LiteralPath $f) { Get-Sha $f } else { 'missing' }
    $isCache = $f.StartsWith('cache-dir')
    if ($got -ne $expected[$f]) {
        $failures += "$f (expected $($expected[$f]), got $got)"
        if ($isCache) { $cacheOk = $false } else { $workspaceOk = $false }
    }
}
$symlink = 'missing'
if (Test-Path -LiteralPath 'out\link.txt') {
    $item = Get-Item -LiteralPath 'out\link.txt' -Force
    $symlink = if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { 'link' } else { 'copy' }
    if ((Get-Content -LiteralPath 'out\link.txt' -Raw) -ne (Get-Content -LiteralPath 'out\hello.txt' -Raw)) { $failures += 'out\link.txt does not lead to hello.txt'; $workspaceOk = $false }
} elseif ($linkMade -eq 'yes') {
    $failures += 'out\link.txt did not arrive'
    $workspaceOk = $false
}
@(
    "workspace=$(if ($workspaceOk) { 'ok' } else { 'fail' })",
    "cache=$(if ($cacheOk) { 'ok' } else { 'fail' })",
    "symlink=$symlink",
    "files=$($expected.Count)",
    "failures=[$($failures -join '; ')]"
) | Set-Content -LiteralPath $result -Encoding ASCII
Get-Content -LiteralPath $result | ForEach-Object { Write-Host $_ }
if (-not ($workspaceOk -and $cacheOk)) { exit 1 }
exit 0
