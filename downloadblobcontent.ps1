<#
.SYNOPSIS
  Recursively download blobs (files/folders) from Azure Storage accounts in a given resource group that match a naming convention.

.DESCRIPTION
  - Authenticates to Azure (interactive or service principal).
  - Finds storage accounts in the given resource group that match a provided name pattern (wildcard or regex).
  - For each matching storage account, lists blobs in the specified container under an optional prefix (folder).
  - Filters blobs by a provided blob name pattern (wildcard or regex).
  - Downloads matched blobs preserving the virtual folder structure to a local destination.

.PARAMETER ResourceGroupName
  Resource group that contains the storage accounts. (Required)

.PARAMETER StorageAccountNamePattern
  Pattern to match storage account names. By default treated as wildcard (-like). (Required)

.PARAMETER UseRegexForStorageAccount
  If set, StorageAccountNamePattern is treated as a regex (-match).

.PARAMETER ContainerName
  Container to search for blobs. (Required)

.PARAMETER BlobPrefix
  Prefix (virtual folder) to limit listing to. e.g. "backups/2025/" or "folder/subfolder/". Optional.

.PARAMETER BlobNamePattern
  Optional pattern to filter blob names within the prefix. Wildcard by default (like). If omitted, all blobs under prefix are matched.

.PARAMETER UseRegexForBlobName
  If set, BlobNamePattern is treated as a regex (-match).

.PARAMETER DestinationPath
  Local folder to download files into. (Required)

.PARAMETER UseServicePrincipal
  Authenticate with a service principal (provide TenantId, ClientId, ClientSecret).

.PARAMETER TenantId
  Tenant ID for service principal auth.

.PARAMETER ClientId
  Client ID for service principal auth.

.PARAMETER ClientSecret
  Client secret for service principal auth.

.PARAMETER WhatIf
  Standard WhatIf support (provided by -WhatIf common parameter).

.EXAMPLE
  .\download-blob-recursive.ps1 -ResourceGroupName my-rg -StorageAccountNamePattern "mystorage*" -ContainerName "files" -BlobPrefix "exports/2025/" -BlobNamePattern "*.zip" -DestinationPath "C:\backups"

.EXAMPLE (regex)
  .\download-blob-recursive.ps1 -ResourceGroupName my-rg -StorageAccountNamePattern "^prod.*storage$" -UseRegexForStorageAccount -ContainerName "data" -DestinationPath "D:\data" -BlobNamePattern ".*(daily|full).*\.tar\.gz$" -UseRegexForBlobName

.NOTES
  - Requires the Az PowerShell modules (Install-Module Az).
  - Uses Get-AzStorageBlob and Get-AzStorageBlobContent.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string]$StorageAccountNamePattern,

    [Parameter(Mandatory=$false)]
    [switch]$UseRegexForStorageAccount,

    [Parameter(Mandatory=$true)]
    [string]$ContainerName,

    [Parameter(Mandatory=$false)]
    [string]$BlobPrefix = "",

    [Parameter(Mandatory=$false)]
    [string]$BlobNamePattern,

    [Parameter(Mandatory=$false)]
    [switch]$UseRegexForBlobName,

    [Parameter(Mandatory=$true)]
    [string]$DestinationPath,

    [Parameter(Mandatory=$false)]
    [switch]$UseServicePrincipal,

    [Parameter(Mandatory=$false)]
    [string]$TenantId,

    [Parameter(Mandatory=$false)]
    [string]$ClientId,

    [Parameter(Mandatory=$false)]
    [string]$ClientSecret
)

function Ensure-AzModule {
    if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
        Write-Error "Az.Storage module not found. Install it first: Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force"
        exit 1
    }
}

Ensure-AzModule

# Authentication
if ($UseServicePrincipal.IsPresent) {
    if (-not ($TenantId -and $ClientId -and $ClientSecret)) {
        Write-Error "When using -UseServicePrincipal you must supply -TenantId, -ClientId and -ClientSecret."
        exit 1
    }
    try {
        $secureSecret = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($ClientId, $secureSecret)
        Connect-AzAccount -ServicePrincipal -Tenant $TenantId -ApplicationId $ClientId -Credential $cred -ErrorAction Stop | Out-Null
        Write-Host "Authenticated with service principal." -ForegroundColor Green
    } catch {
        Write-Error "Service principal login failed: $_"
        exit 1
    }
} else {
    try {
        Connect-AzAccount -ErrorAction Stop | Out-Null
        Write-Host "Authenticated interactively." -ForegroundColor Green
    } catch {
        Write-Error "Interactive login failed: $_"
        exit 1
    }
}

# Ensure destination exists
try {
    if (-not (Test-Path -Path $DestinationPath)) {
        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
    }
} catch {
    Write-Error "Cannot create destination path '$DestinationPath': $_"
    exit 1
}

# Get storage accounts in the resource group
try {
    $allAccounts = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -ErrorAction Stop
} catch {
    Write-Error "Failed to get storage accounts in resource group '$ResourceGroupName': $_"
    exit 1
}

if (-not $allAccounts -or $allAccounts.Count -eq 0) {
    Write-Warning "No storage accounts found in resource group '$ResourceGroupName'."
    exit 0
}

# Filter storage accounts by pattern
if ($UseRegexForStorageAccount.IsPresent) {
    $matchingAccounts = $allAccounts | Where-Object { $_.StorageAccountName -match $StorageAccountNamePattern }
} else {
    $matchingAccounts = $allAccounts | Where-Object { $_.StorageAccountName -like $StorageAccountNamePattern }
}

if (-not $matchingAccounts -or $matchingAccounts.Count -eq 0) {
    Write-Warning "No storage accounts match pattern '$StorageAccountNamePattern' in resource group '$ResourceGroupName'."
    exit 0
}

$summary = @()

foreach ($sa in $matchingAccounts) {
    Write-Host "Processing storage account: $($sa.StorageAccountName)" -ForegroundColor Cyan

    # Build storage context
    try {
        $keys = Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $sa.StorageAccountName -ErrorAction Stop
        $key = $keys[0].Value
        $ctx = New-AzStorageContext -StorageAccountName $sa.StorageAccountName -StorageAccountKey $key
    } catch {
        Write-Warning "Failed to create storage context for $($sa.StorageAccountName): $_"
        continue
    }

    # Verify container exists
    try {
        $container = Get-AzStorageContainer -Name $ContainerName -Context $ctx -ErrorAction Stop
    } catch {
        Write-Warning "Container '$ContainerName' not found in storage account $($sa.StorageAccountName): $_"
        continue
    }

    # Normalize prefix (don't remove if empty)
    $prefix = $BlobPrefix
    if ($prefix -and (-not $prefix.EndsWith("/"))) {
        # Blob list prefixes typically use forward slash; keep what's provided
        # do nothing, allow prefix as-is
        $prefix = $prefix
    }

    Write-Host "Listing blobs in container '$ContainerName' with prefix '$prefix'..." -ForegroundColor DarkCyan

    try {
        # Get-AzStorageBlob returns all blobs with the prefix (it is recursive)
        $blobs = Get-AzStorageBlob -Container $ContainerName -Context $ctx -Prefix $prefix
    } catch {
        Write-Warning "Failed to list blobs in container '$ContainerName' for account $($sa.StorageAccountName): $_"
        continue
    }

    if (-not $blobs -or $blobs.Count -eq 0) {
        Write-Host "No blobs found for prefix '$prefix' in $($sa.StorageAccountName)." -ForegroundColor Yellow
        continue
    }

    # Filter blobs by BlobNamePattern if provided
    if ($BlobNamePattern) {
        if ($UseRegexForBlobName.IsPresent) {
            $matched = $blobs | Where-Object { $_.Name -match $BlobNamePattern }
        } else {
            # treat pattern as wildcard similar to -like
            $matched = $blobs | Where-Object { $_.Name -like $BlobNamePattern }
        }
    } else {
        $matched = $blobs
    }

    if (-not $matched -or $matched.Count -eq 0) {
        Write-Host "No blobs matched pattern in $($sa.StorageAccountName)." -ForegroundColor Yellow
        continue
    }

    foreach ($b in $matched) {
        # Compute relative path under the prefix. If prefix empty, relative is the blob full name.
        if ($prefix) {
            if ($b.Name.StartsWith($prefix)) {
                $relative = $b.Name.Substring($prefix.Length)
                # If prefix ended in '/', trim leading slash
                if ($relative.StartsWith("/")) { $relative = $relative.TrimStart("/") }
            } else {
                # blob name doesn't start with prefix; use full name
                $relative = $b.Name
            }
        } else {
            $relative = $b.Name
        }

        # Local destination path - preserve folder structure
        $localFullPath = Join-Path -Path $DestinationPath -ChildPath $relative
        $localDir = Split-Path -Path $localFullPath -Parent
        if (-not (Test-Path -Path $localDir)) {
            New-Item -Path $localDir -ItemType Directory -Force | Out-Null
        }

        Write-Host "Downloading '$($b.Name)' to '$localFullPath'..." -ForegroundColor Green
        try {
            # Use -Force to overwrite if file exists
            Get-AzStorageBlobContent -Blob $b.Name -Container $ContainerName -Destination $localFullPath -Context $ctx -Force -ErrorAction Stop | Out-Null
            $summary += [PSCustomObject]@{
                StorageAccount = $sa.StorageAccountName
                Container      = $ContainerName
                BlobName       = $b.Name
                LocalPath      = $localFullPath
                Size           = $b.Length
                LastModified   = $b.ICloudBlob.Properties.LastModified.ToString()
                Status         = "Downloaded"
            }
        } catch {
            Write-Warning "Failed to download blob '$($b.Name)' from $($sa.StorageAccountName): $_"
            $summary += [PSCustomObject]@{
                StorageAccount = $sa.StorageAccountName
                Container      = $ContainerName
                BlobName       = $b.Name
                LocalPath      = $localFullPath
                Size           = $b.Length
                LastModified   = ($b.ICloudBlob.Properties.LastModified.ToString())
                Status         = "Failed: $_"
            }
        }
    }
}

# Summary
if ($summary.Count -eq 0) {
    Write-Host "No blobs were downloaded." -ForegroundColor Yellow
} else {
    Write-Host "`nDownload summary:" -ForegroundColor Cyan
    $summary | Format-Table -AutoSize
    # Optionally return summary objects for further processing
    return $summary
}
