Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-SonarToolConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $config = Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
    foreach ($required in 'rootPath', 'projectKeyPrefix', 'sonar', 'scanner') {
        if (-not $config.PSObject.Properties[$required]) { throw "Required config property '$required' is missing." }
    }
    if (-not $config.sonar.url) { throw "Required config property 'sonar.url' is missing." }
    if (-not $config.scanner.executable) { throw "Required config property 'scanner.executable' is missing." }
    if (-not $config.scanner.PSObject.Properties['parallelism']) { $config.scanner | Add-Member parallelism 1 }
    if ([int]$config.scanner.parallelism -lt 1) { throw 'scanner.parallelism must be 1 or greater.' }
    if (-not $config.PSObject.Properties['splitDirectories']) { $config | Add-Member splitDirectories @() }
    if (-not $config.PSObject.Properties['excludeDirectories']) { $config | Add-Member excludeDirectories @() }
    if (-not $config.PSObject.Properties['allowDelete']) { $config | Add-Member allowDelete $false }
    if (-not $config.PSObject.Properties['deleteOnlyCreatedByTool']) { $config | Add-Member deleteOnlyCreatedByTool $true }
    return $config
}

function ConvertTo-SonarProjectKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$RelativePath)

    $part = $RelativePath.Trim().ToLowerInvariant() -replace '[\\/\s]+', '-'
    $part = $part -replace '[^a-z0-9_.:-]', '-'
    $part = $part -replace '-+', '-'
    $part = $part.Trim('-')
    if (-not $part) { throw "Cannot produce a project key from '$RelativePath'." }
    $key = if ($Prefix) { "$($Prefix.Trim().ToLowerInvariant())-$part" } else { $part }
    if ($key -notmatch '[^0-9]') { throw "SonarQube project key '$key' must contain a non-digit character." }
    return $key
}

function Get-SonarProjectCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $root = (Resolve-Path -LiteralPath $Config.rootPath).Path.TrimEnd('\', '/')
    $excluded = @($Config.excludeDirectories | ForEach-Object { [string]$_ })
    $explicit = @($Config.splitDirectories | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $directories = if ($explicit.Count) {
        $explicit | ForEach-Object {
            $path = Join-Path $root $_
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Configured directory does not exist: $path" }
            Get-Item -LiteralPath $path
        }
    } else {
        Get-ChildItem -LiteralPath $root -Directory | Where-Object { $excluded -notcontains $_.Name }
    }

    @($directories | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($root.Length).TrimStart('\', '/')
        [pscustomobject]@{
            Name = $_.Name
            Path = $_.FullName
            RelativePath = $relative
            ProjectKey = ConvertTo-SonarProjectKey -Prefix $Config.projectKeyPrefix -RelativePath $relative
        }
    })
}

function Get-SonarToken {
    $token = [Environment]::GetEnvironmentVariable('SONAR_TOKEN', 'Process')
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'SONAR_TOKEN environment variable is not set.' }
    return $token
}

function Invoke-SonarApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Parameters = @{}
    )

    $baseUrl = ([string]$Config.sonar.url).TrimEnd('/')
    $token = Get-SonarToken
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${token}:"))
    $headers = @{ Authorization = "Basic $auth" }
    try {
        if ($Method -eq 'GET') {
            $query = if ($Parameters.Count) {
                '?' + (($Parameters.GetEnumerator() | ForEach-Object {
                    '{0}={1}' -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value)
                }) -join '&')
            } else { '' }
            return Invoke-RestMethod -Method Get -Uri "$baseUrl$Path$query" -Headers $headers
        }
        return Invoke-RestMethod -Method Post -Uri "$baseUrl$Path" -Headers $headers -Body $Parameters -ContentType 'application/x-www-form-urlencoded'
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'n/a' }
        throw "SonarQube API $Method $Path failed (HTTP $status): $($_.Exception.Message)"
    }
}

function Test-SonarAuthentication {
    param([Parameter(Mandatory)]$Config)
    $result = Invoke-SonarApi -Config $Config -Method GET -Path '/api/authentication/validate'
    return [bool]$result.valid
}

function Test-SonarProjectExists {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$ProjectKey)
    $result = Invoke-SonarApi -Config $Config -Method GET -Path '/api/projects/search' -Parameters @{ projects = $ProjectKey }
    return @($result.components | Where-Object key -eq $ProjectKey).Count -gt 0
}

function New-SonarProject {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Candidate)
    if ($PSCmdlet.ShouldProcess($Candidate.ProjectKey, 'Create SonarQube project')) {
        Invoke-SonarApi -Config $Config -Method POST -Path '/api/projects/create' -Parameters @{
            project = $Candidate.ProjectKey; name = $Candidate.Name
        }
    }
}

function Remove-SonarProject {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$ProjectKey)
    if (-not [bool]$Config.allowDelete) { throw 'Project deletion is disabled by allowDelete=false.' }
    $prefix = "$([string]$Config.projectKeyPrefix)-".ToLowerInvariant()
    if ([bool]$Config.deleteOnlyCreatedByTool -and -not $ProjectKey.ToLowerInvariant().StartsWith($prefix)) {
        throw "Refusing to delete '$ProjectKey': it does not match tool prefix '$prefix'."
    }
    if ($PSCmdlet.ShouldProcess($ProjectKey, 'Delete SonarQube project')) {
        Invoke-SonarApi -Config $Config -Method POST -Path '/api/projects/delete' -Parameters @{ project = $ProjectKey } | Out-Null
    }
}

function Add-ProjectsToSonarApplication {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string[]]$ProjectKeys)
    $applicationKey = if ($Config.sonar.PSObject.Properties['applicationKey']) { [string]$Config.sonar.applicationKey } else { '' }
    if ([string]::IsNullOrWhiteSpace($applicationKey)) { return }
    foreach ($key in $ProjectKeys) {
        Invoke-SonarApi -Config $Config -Method POST -Path '/api/applications/add_project' -Parameters @{
            application = $applicationKey; project = $key
        } | Out-Null
    }
}

function Invoke-SonarScannerBatch {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][object[]]$Candidates)

    $token = Get-SonarToken
    $parallelism = [Math]::Max(1, [int]$Config.scanner.parallelism)
    $executable = [string]$Config.scanner.executable
    $url = [string]$Config.sonar.url
    $work = @($Candidates | ForEach-Object {
        [pscustomobject]@{ Name=$_.Name; Path=$_.Path; ProjectKey=$_.ProjectKey; Executable=$executable; Url=$url; Token=$token }
    })
    if (-not $PSCmdlet.ShouldProcess("$($work.Count) project(s)", "Run scanner with parallelism $parallelism")) { return @() }

    $pending = [Collections.Queue]::new()
    $work | ForEach-Object { $pending.Enqueue($_) }
    $running = @()
    $results = @()
    while ($pending.Count -or $running.Count) {
        while ($pending.Count -and $running.Count -lt $parallelism) {
            $item = $pending.Dequeue()
            $running += Start-Job -ArgumentList $item -ScriptBlock {
                param($workItem)
                Set-Location -LiteralPath $workItem.Path
                $output = & $workItem.Executable "-Dsonar.projectKey=$($workItem.ProjectKey)" "-Dsonar.projectName=$($workItem.Name)" "-Dsonar.sources=." "-Dsonar.host.url=$($workItem.Url)" "-Dsonar.token=$($workItem.Token)" 2>&1 | Out-String
                [pscustomobject]@{ ProjectKey=$workItem.ProjectKey; ExitCode=$LASTEXITCODE; Output=$output }
            }
        }
        $done = Wait-Job -Job $running -Any
        $results += Receive-Job -Job $done
        Remove-Job -Job $done
        $running = @($running | Where-Object Id -ne $done.Id)
    }
    return @($results)
}

Export-ModuleMember -Function Read-SonarToolConfig, ConvertTo-SonarProjectKey, Get-SonarProjectCandidates,
    Test-SonarAuthentication, Test-SonarProjectExists, New-SonarProject, Remove-SonarProject,
    Add-ProjectsToSonarApplication, Invoke-SonarScannerBatch
