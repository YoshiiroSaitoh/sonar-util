[CmdletBinding()]
param([string]$Config = (Join-Path $PSScriptRoot 'sample-config-community.json'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'SonarQubeTool.psm1') -Force

$form = [Windows.Forms.Form]@{ Text='SonarQube Project Tool'; Width=1050; Height=700; StartPosition='CenterScreen' }
$pathBox = [Windows.Forms.TextBox]@{ Left=15; Top=18; Width=810; Text=$Config }
$browse = [Windows.Forms.Button]@{ Left=835; Top=15; Width=90; Text='Browse...' }
$load = [Windows.Forms.Button]@{ Left=930; Top=15; Width=90; Text='Load' }
$list = [Windows.Forms.ListView]@{ Left=15; Top=55; Width=1005; Height=430; CheckBoxes=$true; View='Details'; FullRowSelect=$true; GridLines=$true }
$null = $list.Columns.Add('Name', 180); $null = $list.Columns.Add('Project Key', 260); $null = $list.Columns.Add('Path', 530)
$selectAll = [Windows.Forms.Button]@{ Left=15; Top=500; Width=95; Text='Select all' }
$dryRun = [Windows.Forms.Button]@{ Left=120; Top=500; Width=95; Text='Dry Run' }
$create = [Windows.Forms.Button]@{ Left=225; Top=500; Width=95; Text='Create' }
$scan = [Windows.Forms.Button]@{ Left=330; Top=500; Width=95; Text='Scan' }
$delete = [Windows.Forms.Button]@{ Left=435; Top=500; Width=95; Text='Delete' }
$validate = [Windows.Forms.Button]@{ Left=540; Top=500; Width=110; Text='Validate Token' }
$log = [Windows.Forms.TextBox]@{ Left=15; Top=540; Width=1005; Height=110; Multiline=$true; ReadOnly=$true; ScrollBars='Vertical' }
$form.Controls.AddRange(@($pathBox,$browse,$load,$list,$selectAll,$dryRun,$create,$scan,$delete,$validate,$log))

$script:settings = $null
$script:candidates = @()
function Write-UiLog([string]$Message) { $log.AppendText("$(Get-Date -Format HH:mm:ss) $Message`r`n") }
function Get-SelectedCandidates { @($list.CheckedItems | ForEach-Object { $_.Tag }) }
function Invoke-UiAction([scriptblock]$Action) {
    try { $form.UseWaitCursor=$true; & $Action }
    catch { Write-UiLog "ERROR: $($_.Exception.Message)"; [Windows.Forms.MessageBox]::Show($_.Exception.Message,'SonarQube Tool','OK','Error') | Out-Null }
    finally { $form.UseWaitCursor=$false }
}
function Load-Config {
    $script:settings = Read-SonarToolConfig -Path $pathBox.Text
    $script:candidates = @(Get-SonarProjectCandidates -Config $script:settings)
    $list.Items.Clear()
    foreach ($candidate in $script:candidates) {
        $item = [Windows.Forms.ListViewItem]::new($candidate.Name)
        $null = $item.SubItems.Add($candidate.ProjectKey); $null = $item.SubItems.Add($candidate.Path)
        $item.Tag = $candidate; $null = $list.Items.Add($item)
    }
    Write-UiLog "Loaded $($script:candidates.Count) candidate(s). Application API: $(if ($script:settings.sonar.applicationKey) {'enabled'} else {'disabled'})"
}

$browse.Add_Click({
    $dialog = [Windows.Forms.OpenFileDialog]@{ Filter='JSON config (*.json)|*.json|All files (*.*)|*.*'; FileName=$pathBox.Text }
    if ($dialog.ShowDialog() -eq 'OK') { $pathBox.Text=$dialog.FileName }
})
$load.Add_Click({ Invoke-UiAction { Load-Config } })
$selectAll.Add_Click({ foreach ($item in $list.Items) { $item.Checked=$true } })
$validate.Add_Click({ Invoke-UiAction { if (Test-SonarAuthentication $script:settings) { Write-UiLog 'SONAR_TOKEN is valid.' } else { throw 'SONAR_TOKEN was rejected.' } } })
$dryRun.Add_Click({ Invoke-UiAction {
    $selected = Get-SelectedCandidates
    foreach ($candidate in $selected) {
        $exists = Test-SonarProjectExists $script:settings $candidate.ProjectKey
        Write-UiLog "DRY RUN $($candidate.ProjectKey): $(if ($exists) {'exists; scan would run'} else {'would create and scan'})"
    }
} })
$create.Add_Click({ Invoke-UiAction {
    $selected = Get-SelectedCandidates
    foreach ($candidate in $selected) {
        if (Test-SonarProjectExists $script:settings $candidate.ProjectKey) { Write-UiLog "EXISTS $($candidate.ProjectKey)" }
        else { New-SonarProject $script:settings $candidate; Write-UiLog "CREATED $($candidate.ProjectKey)" }
    }
    Add-ProjectsToSonarApplication $script:settings @($selected.ProjectKey)
} })
$scan.Add_Click({ Invoke-UiAction {
    $results = @(Invoke-SonarScannerBatch $script:settings (Get-SelectedCandidates))
    foreach ($result in $results) { Write-UiLog "SCAN $($result.ProjectKey): exit $($result.ExitCode)" }
} })
$delete.Add_Click({ Invoke-UiAction {
    $selected = Get-SelectedCandidates
    if (-not $selected.Count) { return }
    if ([Windows.Forms.MessageBox]::Show("Delete $($selected.Count) selected project(s)?",'Confirm deletion','YesNo','Warning') -ne 'Yes') { return }
    foreach ($candidate in $selected) { Remove-SonarProject $script:settings $candidate.ProjectKey -Confirm:$false; Write-UiLog "DELETED $($candidate.ProjectKey)" }
} })
$form.Add_Shown({ Invoke-UiAction { Load-Config } })
[void]$form.ShowDialog()
