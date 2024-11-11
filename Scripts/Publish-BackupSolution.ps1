<#
    .DESCRIPTION
    Deploys the Backup solution and appropriate runbooks via a pipeline to a customers environment.
    Requires the automation account to be deployed.
#>

[cmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Subscription,
    [switch]$DryRun
)

if ($DryRun) {
    Write-Host '####################################################'
    Write-Host '     This is a DRY RUN. No changes will happen.     '
    Write-Host '####################################################'
}

$runbooks = @{
    # friendlyName = PowerShellScript
    'backup-helm-values' = 'Backup-HelmValues.ps1'
    'backup-cluedin' = 'Backup-CluedIn.ps1'
}

$aksCluster = az aks list --resource-group $ResourceGroup --subscription $Subscription | ConvertFrom-Json
$aksClusterName = $aksCluster.name
if (!$aksClusterName) { throw "Issue obtaining aks details in resource group '$ResourceGroup'" }

$automationAccountName = $aksClusterName.Replace('aks', 'automation')
Write-Host "AutomationAccountName: $automationAccountName"

$storageAccountName = $aksClusterName.Replace('aks-', 'storage')
Write-Host "StorageAccountName: $storageAccountName"

Write-Host "Checking automation account exists"
$params = @(
    '--name', $automationAccountName
    '--resource-group', $ResourceGroup
    '--subscription', $Subscription
    '--output', 'none'
)
az automation account show @params 2>$null
if (!$?) { throw "Automation account '$automationAccountName' doesn't exist or returned an error. You may need to run the automation account pipeline beforehand." }

Write-Host "Deploying Backup Solution" -ForegroundColor 'Green'
Write-Host "This may take a few minutes to complete..."
$params = @(
    '--name', 'backuprestore-deployment'
    '--resource-group', $resourceGroup
    '--template-file', "$PSScriptRoot/../IaC/backup-restore.bicep"
    '--mode', 'Incremental'
    '--parameters',
        ('aksClusterName={0}' -f $aksClusterName)
        ('aksClusterNodeRG={0}' -f $aksCluster.nodeResourceGroup)
        ('automationAccountName={0}' -f $automationAccountName)
        ('storageAccountName={0}' -f $storageAccountName)
    '--output', 'none'
)
if ($Subscription) { $params += @('--subscription', $Subscription) }
if ($DryRun) { $params += @('--what-if', '--what-if-exclude-change-types', 'NoChange', 'Ignore') }

az deployment group create @params
if (!$?) { throw "Issue with deploying the automation account" }

$aaBaseUrl = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}' -f @(
    $Subscription, $ResourceGroup, $automationAccountName
)

$runtimeEnvironmentName = 'pwsh-azcli' # Must match what is deployed via the Publish-AutomationRunbooks script

Write-Host "Uploading Automation Runbooks to '$automationAccountName'" -ForegroundColor 'Green'
$currentRunbooksParams = @(
    '--automation-account-name', $automationAccountName
    '--resource-group', $resourceGroup
)
if ($Subscription) { $currentRunbooksParams += @('--subscription', $Subscription) }
$currentRunbooks =  az automation runbook list @currentRunbooksParams 2>nul | ConvertFrom-Json

# Need to get location for the runbook creation for some reason
$locationParams = @(
    '--name', $automationAccountName
    '--resource-group', $ResourceGroup
    '--subscription', $Subscription
    '--query', 'location'
    '--output', 'tsv'
)
$location = az automation account show @locationParams

foreach ($runbook in $runbooks.keys) {
    if ($runbook -notin $currentRunbooks.name) {
        Write-Host "Creating: $runbook" -ForegroundColor 'Cyan'

        $url = $aaBaseUrl + ('/runbooks/{0}?api-version=2023-05-15-preview' -f $runbook)

        $body = @{
            properties = @{
                runbookType = 'PowerShell'
                runtimeEnvironment = $runtimeEnvironmentName
            }
            location = $location
        } | ConvertTo-Json -Compress
        $params = @(
            '--method', 'PUT'
            '--url', $url
            '--body', $body
            '--output', 'none'
        )
        if (!$DryRun) { az rest @params }
    }

    Write-Host "Uploading content to: $runbook" -ForegroundColor 'Cyan'
    $params = @(
        '--content', "@$PSScriptRoot/../IaC/Runbooks/$($runbooks[$runbook])"
        '--runbook-name', $runbook
        '--output', 'none'
    ) + $currentRunbooksParams
    if (!$DryRun) { az automation runbook replace-content @params 2>nul }

    Write-Host "Publishing runbook" -ForegroundColor 'Cyan'
    $params = @(
        '--runbook-name', $runbook
        '--output', 'none'
    ) + $currentRunbooksParams
    if (!$DryRun) { az automation runbook publish @params 2>nul }
}

if ($DryRun) { $LASTEXITCODE = 0 }
Write-Host "Backup Solution process now complete"