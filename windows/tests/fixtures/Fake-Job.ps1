<#
    Stand-in for a CircleCI job inside a runner container (Windows).
    Reports residue left by any previous job, then leaves residue everywhere a real job
    could: profile, TEMP, working directory, ProgramData, HKCU, HKLM (admin only) and a
    machine environment variable.

    Output (one line):
      FAKEJOB layer=<container identity hash> host=<COMPUTERNAME> user=<name> residue=[...]

    "host" is COMPUTERNAME, which is the container ID because no test sets a hostname. It is how
    a container is told apart on Windows: the C: volume ID is the same in every container started
    from one image. "layer" is a hash of both, for the log. A restarted container keeps both; a new
    container gets a new COMPUTERNAME.
#>
$ErrorActionPreference = 'Continue'

$fileMarkers = @(
    (Join-Path $env:USERPROFILE '.job-marker'),
    (Join-Path $env:TEMP '.job-marker'),
    'C:\cci\w\.job-marker',
    'C:\ProgramData\swarm-job-marker'
)
$regMarkers = @('HKCU:\Software\SwarmJobMarker', 'HKLM:\SOFTWARE\SwarmJobMarker')

$seen = New-Object System.Collections.Generic.List[string]
foreach ($f in $fileMarkers) { if (Test-Path -LiteralPath $f) { $seen.Add($f) } }
foreach ($k in $regMarkers) { if (Test-Path -LiteralPath $k) { $seen.Add($k) } }
if ([Environment]::GetEnvironmentVariable('SWARM_TEST_JOB_MARKER', 'Machine')) { $seen.Add('env:Machine\SWARM_TEST_JOB_MARKER') }

$volumeId = $null
try { $volumeId = (Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='C:'" -ErrorAction Stop).DeviceID } catch { $volumeId = $null }
if (-not $volumeId) {
    $mv = & mountvol.exe 'C:\' /L 2>$null
    if ($mv) { $volumeId = ([string]$mv).Trim() }
}
# COMPUTERNAME survives a restart of the same container and changes for a new container
# (nothing sets --hostname, so COMPUTERNAME is the container's ID).
$sha = [System.Security.Cryptography.SHA256]::Create()
$hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$volumeId|$env:COMPUTERNAME"))
$layer = (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
[Console]::Out.WriteLine("FAKEJOB layer=$layer host=$env:COMPUTERNAME user=$user residue=[$($seen -join ' ')]")

foreach ($f in $fileMarkers) {
    try {
        $dir = Split-Path -Parent $f
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Set-Content -LiteralPath $f -Value 'residue' -ErrorAction Stop
    } catch { $null = $_ }
}
foreach ($k in $regMarkers) {
    try { New-Item -Path $k -Force -ErrorAction Stop | Out-Null } catch { $null = $_ }
}
try { [Environment]::SetEnvironmentVariable('SWARM_TEST_JOB_MARKER', 'residue', 'Machine') } catch { $null = $_ }
exit 0
