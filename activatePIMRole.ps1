<#
.SYNOPSIS
  Activate an eligible Microsoft Entra (Azure AD) PIM role for the signed-in user using Microsoft Graph PowerShell.

.DESCRIPTION
  - Connects to Microsoft Graph with RoleManagement.ReadWrite.Directory
  - Lists eligible role eligibility schedule instances for the signed-in user
  - Allows interactive selection (or provide RoleDisplayName/RoleDefinitionId)
  - Submits a roleAssignmentScheduleRequest with action = selfActivate

.NOTES
  Requires Microsoft.Graph module and the RoleManagement.ReadWrite.Directory permission.
  Run: Install-Module Microsoft.Graph
  Example usage: .\activate-pim-role.ps1 -Duration "PT4H" -Justification "Incident response"
#>

param(
    [string] $RoleDisplayName = "",
    [string] $RoleDefinitionId = "",
    [string] $Duration = "PT4H",                    # ISO 8601 duration, e.g., PT4H
    [string] $Justification = "Automated activation",
    [string] $TicketNumber = "",
    [string] $TicketSystem = "Automation"
)

function Ensure-GraphConnection {
    $context = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $context) {
        Write-Host "Connecting to Microsoft Graph..."
        Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory","User.Read"
    } else {
        Write-Host "Already connected to Microsoft Graph as $($context.Account)."
    }
}

function Get-MyUserId {
    $account = (Get-MgContext).Account
    if (-not $account) {
        throw "Not connected to Graph. Run Connect-MgGraph first."
    }
    $me = Get-MgUser -UserId $account -ErrorAction Stop
    return $me.Id
}

function Get-EligibleRolesForUser($userId) {
    # Use Graph to find eligibility schedule instances for this principal
    # Query endpoint: /roleManagement/directory/roleEligibilityScheduleInstances?$filter=principalId eq '...'
    $filter = "principalId eq '$userId'"
    $uri = "roleManagement/directory/roleEligibilityScheduleInstances?`$filter=$([System.Uri]::EscapeDataString($filter))&`$expand=roleDefinition"
    $resp = Invoke-MgGraphRequest -Method GET -Uri $uri
    return $resp.value
}

function Choose-Role($eligibleRoles) {
    if (-not $eligibleRoles -or $eligibleRoles.Count -eq 0) {
        throw "No eligible roles found for the current user."
    }

    if ($RoleDefinitionId) {
        $found = $eligibleRoles | Where-Object { $_.roleDefinition.id -eq $RoleDefinitionId -or $_.roleDefinitionId -eq $RoleDefinitionId }
        if ($found) { return $found[0] }
        throw "No matching eligible role found for RoleDefinitionId $RoleDefinitionId"
    }

    if ($RoleDisplayName) {
        $found = $eligibleRoles | Where-Object { $_.roleDefinition.displayName -like "*$RoleDisplayName*" }
        if ($found.Count -eq 1) { return $found[0] }
        if ($found.Count -gt 1) {
            Write-Host "Multiple matches for display name '$RoleDisplayName':"
            $i = 0
            $found | ForEach-Object { Write-Host "[$i] $($_.roleDefinition.displayName) - RoleDefId: $($_.roleDefinition.id)"; $i++ }
            $idx = Read-Host "Pick index"
            return $found[$idx]
        }
        throw "No eligible role with display name matching '$RoleDisplayName' found."
    }

    if ($eligibleRoles.Count -eq 1) {
        return $eligibleRoles[0]
    }

    Write-Host "Multiple eligible roles found. Select one:"
    for ($i=0; $i -lt $eligibleRoles.Count; $i++) {
        $r = $eligibleRoles[$i]
        Write-Host "[$i] $($r.roleDefinition.displayName)  (RoleDefId: $($r.roleDefinition.id))"
    }
    $choice = Read-Host "Enter selection index"
    return $eligibleRoles[$choice]
}

function Activate-Role($principalId, $roleDefinitionId, $directoryScopeId, $startDateTime, $duration, $justification, $ticketNumber, $ticketSystem) {
    $body = @{
        action = "selfActivate"
        principalId = $principalId
        roleDefinitionId = $roleDefinitionId
        directoryScopeId = $directoryScopeId
        justification = $justification
        scheduleInfo = @{
            startDateTime = $startDateTime
            expiration = @{
                type = "AfterDuration"
                duration = $duration
            }
        }
        ticketInfo = @{
            ticketNumber = $ticketNumber
            ticketSystem = $ticketSystem
        }
    }

    $json = $body | ConvertTo-Json -Depth 6
    Write-Host "Submitting role activation request..."
    $resp = Invoke-MgGraphRequest -Method POST -Uri "roleManagement/directory/roleAssignmentScheduleRequests" -Body $json -ContentType "application/json"
    return $resp
}

# Main flow
try {
    Ensure-GraphConnection
    $userId = Get-MyUserId
    Write-Host "Current user object id: $userId"

    $eligible = Get-EligibleRolesForUser -userId $userId
    $chosen = Choose-Role -eligibleRoles $eligible

    $roleDefId = if ($chosen.roleDefinition) { $chosen.roleDefinition.id } else { $chosen.roleDefinitionId }
    $directoryScopeId = if ($chosen.directoryScope) { $chosen.directoryScope.id } elseif ($chosen.directoryScopeId) { $chosen.directoryScopeId } else { "/" }

    $start = (Get-Date).ToUniversalTime().ToString("o")

    $result = Activate-Role -principalId $userId -roleDefinitionId $roleDefId -directoryScopeId $directoryScopeId -startDateTime $start -duration $Duration -justification $Justification -ticketNumber $TicketNumber -ticketSystem $TicketSystem

    Write-Host "Activation request returned:"
    $result | ConvertTo-Json -Depth 6 | Write-Host
    Write-Host "If the request was accepted you will see a scheduleRequest object and then PIM will process it."
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
