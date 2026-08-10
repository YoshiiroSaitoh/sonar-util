[CmdletBinding()]
param(
    [string]$Config = (Join-Path $PSScriptRoot '..\sample-config-community.json'),
    [int]$Limit = 2,
    [switch]$RunScanner,
    [switch]$KeepProjects
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\SonarQubeTool.psm1') -Force
$settings = Read-SonarToolConfig $Config
if ($settings.sonar.applicationKey) { throw 'Community E2E requires sonar.applicationKey to be null or omitted.' }
$candidates = @(Get-SonarProjectCandidates $settings | Select-Object -First $Limit)
if (-not $candidates.Count) { throw 'No project candidates were found.' }
if (-not (Test-SonarAuthentication $settings)) { throw 'SONAR_TOKEN was rejected.' }

try {
    foreach ($candidate in $candidates) {
        if (-not (Test-SonarProjectExists $settings $candidate.ProjectKey)) { New-SonarProject $settings $candidate }
        if (-not (Test-SonarProjectExists $settings $candidate.ProjectKey)) { throw "Project was not created: $($candidate.ProjectKey)" }
        Write-Output "PASS create/existence $($candidate.ProjectKey)"
    }
    Add-ProjectsToSonarApplication $settings @($candidates.ProjectKey)
    Write-Output 'PASS Community mode skipped Application APIs'
    if ($RunScanner) {
        $results = @(Invoke-SonarScannerBatch $settings $candidates)
        if (@($results | Where-Object ExitCode -ne 0).Count) { throw 'One or more scanner processes failed.' }
        Write-Output 'PASS scanner batch'
    }
} finally {
    if (-not $KeepProjects) {
        foreach ($candidate in $candidates) {
            if (Test-SonarProjectExists $settings $candidate.ProjectKey) { Remove-SonarProject $settings $candidate.ProjectKey -Confirm:$false }
        }
    }
}

