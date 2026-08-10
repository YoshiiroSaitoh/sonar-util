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
    if (-not $config.sonar.PSObject.Properties['propertiesFile'] -or -not $config.sonar.propertiesFile) {
        throw "Required config property 'sonar.propertiesFile' is missing."
    }
    $configDirectory = Split-Path -Parent $resolved
    $propertiesPath = [string]$config.sonar.propertiesFile
    if (-not [IO.Path]::IsPathRooted($propertiesPath)) { $propertiesPath = Join-Path $configDirectory $propertiesPath }
    $propertiesPath = (Resolve-Path -LiteralPath $propertiesPath).Path
    $sonarProperties = Read-SonarProperties -Path $propertiesPath
    if (-not $sonarProperties.ContainsKey('sonar.host.url')) { throw "Required property 'sonar.host.url' is missing from $propertiesPath." }
    $config.sonar | Add-Member -NotePropertyName url -NotePropertyValue $sonarProperties['sonar.host.url'] -Force
    $config.sonar | Add-Member -NotePropertyName resolvedPropertiesFile -NotePropertyValue $propertiesPath -Force
    if (-not $config.scanner.executable) { throw "Required config property 'scanner.executable' is missing." }
    if (-not $config.scanner.PSObject.Properties['parallelism']) { $config.scanner | Add-Member parallelism 1 }
    if ([int]$config.scanner.parallelism -lt 1) { throw 'scanner.parallelism must be 1 or greater.' }
    if (-not $config.scanner.PSObject.Properties['javaBinaries']) {
        $config.scanner | Add-Member javaBinaries ([pscustomobject]@{ directory = 'classes'; useDummyWhenMissing = $true })
    }
    if (-not $config.scanner.javaBinaries.PSObject.Properties['directory']) { $config.scanner.javaBinaries | Add-Member directory 'classes' }
    if (-not $config.scanner.javaBinaries.PSObject.Properties['useDummyWhenMissing']) { $config.scanner.javaBinaries | Add-Member useDummyWhenMissing $true }
    if (-not $config.PSObject.Properties['splitDirectories']) { $config | Add-Member splitDirectories @() }
    if (-not $config.PSObject.Properties['excludeDirectories']) { $config | Add-Member excludeDirectories @() }
    if (-not $config.PSObject.Properties['allowDelete']) { $config | Add-Member allowDelete $false }
    if (-not $config.PSObject.Properties['deleteOnlyCreatedByTool']) { $config | Add-Member deleteOnlyCreatedByTool $true }
    if (-not $config.PSObject.Properties['projectName']) {
        $config | Add-Member projectName ([pscustomobject]@{ mode = 'directoryName'; separator = ' / ' })
    }
    if (-not $config.projectName.PSObject.Properties['mode']) { $config.projectName | Add-Member mode 'directoryName' }
    if (-not $config.projectName.PSObject.Properties['separator']) { $config.projectName | Add-Member separator ' / ' }
    if (-not $config.projectName.PSObject.Properties['includePrefix']) { $config.projectName | Add-Member includePrefix $false }
    if (-not $config.projectName.PSObject.Properties['prefixSeparator']) { $config.projectName | Add-Member prefixSeparator ' / ' }
    if ([string]$config.projectName.mode -notin @('directoryName', 'relativePath')) {
        throw "projectName.mode must be 'directoryName' or 'relativePath'."
    }
    return $config
}

function Read-SonarProperties {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $result = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#') -or $trimmed.StartsWith('!')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) { $separator = $trimmed.IndexOf(':') }
        if ($separator -lt 1) { throw "Invalid Sonar property line in '$Path': $line" }
        $key = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        $result[$key] = $value
    }
    return $result
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

    @($directories | Sort-Object FullName | ForEach-Object { New-SonarProjectCandidate -Config $Config -Directory $_.FullName })
}

function New-SonarProjectCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Directory)

    $root = (Resolve-Path -LiteralPath $Config.rootPath).Path.TrimEnd('\', '/')
    $path = (Resolve-Path -LiteralPath $Directory).Path.TrimEnd('\', '/')
    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Candidate directory must be below rootPath: $path"
    }
    $relative = $path.Substring($root.Length).TrimStart('\', '/')
    $projectName = if ([string]$Config.projectName.mode -eq 'relativePath') {
        ($relative -split '[\\/]' | Where-Object { $_ }) -join [string]$Config.projectName.separator
    } else { Split-Path -Leaf $path }
    if ([bool]$Config.projectName.includePrefix -and -not [string]::IsNullOrWhiteSpace([string]$Config.projectKeyPrefix)) {
        $projectName = "$( [string]$Config.projectKeyPrefix )$([string]$Config.projectName.prefixSeparator)$projectName"
    }
    [pscustomobject]@{
        Name = $projectName
        Path = $path
        RelativePath = $relative
        ProjectKey = ConvertTo-SonarProjectKey -Prefix $Config.projectKeyPrefix -RelativePath $relative
    }
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
    $propertiesFile = [string]$Config.sonar.resolvedPropertiesFile
    if (-not $PSCmdlet.ShouldProcess("$($Candidates.Count) project(s)", "Run scanner with parallelism $parallelism")) { return @() }
    $dummyBinaries = $null
    if ([bool]$Config.scanner.javaBinaries.useDummyWhenMissing) {
        $dummyBinaries = Join-Path ([IO.Path]::GetTempPath()) "sonar-util-empty-classes-$([guid]::NewGuid().ToString('N'))"
        $null = [IO.Directory]::CreateDirectory($dummyBinaries)
    }
    $work = @($Candidates | ForEach-Object {
        $configuredBinaries = Join-Path $_.Path ([string]$Config.scanner.javaBinaries.directory)
        $javaBinaries = if (Test-Path -LiteralPath $configuredBinaries -PathType Container) {
            (Resolve-Path -LiteralPath $configuredBinaries).Path
        } elseif ($dummyBinaries) { $dummyBinaries } else { $null }
        [pscustomobject]@{ Name=$_.Name; Path=$_.Path; ProjectKey=$_.ProjectKey; Executable=$executable; Url=$url; Token=$token; PropertiesFile=$propertiesFile; JavaBinaries=$javaBinaries }
    })
    try {
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
                    $arguments = @("-Dproject.settings=$($workItem.PropertiesFile)", "-Dsonar.projectKey=$($workItem.ProjectKey)", "-Dsonar.projectName=$($workItem.Name)", "-Dsonar.token=$($workItem.Token)")
                    if ($workItem.JavaBinaries) { $arguments += "-Dsonar.java.binaries=$($workItem.JavaBinaries)" }
                    $output = & $workItem.Executable @arguments 2>&1 | Out-String
                    [pscustomobject]@{ ProjectKey=$workItem.ProjectKey; ExitCode=$LASTEXITCODE; Output=$output; JavaBinaries=$workItem.JavaBinaries }
                }
            }
            $done = Wait-Job -Job $running -Any
            $results += Receive-Job -Job $done
            Remove-Job -Job $done
            $running = @($running | Where-Object Id -ne $done.Id)
        }
        return @($results)
    } finally {
        if ($dummyBinaries -and (Test-Path -LiteralPath $dummyBinaries)) { Remove-Item -LiteralPath $dummyBinaries -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function Read-SonarToolConfig, Read-SonarProperties, ConvertTo-SonarProjectKey, Get-SonarProjectCandidates, New-SonarProjectCandidate,
    Test-SonarAuthentication, Test-SonarProjectExists, New-SonarProject, Remove-SonarProject,
    Add-ProjectsToSonarApplication, Invoke-SonarScannerBatch
