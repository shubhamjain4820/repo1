<#
.SYNOPSIS
  Create an Azure Key Vault, create an Azure AD application with a client secret, add the app's service principal to the Key Vault access policy,
  and (optionally) store the app secret as a Key Vault secret.

.NOTES
  - Requires Az PowerShell module and Microsoft.Graph PowerShell module.
    Install-Module Az -Scope CurrentUser
    Install-Module Microsoft.Graph -Scope CurrentUser
  - Registering an app requires directory-level permissions. Connect-MgGraph must be granted Application.ReadWrite.All and Directory.ReadWrite.All (admin consent).
  - Run from an account that has appropriate rights to create Key Vaults and create app registrations (Global Admin / Application Administrator or granted consent).
#>

param(
    [Parameter(Mandatory=$true)]
    [string] $SubscriptionId,

    [Parameter(Mandatory=$true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string] $Location,

    [Parameter(Mandatory=$true)]
    [string] $KeyVaultName,

    [Parameter(Mandatory=$true)]
    [string] $AdAppDisplayName,

    [int] $SecretValidityYears = 2,

    [switch] $StoreAppSecretInKeyVault = $false,

    [string] $KeyVaultSecretName = "secret"
)

function Ensure-Modules {
    if (-not (Get-Module -ListAvailable -Name Az)) {
        Write-Host "Installing Az module..."
        Install-Module -Name Az -Scope CurrentUser -Force
    }

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
        Write-Host "Installing Microsoft.Graph module..."
        Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force
    }
}

function Connect-Azure {
    Write-Host "Connecting to Azure..."
    Connect-AzAccount -ErrorAction Stop
    Select-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
}

function Connect-Graph {
    # These scopes are required to create app registrations and service principals
    $scopes = @("Application.ReadWrite.All","Directory.ReadWrite.All")
    Write-Host "Connecting to Microsoft Graph (requires admin consent for app registration scopes)..."
    Connect-MgGraph -Scopes $scopes -ErrorAction Stop
}

function Create-KeyVault {
    Write-Host "Creating (or getting) resource group $ResourceGroupName in $Location..."
    if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
    }

    Write-Host "Creating Key Vault $KeyVaultName..."
    # If vault exists this will throw; handle existence gracefully
    $vault = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction SilentlyContinue
    if (-not $vault) {
        $vault = New-AzKeyVault -Name $KeyVaultName -ResourceGroupName $ResourceGroupName -Location $Location -Sku Standard -EnabledForDeployment $false -EnabledForDiskEncryption $false -EnabledForTemplateDeployment $false
    } else {
        Write-Host "Key Vault $KeyVaultName already exists. Using existing Vault."
    }
    return $vault
}

function Create-AdAppWithSecret {
    param(
        [string] $DisplayName,
        [int] $ValidityYears
    )

    Write-Host "Creating Azure AD application '$DisplayName'..."
    $app = New-MgApplication -DisplayName $DisplayName

    # Generate a reasonably strong client secret if not provided
    $plainSecret = [System.Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Maximum 256 }))

    $pwdBody = @{
        displayName = "$DisplayName-client-secret"
        secretText  = $plainSecret
        endDateTime = (Get-Date).AddYears($ValidityYears).ToUniversalTime().ToString("o")
    }

    Write-Host "Adding client secret to the application (valid for $ValidityYears year(s))..."
    # Create a password credential for the app
    $pwd = New-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential $pwdBody

    Write-Host "Creating service principal for the application..."
    # Create service principal so we have an objectId to use in KeyVault access policy
    $sp = New-MgServicePrincipal -AppId $app.AppId

    return [PSCustomObject]@{
        AppObjectId    = $app.Id          # application object id
        AppId          = $app.AppId       # client id
        ServicePrincipalObjectId = $sp.Id # SP object id (use this in KeyVault access policy)
        ClientSecret   = $plainSecret
        SecretId       = $pwd.Id
        SecretEndDate  = $pwd.EndDateTime
    }
}

function Grant-KeyVaultAccessToSp {
    param(
        [string] $VaultName,
        [string] $SpObjectId
    )

    Write-Host "Granting Key Vault access policy to service principal $SpObjectId..."
    # Give typical secret permissions (adjust as needed)
    $secretPerms = @("get","list","set","delete","recover","backup","restore")
    $keyPerms    = @("get","list")
    $certPerms   = @("get","list")
    # Use Add-AzKeyVaultAccessPolicy to add (does not remove other policies)
    Add-AzKeyVaultAccessPolicy -VaultName $VaultName -ObjectId $SpObjectId -PermissionsToSecrets $secretPerms -PermissionsToKeys $keyPerms -PermissionsToCertificates $certPerms -ErrorAction Stop
}

function Store-SecretInVault {
    param(
        [string] $VaultName,
        [string] $SecretName,
        [string] $SecretPlain
    )
    Write-Host "Storing client secret into Key Vault as secret '$SecretName' (value will be written once to console)..."
    $secureValue = ConvertTo-SecureString -String $SecretPlain -AsPlainText -Force
    $kvSecret = Set-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -SecretValue $secureValue -ErrorAction Stop
    return $kvSecret
}

# main
try {
    Ensure-Modules

    Connect-Azure
    Connect-Graph

    $vault = Create-KeyVault

    $appInfo = Create-AdAppWithSecret -DisplayName $AdAppDisplayName -ValidityYears $SecretValidityYears

    # Grant the service principal access to Key Vault
    Grant-KeyVaultAccessToSp -VaultName $KeyVaultName -SpObjectId $appInfo.ServicePrincipalObjectId

    if ($StoreAppSecretInKeyVault) {
        $kvSecret = Store-SecretInVault -VaultName $KeyVaultName -SecretName $KeyVaultSecretName -SecretPlain $appInfo.ClientSecret
    }

    Write-Host "`n--- RESULT ---"
    Write-Host "Application Display Name : $AdAppDisplayName"
    Write-Host "Application (client) Id  : $($appInfo.AppId)"
    Write-Host "Application object Id    : $($appInfo.AppObjectId)"
    Write-Host "Service Principal object Id : $($appInfo.ServicePrincipalObjectId)"
    Write-Host "Client secret (plain text) : $($appInfo.ClientSecret)"
    if ($StoreAppSecretInKeyVault) {
        Write-Host "Client secret stored in Key Vault as: $KeyVaultSecretName"
    } else {
        Write-Host "Client secret NOT stored in Key Vault. You must persist it securely now."
    }

    Write-Host "`nReminder: This script printed the client secret once. Store it securely; it cannot be retrieved later from the application object."
}
catch {
    Write-Error "Error: $_"
    throw
}
