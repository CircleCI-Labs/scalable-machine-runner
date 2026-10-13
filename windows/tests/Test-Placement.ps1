<#
.SYNOPSIS
    Checks Swarm placement for the constraints the files in windows\stack use: a constrained service
    stays pending on a node that does not match, and starts once the node matches. Windows host,
    Docker in Windows-container mode. Needs no runner token.

.DESCRIPTION
    Uses a tiny service (a sleeping PowerShell on the stock Server Core image) so no runner or token is
    involved, and the same constraint expressions as the stack file:

      node.platform.os == windows                     matches
      node.platform.os == linux                       pending (wrong OS)
      node.labels.windows.build == <this build>       pending until the node carries the label
      node.labels.windows.build == <other build>      pending even with the right label on the node
      node.labels.smr.docker-build == true            pending until the node carries the label

    A pending task shows "no suitable node (scheduling constraints not satisfied on 1 node)" and has no
    container. The script adds node labels and removes them again; it leaves a swarm it created, but
    never one that existed before.

    Prints "CHECK ..." lines and "RESULT placement ..."; exits 0 only if everything passed.

.EXAMPLE
    .\windows\tests\Test-Placement.ps1
#>
[CmdletBinding()]
param(
    [string] $Image,
    [int] $PendingSeconds = 25,
    [int] $StartTimeoutSeconds = 300,
    [ValidateSet('process', 'hyperv', 'default')][string] $Isolation = 'process',
    [string] $AdvertiseAddr,
    [string] $DockerCommand = 'docker'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'SmrTestHelpers.psm1') -Force
$tag = Get-SmrWindowsTag
if (-not $Image) { $Image = "mcr.microsoft.com/windows/servercore:$tag" }
$otherTag = 'ltsc2025'
if ($tag -eq 'ltsc2025') { $otherTag = 'ltsc2022' }

function Invoke-Docker {
    param([string[]] $ArgumentList)
    return (Invoke-SmrDocker -DockerCommand $DockerCommand -ArgumentList $ArgumentList)
}

function Add-PlacementService {
    # Creates a service pinned by the given constraints; returns its name.
    param([string] $Suffix, [string[]] $Constraint, [string] $IsolationMode)
    $name = "smr-place-$PID-$Suffix"
    $create = @('service', 'create', '--detach', '--name', $name, '--restart-condition', 'none', '--endpoint-mode', 'dnsrr')
    if ($IsolationMode -ne 'default') { $create += "--isolation=$IsolationMode" }
    foreach ($c in $Constraint) { $create += @('--constraint', $c) }
    $create += @($Image, 'powershell.exe', '-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 3600')
    $r = Invoke-Docker $create
    if ($r.ExitCode -ne 0) { throw "docker service create ($Suffix) failed: $($r.Output -join ' ')" }
    return $name
}

function Get-PlacementState {
    # The newest task's state, and how many containers exist for the service.
    param([string] $Service)
    $task = @(Get-SmrServiceTask -Service $Service -DockerCommand $DockerCommand | Select-Object -First 1)
    $containers = @((Invoke-Docker @('ps', '--all', '--quiet', '--filter', "label=com.docker.swarm.service.name=$Service")).Output | Where-Object { $_ })
    $state = ''
    $err = ''
    if ($task.Count -gt 0) { $state = $task[0].CurrentState; $err = $task[0].Error }
    return @{ State = $state; Error = $err; Containers = $containers.Count }
}

function Test-StaysPending {
    param([string] $Service, [int] $Seconds)
    Start-Sleep -Seconds $Seconds
    $s = Get-PlacementState -Service $Service
    return @{ Ok = ($s.State -match '^Pending' -and $s.Containers -eq 0); Detail = "state='$($s.State)' error='$($s.Error)' containers=$($s.Containers)" }
}

$swarm = $null
$services = @()
$labelsAdded = @()
$node = $null
try {
    $swarm = Initialize-SmrSwarm -AdvertiseAddr $AdvertiseAddr -DockerCommand $DockerCommand
    $node = Get-SmrNodeId -DockerCommand $DockerCommand
    $null = Invoke-Docker @('pull', $Image)

    # Start from a clean node: no windows.build or smr.docker-build label.
    foreach ($l in @('windows.build', 'smr.docker-build')) { $null = Invoke-Docker @('node', 'update', '--label-rm', $l, $node) }

    # 1. Constraints that cannot match.
    $svc = Add-PlacementService -Suffix 'linux' -Constraint @('node.platform.os == linux') -IsolationMode $Isolation
    $services += $svc
    $p = Test-StaysPending -Service $svc -Seconds $PendingSeconds
    Write-SmrCheck 'wrong-os-pending' $p.Ok $p.Detail

    $svc = Add-PlacementService -Suffix 'nolabel' -Constraint @('node.platform.os == windows', "node.labels.windows.build == $tag") -IsolationMode $Isolation
    $services += $svc
    $p = Test-StaysPending -Service $svc -Seconds $PendingSeconds
    Write-SmrCheck 'missing-build-label-pending' $p.Ok $p.Detail

    $svc2 = Add-PlacementService -Suffix 'dockerbuild' -Constraint @('node.platform.os == windows', 'node.labels.smr.docker-build == true') -IsolationMode $Isolation
    $services += $svc2
    $p = Test-StaysPending -Service $svc2 -Seconds $PendingSeconds
    Write-SmrCheck 'missing-docker-build-label-pending' $p.Ok $p.Detail

    # 2. The label arrives: the pending task is scheduled and starts.
    $r = Invoke-Docker @('node', 'update', '--label-add', "windows.build=$tag", $node)
    $labelsAdded += 'windows.build'
    $started = Wait-SmrCondition -TimeoutSeconds $StartTimeoutSeconds -IntervalSeconds 5 -Condition { (Get-PlacementState -Service $svc).State -match '^Running' }
    $s = Get-PlacementState -Service $svc
    Write-SmrCheck 'build-label-starts' $started "label=windows.build=$tag label_exit=$($r.ExitCode) state='$($s.State)' error='$($s.Error)'"

    # 3. The docker-build service is still pending: only its own label unlocks it.
    $s2 = Get-PlacementState -Service $svc2
    Write-SmrCheck 'docker-build-still-pending' ($s2.State -match '^Pending') "state='$($s2.State)'"
    $null = Invoke-Docker @('node', 'update', '--label-add', 'smr.docker-build=true', $node)
    $labelsAdded += 'smr.docker-build'
    $started2 = Wait-SmrCondition -TimeoutSeconds $StartTimeoutSeconds -IntervalSeconds 5 -Condition { (Get-PlacementState -Service $svc2).State -match '^Running' }
    Write-SmrCheck 'docker-build-label-starts' $started2 "state='$((Get-PlacementState -Service $svc2).State)'"

    # 4. A service for the OTHER build stays pending although the node carries a windows.build label.
    $svc3 = Add-PlacementService -Suffix 'otherbuild' -Constraint @('node.platform.os == windows', "node.labels.windows.build == $otherTag") -IsolationMode $Isolation
    $services += $svc3
    $p = Test-StaysPending -Service $svc3 -Seconds $PendingSeconds
    Write-SmrCheck 'other-build-pending' $p.Ok "$($p.Detail) (node build $tag, service wants $otherTag)"
} finally {
    foreach ($s in $services) { $null = Invoke-Docker @('service', 'rm', $s) }
    if ($node) { foreach ($l in $labelsAdded) { $null = Invoke-Docker @('node', 'update', '--label-rm', $l, $node) } }
    if ($swarm -and $swarm.Initialised) { $null = Invoke-Docker @('swarm', 'leave', '--force') }
}

$count = Get-SmrCheckCount
$verdict = 'PASS'
if ($count.Failed -gt 0) { $verdict = 'FAIL' }
[Console]::Out.WriteLine("RESULT placement checks=$($count.Checks) failed=$($count.Failed) host_tag=$tag verdict=$verdict")
if ($count.Failed -gt 0) { exit 1 }
exit 0
