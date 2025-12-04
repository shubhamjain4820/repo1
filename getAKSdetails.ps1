<#
.SYNOPSIS
  Find AKS clusters in a given Resource Group, collect subscription + credential info, detect kubelogin, and export details to a file.

.DESCRIPTION
  - Looks up AKS (managedClusters) in the specified Resource Group.
  - For each AKS cluster it:
      * Parses the subscription id from the cluster resource id
      * (If Azure CLI "az" is available) fetches kubeconfig for the cluster into a temp file using az aks get-credentials
      * Detects whether "kubelogin" is installed and returns a version string if available
  - Exports a JSON file (default) containing cluster details, subscription id, path to the kubeconfig file and kubelogin info.
  - If Azure CLI is not installed, the script still returns cluster + subscription info but will skip kubeconfig fetching.

.PARAMETER ResourceGroupName
  The name of the resource group to search for AKS clusters.

.PARAMETER OutputFile
  Path to output file. Default: .\aks-clusters-info.json

.PARAMETER IncludeKubeconfigContent
  If set, the script will also include the kubeconfig file content (base64-encoded) in the exported JSON.
  Note: encoding kubeconfig into the JSON increases size and may include secrets.

.PARAMETER OverwriteKubeconfigFiles
  If set, existing temp kubeconfig files for the same cluster will be overwritten.

.EXAMPLE
  .\get-aks-info-from-rg.ps1 -ResourceGroupName "rg-demo" -OutputFile "aks-info.json" -IncludeKubeconfigContent -OverwriteKubeconfigFiles

.NOTES
  - Requires Az module installed and you should be signed in via Connect-AzAccount (or az login for Azure CLI credential fetching).
  - Prefers Azure CLI (az) to fetch kubeconfigs. If az is missing, kubeconfig fetching is skipped.
  - The script will not change or persist your Azure CLI login; it simply calls az with --subscription when fetching credentials.
#>

param(
    [Parameter(Mandatory=$true)]
    [string] $ResourceGroupName,

    [string] $OutputFile = ".\aks-clusters-info.json",

    [switch] $IncludeKubeconfigContent,

    [switch] $OverwriteKubeconfigFiles
)

function Ensure-AzModule {
    if (-not (Get-Module -ListAvailable -Name Az)) {
        Write-Host "Az module not found. Installing Az module (will require internet)..."
        Install-Module -Name Az -Scope CurrentUser -Force
    }
}

function Connect-IfNeeded {
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        Write-Host "No Az context detected. Connecting to Azure..."
        Connect-AzAccount -ErrorAction Stop
    } else {
        Write-Host "Using Azure account: $($ctx.Account)"
    }
}

function Get-ResourceGroup {
    param($name)
    $rg = Get-AzResourceGroup -Name $name -ErrorAction SilentlyContinue
    if (-not $rg) {
        throw "Resource group '$name' not found in the currently selected subscription context. Consider signing in or selecting the correct subscription."
    }
    return $rg
}

function Parse-SubscriptionIdFromResourceId {
    param($resourceId)
    # resourceId format: /subscriptions/{subId}/resourceGroups/{rgName}/...
    if (-not $resourceId) { return $null }
    $parts = $resourceId -split '/'
    # parts[0] is empty due to leading slash, parts[2] should be subscription id
    if ($parts.Length -ge 3) { return $parts[2] }
    return $null
}

function Find-AksClustersInRg {
    param($rgName)
    # Get-AzAks is provided by Az.Aks; fallback to generic resource query if not available
    $aksCmd = Get-Command -Name Get-AzAks -ErrorAction SilentlyContinue
    if ($aksCmd) {
        return Get-AzAks -ResourceGroupName $rgName -ErrorAction Stop
    } else {
        Write-Warning "Get-AzAks not available in Az module. Falling back to generic resource query for managedClusters."
        $resources = Get-AzResource -ResourceGroupName $rgName -ResourceType "Microsoft.ContainerService/managedClusters" -ErrorAction SilentlyContinue
        if (-not $resources) { return @() }
        # Normalize to objects that have Name and Id and Location
        return $resources | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.Name
                Id = $_.ResourceId
                Location = $_.Location
                Type = $_.ResourceType
                Raw = $_
            }
        }
    }
}

function Fetch-Kubeconfig-WithAz {
    param(
        [string] $clusterName,
        [string] $rgName,
        [string] $subscriptionId,
        [bool] $overwrite
    )

    $safeName = $clusterName -replace '[^a-zA-Z0-9\-]','-'
    $tempFile = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("kubeconfig_{0}_{1}.yaml" -f $safeName, (Get-Random -Maximum 100000))
    if ((Test-Path $tempFile) -and -not $overwrite) {
        # create a different name if file exists and not allowed to overwrite
        $tempFile = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("kubeconfig_{0}_{1}_{2}.yaml" -f $safeName, (Get-Random -Maximum 100000), (Get-Date -UFormat %s))
    }

    # Build az args and call
    $args = @("aks","get-credentials","--resource-group",$rgName,"--name",$clusterName,"--subscription",$subscriptionId,"--file",$tempFile,"--overwrite-existing")
    Write-Host "Running: az $($args -join ' ')"
    $proc = Start-Process -FilePath "az" -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardOutput ([IO.Path]::Combine([IO.Path]::GetTempPath(), "az_aks_output_$((Get-Random).ToString()).log")) -RedirectStandardError ([IO.Path]::Combine([IO.Path]::GetTempPath(), "az_aks_error_$((Get-Random).ToString()).log"))
    if ($proc.ExitCode -ne 0) {
        Write-Warning "az aks get-credentials returned exit code $($proc.ExitCode). Kubeconfig not saved."
        return $null
    }

    if (Test-Path $tempFile) {
        return $tempFile
    } else {
        Write-Warning "az succeeded but kubeconfig file not found at expected path $tempFile."
        return $null
    }
}

function Detect-Kubelogin {
    # Check for kubelogin in PATH
    $kubeloginCmd = Get-Command -Name kubelogin -ErrorAction SilentlyContinue
    if ($kubeloginCmd) {
        # Try to get a version string
        $version = $null
        try {
            # Try common version flags; capture output
            $verOut = & kubelogin version 2>&1
            if (-not $verOut) { $verOut = & kubelogin --version 2>&1 }
            $version = ($verOut | Out-String).Trim()
        } catch {
            $version = "kubelogin found at $($kubeloginCmd.Path) (version unknown)"
        }
        return [PSCustomObject]@{
            Installed = $true
            Path = $kubeloginCmd.Path
            Version = $version
        }
    } else {
        return [PSCustomObject]@{
            Installed = $false
            Path = $null
            Version = $null
        }
    }
}

### MAIN ###
try {
    Ensure-AzModule
    Connect-IfNeeded

    $rg = Get-ResourceGroup -name $ResourceGroupName
    Write-Host "Resource Group '$ResourceGroupName' found. Location: $($rg.Location)."

    $aksClusters = Find-AksClustersInRg -rgName $ResourceGroupName
    if (-not $aksClusters -or $aksClusters.Count -eq 0) {
        Write-Warning "No AKS clusters (Microsoft.ContainerService/managedClusters) found in resource group '$ResourceGroupName'."
        $result = @{
            ResourceGroup = $ResourceGroupName
            Clusters = @()
            CheckedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
        $result | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputFile -Encoding utf8
        Write-Host "Wrote empty result to $OutputFile"
        exit 0
    }

    # Detect kubelogin once
    $kubeloginInfo = Detect-Kubelogin()

    $resultClusters = @()
    $azAvailable = (Get-Command -Name az -ErrorAction SilentlyContinue) -ne $null
    if (-not $azAvailable) {
        Write-Warning "Azure CLI 'az' not found. The script will skip kubeconfig fetching. Install Azure CLI to enable credential export (https://docs.microsoft.com/cli/azure/install-azure-cli)."
    }

    foreach ($c in $aksClusters) {
        # Normalize cluster object: if it comes from Get-AzAks it has .Id .Name .Location etc; if from generic resource query use the normalized fields
        $clusterName = $c.Name
        $clusterId = if ($c.Id) { $c.Id } elseif ($c.ResourceId) { $c.ResourceId } else { $c.Raw.ResourceId }
        $clusterLocation = if ($c.Location) { $c.Location } else { $c.Location }

        $subscriptionId = Parse-SubscriptionIdFromResourceId -resourceId $clusterId

        $kubeconfigPath = $null
        $kubeconfigBase64 = $null
        if ($azAvailable) {
            try {
                $kubeconfigPath = Fetch-Kubeconfig-WithAz -clusterName $clusterName -rgName $ResourceGroupName -subscriptionId $subscriptionId -overwrite:$OverwriteKubeconfigFiles.IsPresent
                if ($kubeconfigPath -and $IncludeKubeconfigContent.IsPresent) {
                    $bytes = [System.IO.File]::ReadAllBytes($kubeconfigPath)
                    $kubeconfigBase64 = [System.Convert]::ToBase64String($bytes)
                }
            } catch {
                Write-Warning "Failed fetching kubeconfig for $clusterName: $_"
            }
        }

        $entry = [PSCustomObject]@{
            ClusterName = $clusterName
            ResourceGroup = $ResourceGroupName
            Location = $clusterLocation
            ResourceId = $clusterId
            SubscriptionId = $subscriptionId
            KubeconfigPath = $kubeconfigPath
            KubeconfigBase64 = $kubeconfigBase64
            Kubelogin = $kubeloginInfo
        }

        $resultClusters += $entry
    }

    $outObj = [PSCustomObject]@{
        ResourceGroup = $ResourceGroupName
        Location = $rg.Location
        CheckedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        AzCliAvailable = $azAvailable
        Clusters = $resultClusters
    }

    # Export to JSON
    $outObj | ConvertTo-Json -Depth 6 | Out-File -FilePath $OutputFile -Encoding utf8
    Write-Host "Wrote AKS cluster details to $OutputFile"

    # Print summary
    Write-Host "`nSummary:"
    foreach ($c in $outObj.Clusters) {
        Write-Host " - $($c.ClusterName) | Subscription: $($c.SubscriptionId) | Kubeconfig: $([System.IO.Path]::GetFileName($c.KubeconfigPath)) | Kubelogin.Installed: $($c.Kubelogin.Installed)"
    }

} catch {
    Write-Error "An error occurred: $_"
    exit 1
}
