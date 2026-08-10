[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Config,
    [ValidateSet('List','ValidateToken','Create','Scan','Delete','E2E')][string]$Action = 'List',
    [string[]]$ProjectKey,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SonarQubeTool.psm1') -Force
$settings = Read-SonarToolConfig -Path $Config
$candidates = @(Get-SonarProjectCandidates -Config $settings)
if ($ProjectKey) { $candidates = @($candidates | Where-Object ProjectKey -in $ProjectKey) }

switch ($Action) {
    'List' { $candidates | Format-Table Name, ProjectKey, Path; break }
    'ValidateToken' {
        if (-not (Test-SonarAuthentication -Config $settings)) { throw 'SONAR_TOKEN was rejected by SonarQube.' }
        Write-Output 'SONAR_TOKEN is valid.'
        break
    }
    'Create' {
        foreach ($candidate in $candidates) {
            if (Test-SonarProjectExists -Config $settings -ProjectKey $candidate.ProjectKey) {
                Write-Output "EXISTS $($candidate.ProjectKey)"
            } else {
                New-SonarProject -Config $settings -Candidate $candidate -WhatIf:$DryRun
                if (-not $DryRun) { Write-Output "CREATED $($candidate.ProjectKey)" }
            }
        }
        if (-not $DryRun) { Add-ProjectsToSonarApplication -Config $settings -ProjectKeys @($candidates.ProjectKey) }
        break
    }
    'Scan' {
        $results = Invoke-SonarScannerBatch -Config $settings -Candidates $candidates -WhatIf:$DryRun
        $results | Format-Table ProjectKey, ExitCode
        if (@($results | Where-Object ExitCode -ne 0).Count) { exit 1 }
        break
    }
    'Delete' {
        foreach ($candidate in $candidates) {
            Remove-SonarProject -Config $settings -ProjectKey $candidate.ProjectKey -WhatIf:$DryRun -Confirm:(-not $Force)
            if (-not $DryRun) { Write-Output "DELETED $($candidate.ProjectKey)" }
        }
        break
    }
    'E2E' {
        if (-not (Test-SonarAuthentication -Config $settings)) { throw 'SONAR_TOKEN was rejected by SonarQube.' }
        foreach ($candidate in $candidates) {
            if (-not (Test-SonarProjectExists -Config $settings -ProjectKey $candidate.ProjectKey)) {
                New-SonarProject -Config $settings -Candidate $candidate -WhatIf:$DryRun
            }
        }
        if (-not $DryRun) {
            Add-ProjectsToSonarApplication -Config $settings -ProjectKeys @($candidates.ProjectKey)
            $results = @(Invoke-SonarScannerBatch -Config $settings -Candidates $candidates)
            $results | Format-Table ProjectKey, ExitCode
            if (@($results | Where-Object ExitCode -ne 0).Count) { exit 1 }
        }
        break
    }
}

