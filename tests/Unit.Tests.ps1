$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\SonarQubeTool.psm1') -Force
$failures = [Collections.Generic.List[string]]::new()
function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -ne $Actual) { $failures.Add("$Name expected '$Expected', got '$Actual'") }
    else { Write-Output "PASS $Name" }
}
function Assert-Throws([scriptblock]$Action, [string]$Name) {
    try { & $Action; $failures.Add("$Name did not throw") } catch { Write-Output "PASS $Name" }
}

Assert-Equal 'test-api-one' (ConvertTo-SonarProjectKey test 'API One') 'key normalization'
Assert-Equal 'prefix-a-b' (ConvertTo-SonarProjectKey prefix 'A\B') 'path normalization'
Assert-Throws { ConvertTo-SonarProjectKey '' '123' } 'numeric-only key rejection'

$propertyFile = Join-Path ([IO.Path]::GetTempPath()) "sonar-properties-$([guid]::NewGuid()).properties"
try {
    Set-Content -LiteralPath $propertyFile -Value @('# comment','sonar.host.url=http://localhost:9000','sonar.sources=.')
    $properties = Read-SonarProperties $propertyFile
    Assert-Equal 'http://localhost:9000' $properties['sonar.host.url'] 'property file URL'
    Assert-Equal '.' $properties['sonar.sources'] 'property file sources'
} finally { Remove-Item -LiteralPath $propertyFile -Force -ErrorAction SilentlyContinue }

$temp = Join-Path ([IO.Path]::GetTempPath()) "sonar-tool-test-$([guid]::NewGuid())"
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $temp 'alpha') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $temp 'node_modules') -Force
    $config = [pscustomobject]@{ rootPath=$temp; projectKeyPrefix='test'; projectName=[pscustomobject]@{mode='directoryName';separator=' / '}; splitDirectories=@(); excludeDirectories=@('node_modules') }
    $items = @(Get-SonarProjectCandidates $config)
    Assert-Equal 1 $items.Count 'excluded directory'
    Assert-Equal 'test-alpha' $items[0].ProjectKey 'candidate key'

    $nested = Join-Path $temp 'services\api'
    $null = New-Item -ItemType Directory -Path $nested -Force
    $config.splitDirectories = @('services\api')
    $config.projectName.mode = 'relativePath'
    $nestedItems = @(Get-SonarProjectCandidates $config)
    Assert-Equal 'services / api' $nestedItems[0].Name 'relative path project name'
    Assert-Equal 'test-services-api' $nestedItems[0].ProjectKey 'nested candidate key'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }

$moduleText = Get-Content -Raw (Join-Path $PSScriptRoot '..\SonarQubeTool.psm1')
if ($moduleText -match 'IsNullOrWhiteSpace\(\$applicationKey\)\) \{ return \}') { Write-Output 'PASS null application key guard' }
else { $failures.Add('null application key guard missing') }

if ($failures.Count) { $failures | ForEach-Object { Write-Error $_ }; exit 1 }
Write-Output 'All unit tests passed.'
