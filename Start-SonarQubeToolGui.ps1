[CmdletBinding()]
param([string]$Config = (Join-Path $PSScriptRoot 'sample-config-community.json'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'SonarQubeTool.psm1') -Force

$form = [Windows.Forms.Form]@{ Text='SonarQube Project Tool'; Width=1250; Height=760; StartPosition='CenterScreen'; MinimumSize=[Drawing.Size]::new(1000,650) }
$pathBox = [Windows.Forms.TextBox]@{ Left=15; Top=18; Width=980; Text=$Config; Anchor='Top,Left,Right' }
$browse = [Windows.Forms.Button]@{ Left=1005; Top=15; Width=100; Text='Browse...'; Anchor='Top,Right' }
$load = [Windows.Forms.Button]@{ Left=1115; Top=15; Width=100; Text='Load'; Anchor='Top,Right' }
$rootLabel = [Windows.Forms.Label]@{ Left=15; Top=52; Width=1200; Height=20; Text='Root: (not loaded)'; Anchor='Top,Left,Right' }
$treeLabel = [Windows.Forms.Label]@{ Left=15; Top=77; Width=450; Text='Directories (check any level)' }
$previewLabel = [Windows.Forms.Label]@{ Left=475; Top=77; Width=740; Text='Selected project preview' }
$tree = [Windows.Forms.TreeView]@{ Left=15; Top=98; Width=450; Height=420; CheckBoxes=$true; HideSelection=$false; Anchor='Top,Bottom,Left' }
$preview = [Windows.Forms.ListView]@{ Left=475; Top=98; Width=740; Height=420; View='Details'; FullRowSelect=$true; GridLines=$true; Anchor='Top,Bottom,Left,Right' }
$null=$preview.Columns.Add('Name',220); $null=$preview.Columns.Add('Project Key',235); $null=$preview.Columns.Add('Path',500)
$selectConfigured = [Windows.Forms.Button]@{ Left=15; Top=530; Width=145; Text='Select configured'; Anchor='Bottom,Left' }
$clear = [Windows.Forms.Button]@{ Left=170; Top=530; Width=100; Text='Clear'; Anchor='Bottom,Left' }
$refresh = [Windows.Forms.Button]@{ Left=280; Top=530; Width=100; Text='Refresh tree'; Anchor='Bottom,Left' }
$dryRun = [Windows.Forms.Button]@{ Left=475; Top=530; Width=95; Text='Dry Run'; Anchor='Bottom,Left' }
$create = [Windows.Forms.Button]@{ Left=580; Top=530; Width=95; Text='Create'; Anchor='Bottom,Left' }
$scan = [Windows.Forms.Button]@{ Left=685; Top=530; Width=95; Text='Scan'; Anchor='Bottom,Left' }
$delete = [Windows.Forms.Button]@{ Left=790; Top=530; Width=95; Text='Delete'; Anchor='Bottom,Left' }
$validate = [Windows.Forms.Button]@{ Left=895; Top=530; Width=120; Text='Validate Token'; Anchor='Bottom,Left' }
$log = [Windows.Forms.TextBox]@{ Left=15; Top=570; Width=1200; Height=140; Multiline=$true; ReadOnly=$true; ScrollBars='Vertical'; Anchor='Bottom,Left,Right' }
$form.Controls.AddRange(@($pathBox,$browse,$load,$rootLabel,$treeLabel,$previewLabel,$tree,$preview,$selectConfigured,$clear,$refresh,$dryRun,$create,$scan,$delete,$validate,$log))

$script:settings=$null
$script:suppressTreeEvents=$false
$script:rootNode=$null
function Write-UiLog([string]$Message) { $log.AppendText("$(Get-Date -Format HH:mm:ss) $Message`r`n") }
function Invoke-UiAction([scriptblock]$Action) {
    try { $form.UseWaitCursor=$true; & $Action }
    catch { Write-UiLog "ERROR: $($_.Exception.Message)"; [Windows.Forms.MessageBox]::Show($_.Exception.Message,'SonarQube Tool','OK','Error') | Out-Null }
    finally { $form.UseWaitCursor=$false }
}
function Get-VisibleDirectories([string]$Path) {
    $excluded=@($script:settings.excludeDirectories | ForEach-Object {[string]$_})
    @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction Stop | Where-Object { $excluded -notcontains $_.Name } | Sort-Object Name)
}
function Add-DirectoryNode([Windows.Forms.TreeNodeCollection]$Collection, $Directory) {
    $node=[Windows.Forms.TreeNode]::new($Directory.Name); $node.Name=$Directory.FullName; $node.Tag=$Directory.FullName
    if (@(Get-VisibleDirectories $Directory.FullName).Count) { $dummy=[Windows.Forms.TreeNode]::new('Loading...'); $dummy.Tag=$null; $null=$node.Nodes.Add($dummy) }
    $null=$Collection.Add($node); return $node
}
function Expand-DirectoryNode([Windows.Forms.TreeNode]$Node) {
    if ($Node.Nodes.Count -eq 1 -and $null -eq $Node.Nodes[0].Tag) {
        $Node.Nodes.Clear(); foreach($directory in Get-VisibleDirectories $Node.Tag){$null=Add-DirectoryNode $Node.Nodes $directory}
    }
}
function Get-AllLoadedNodes([Windows.Forms.TreeNodeCollection]$Nodes) {
    @($Nodes | ForEach-Object { $_; if($_.Nodes.Count){Get-AllLoadedNodes $_.Nodes} })
}
function Get-SelectedCandidates {
    if (-not $script:settings) { return @() }
    @(Get-AllLoadedNodes $tree.Nodes | Where-Object {$_.Checked -and $null -ne $_.Tag} | ForEach-Object { New-SonarProjectCandidate $script:settings $_.Tag })
}
function Update-Preview {
    $preview.Items.Clear()
    foreach($candidate in Get-SelectedCandidates){
        $item=[Windows.Forms.ListViewItem]::new($candidate.Name); $null=$item.SubItems.Add($candidate.ProjectKey); $null=$item.SubItems.Add($candidate.Path); $item.Tag=$candidate; $null=$preview.Items.Add($item)
    }
    $previewLabel.Text="Selected project preview ($($preview.Items.Count))"
}
function Update-RootCheckState {
    if (-not $script:rootNode) { return }
    $children=@($script:rootNode.Nodes | Where-Object {$null -ne $_.Tag})
    $allChecked=$children.Count -gt 0 -and @($children | Where-Object {-not $_.Checked}).Count -eq 0
    $script:suppressTreeEvents=$true
    try {$script:rootNode.Checked=$allChecked} finally {$script:suppressTreeEvents=$false}
}
function Set-DescendantsUnchecked([Windows.Forms.TreeNode]$Node) {
    foreach($child in $Node.Nodes){if($null -ne $child.Tag){$child.Checked=$false}; Set-DescendantsUnchecked $child}
}
function Clear-TreeChecks {
    $script:suppressTreeEvents=$true
    try { foreach($node in Get-AllLoadedNodes $tree.Nodes){$node.Checked=$false} } finally {$script:suppressTreeEvents=$false}
    Update-Preview
}
function Find-ChildNode([Windows.Forms.TreeNodeCollection]$Nodes,[string]$FullPath) { @($Nodes | Where-Object {$_.Tag -and [string]::Equals([string]$_.Tag,$FullPath,[StringComparison]::OrdinalIgnoreCase)}) | Select-Object -First 1 }
function Select-RelativeDirectory([string]$RelativePath) {
    $root=(Resolve-Path -LiteralPath $script:settings.rootPath).Path.TrimEnd('\','/')
    $parent=$null; $nodes=$script:rootNode.Nodes; $current=$root
    foreach($part in $RelativePath -split '[\\/]' | Where-Object {$_}){
        $current=Join-Path $current $part
        if($parent){Expand-DirectoryNode $parent}
        $node=Find-ChildNode $nodes $current
        if(-not $node){throw "Configured directory is not visible in tree: $RelativePath"}
        $parent=$node; $nodes=$node.Nodes
    }
    if($parent){$parent.Checked=$true; $parent.EnsureVisible()}
}
function Select-ConfiguredDirectories {
    Clear-TreeChecks
    $configured=@($script:settings.splitDirectories | Where-Object {$_})
    if(-not $configured.Count){$configured=@(Get-VisibleDirectories $script:settings.rootPath | ForEach-Object {$_.Name})}
    $script:suppressTreeEvents=$true
    try { foreach($relative in $configured){Select-RelativeDirectory ([string]$relative)} } finally {$script:suppressTreeEvents=$false}
    # Normalize parent/child overlap through the same selection rule.
    foreach($node in @(Get-AllLoadedNodes $tree.Nodes | Where-Object Checked)){Set-DescendantsUnchecked $node}
    Update-RootCheckState
    Update-Preview
}
function Load-DirectoryTree {
    $script:settings=Read-SonarToolConfig -Path $pathBox.Text
    $root=(Resolve-Path -LiteralPath $script:settings.rootPath).Path
    $rootLabel.Text="Root: $root"
    $tree.Nodes.Clear()
    $script:rootNode=[Windows.Forms.TreeNode]::new("$(Split-Path -Leaf $root)  [check: select direct children]")
    $script:rootNode.Name='__SONAR_ROOT__'; $script:rootNode.Tag=$null
    $null=$tree.Nodes.Add($script:rootNode)
    foreach($directory in Get-VisibleDirectories $root){$null=Add-DirectoryNode $script:rootNode.Nodes $directory}
    $script:rootNode.Expand()
    Select-ConfiguredDirectories
    Write-UiLog "Loaded tree. Selected $($preview.Items.Count) candidate(s). Application API: $(if($script:settings.sonar.applicationKey){'enabled'}else{'disabled'})"
}

$tree.Add_BeforeExpand({param($sender,$eventArgs) Invoke-UiAction {Expand-DirectoryNode $eventArgs.Node}})
$tree.Add_AfterCheck({param($sender,$eventArgs)
    if($script:suppressTreeEvents){return}
    if($eventArgs.Node.Name -eq '__SONAR_ROOT__'){
        $script:suppressTreeEvents=$true
        try { foreach($child in $eventArgs.Node.Nodes){$child.Checked=$eventArgs.Node.Checked;if($eventArgs.Node.Checked){Set-DescendantsUnchecked $child}} } finally {$script:suppressTreeEvents=$false}
        Update-Preview
        return
    }
    if($null -eq $eventArgs.Node.Tag){return}
    $script:suppressTreeEvents=$true
    try {
        if($eventArgs.Node.Checked){
            $parent=$eventArgs.Node.Parent; while($parent){$parent.Checked=$false; $parent=$parent.Parent}
            Set-DescendantsUnchecked $eventArgs.Node
        }
    } finally {$script:suppressTreeEvents=$false}
    Update-RootCheckState
    Update-Preview
})
$browse.Add_Click({$dialog=[Windows.Forms.OpenFileDialog]@{Filter='JSON config (*.json)|*.json|All files (*.*)|*.*';FileName=$pathBox.Text};if($dialog.ShowDialog() -eq 'OK'){$pathBox.Text=$dialog.FileName}})
$load.Add_Click({Invoke-UiAction {Load-DirectoryTree}})
$refresh.Add_Click({Invoke-UiAction {Load-DirectoryTree}})
$selectConfigured.Add_Click({Invoke-UiAction {Select-ConfiguredDirectories}})
$clear.Add_Click({Clear-TreeChecks})
$validate.Add_Click({Invoke-UiAction {if(Test-SonarAuthentication $script:settings){Write-UiLog 'SONAR_TOKEN is valid.'}else{throw 'SONAR_TOKEN was rejected.'}}})
$dryRun.Add_Click({Invoke-UiAction {foreach($candidate in Get-SelectedCandidates){$exists=Test-SonarProjectExists $script:settings $candidate.ProjectKey;Write-UiLog "DRY RUN $($candidate.ProjectKey): $(if($exists){'exists; scan would run'}else{'would create and scan'})"}}})
$create.Add_Click({Invoke-UiAction {$selected=Get-SelectedCandidates;foreach($candidate in $selected){if(Test-SonarProjectExists $script:settings $candidate.ProjectKey){Write-UiLog "EXISTS $($candidate.ProjectKey)"}else{New-SonarProject $script:settings $candidate;Write-UiLog "CREATED $($candidate.ProjectKey)"}};Add-ProjectsToSonarApplication $script:settings @($selected.ProjectKey)}})
$scan.Add_Click({Invoke-UiAction {$results=@(Invoke-SonarScannerBatch $script:settings (Get-SelectedCandidates));foreach($result in $results){Write-UiLog "SCAN $($result.ProjectKey): exit $($result.ExitCode)"}}})
$delete.Add_Click({Invoke-UiAction {$selected=Get-SelectedCandidates;if(-not $selected.Count){return};if([Windows.Forms.MessageBox]::Show("Delete $($selected.Count) selected project(s)?",'Confirm deletion','YesNo','Warning') -ne 'Yes'){return};foreach($candidate in $selected){Remove-SonarProject $script:settings $candidate.ProjectKey -Confirm:$false;Write-UiLog "DELETED $($candidate.ProjectKey)"}}})
$form.Add_Shown({Invoke-UiAction {Load-DirectoryTree}})
if ([Environment]::GetEnvironmentVariable('SONAR_TOOL_GUI_TEST_MODE','Process') -eq '1') {
    Load-DirectoryTree
    Clear-TreeChecks
    $script:rootNode.Checked=$true
    if ($preview.Items.Count -ne $script:rootNode.Nodes.Count) { throw 'Root bulk selection smoke test failed.' }
    Write-Output "GUI smoke test passed: roots=$($tree.Nodes.Count), direct=$($script:rootNode.Nodes.Count), selected=$($preview.Items.Count)"
    return
}
[void]$form.ShowDialog()
