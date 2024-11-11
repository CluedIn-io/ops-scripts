<#
    .DESCRIPTION
    Deploys an Automation Account and appropriate runbooks via a pipeline to a customers environment.
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

# Variables
$azCliVersion = '2.56.0'

$runbooks = @{
    # friendlyName = PowerShellScript
    'auto-shutdown-aks' = 'Set-AKSPowerState.ps1'
}

$aksClusterName = az aks list --resource-group $ResourceGroup --subscription $Subscription --query '[].name' --output 'tsv'
if (!$aksClusterName) { throw "Issue obtaining aks details in resource group '$ResourceGroup'" }

$automationAccountName = $aksClusterName.Replace('aks', 'automation')
Write-Host "AutomationAccountName: $automationAccountName"

Write-Host "INFO: Running Automation Account Deployment" -ForegroundColor 'Green'
Write-Host "This may take a few minutes to complete..."
$params = @(
    '--name', 'automation-deployment'
    '--resource-group', $resourceGroup
    '--template-file', "$PSScriptRoot/../IaC/automation-runbooks.bicep"
    '--mode', 'Incremental'
    '--parameters',
        ('automationAccountName={0}' -f $automationAccountName)
        ('aksClusterName={0}' -f $aksClusterName) # Used for role assignment
    '--output', 'none'
)
if ($Subscription) { $params += @('--subscription', $Subscription) }
if ($DryRun) { $params += @('--what-if', '--what-if-exclude-change-types', 'NoChange', 'Ignore') }

az deployment group create @params
if (!$?) { throw "Issue with deploying the automation account" }

$aaBaseUrl = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}' -f @(
    $Subscription, $ResourceGroup, $automationAccountName
)

Write-Host "INFO: Creating new runtime environment" -ForegroundColor 'Green'
$runtimeEnvironmentName = 'pwsh-azcli'
$url = $aaBaseUrl + ('/runtimeEnvironments/{0}?api-version=2023-05-15-preview' -f $runtimeEnvironmentName)

$body = @{
    properties = @{
        runtime = @{
            language = 'PowerShell'
            version = '7.2'
        }
        defaultPackages = @{ 'azure cli' = $azCliVersion }
    }
    name = $runtimeEnvironmentName
} | ConvertTo-Json -Compress -Depth 10
$params = @(
    '--method', 'PUT'
    '--url', $url
    '--body', $body
    '--output', 'none'
)
if (!$DryRun) { az rest @params }

Write-Host "INFO: Uploading Automation Runbooks to '$automationAccountName'" -ForegroundColor 'Green'
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
Write-Host "Automation Accounts and Runbooks process now complete"