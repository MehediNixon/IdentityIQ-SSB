<#
.SYNOPSIS
    Identifies service accounts in Active Directory that are missing Manager and/or
    Notes (info) attributes, resolves the correct value from an Excel source file
    (using the CyberArk Safe -> Safe Access Group Owner mapping), and updates AD.

.DESCRIPTION
    Source of truth: an Excel export containing one row per service account, with
    columns describing the account, its CyberArk Safe, and the Safe's access-group
    owner (both as a display name and as a resolvable domain\samAccountName).

    For every row where the AD account is actually missing Manager and/or Notes
    (the Excel columns are only used to build the initial candidate list — the
    live AD attribute value is always re-checked before any write, so existing
    valid AD values are never overwritten):

        1. Verify the service account exists in AD.
        2. Look up the CyberArk Safe for that account.
        3. Look up the Safe's access-group owner (prefer the ready-made
           "Safe Access Group Owner Accounts" column; fall back to resolving
           the "Safe Access Group Owner Names" display name via Get-ADUser).
        4. If exactly one owner resolves to exactly one AD user, use that user
           as the new Manager. If Notes/info is also missing, build a short
           descriptive note referencing the Safe and the owner.
        5. Log every account processed (updated, skipped, or errored) with full
           before/after values to a CSV report.

    The script never writes to AD unless -Mode Update is passed. Even in Update
    mode, it is a native PowerShell ShouldProcess cmdlet, so -WhatIf and -Confirm
    both work normally on top of the built-in Report mode.

.PARAMETER ExcelPath
    Path to the source .xlsx file.

.PARAMETER WorksheetName
    Worksheet to read. Defaults to 'Sheet1'.

.PARAMETER Mode
    'Report'  (default) - analyze only, write the CSV report, change nothing in AD.
    'Update'  - after the same analysis, actually apply the changes to AD.

.PARAMETER OwnerDelimiter
    Delimiter used to split multi-value owner cells (some Safes have more than
    one owner listed in a single cell). Defaults to ';'. Change to ',' only if
    you are certain owner display names never contain a comma themselves
    (this file's "Last, First" name format makes ',' unsafe as a delimiter).

.PARAMETER NotesAttribute
    Which AD attribute Excel's "Notes" concept should be written to.
    IMPORTANT: In ADUC, the tab literally labelled "Notes" on a user object is
    backed by the LDAP attribute 'info' — NOT 'description' (Description is a
    separate, distinct field). Defaults to 'info'. Set to 'description' only if
    that is genuinely what your organization means by "Notes" here.

.PARAMETER OutputFolder
    Folder to write the CSV report and transcript log to. Defaults to the
    script's own folder.

.PARAMETER Server
    Optional. A specific domain controller or domain FQDN to target for every
    AD read/write in this run (e.g. 'dc01.corp.contoso.com' or 'corp.contoso.com').
    If omitted, the ActiveDirectory module falls back to its normal automatic
    site/DC discovery using your current logon session — which is fine for a
    single-domain environment, but should be set explicitly in multi-domain /
    multi-forest environments so you know exactly which domain is being written to.

.PARAMETER Credential
    Optional. A PSCredential to run every AD read/write as, instead of the
    account currently running the script. Prompts interactively if you pass
    -Credential without a value, e.g.:
        -Credential (Get-Credential)
    Useful when the account you're logged in as does not have write permission
    to the Manager/Notes attributes on these service account OUs.

.EXAMPLE
    # Dry run / report only — always run this first.
    .\Update-ServiceAccountManagerNotes.ps1 -ExcelPath 'C:\Data\AD-ServiceAccountFile.xlsx' -Mode Report

.EXAMPLE
    # Report mode, explicitly targeting a specific domain controller:
    .\Update-ServiceAccountManagerNotes.ps1 -ExcelPath 'C:\Data\AD-ServiceAccountFile.xlsx' -Mode Report -Server 'dc01.corp.contoso.com'

.EXAMPLE
    # Review the CSV report from the run above, then apply the changes for real,
    # with an extra interactive confirmation prompt per account, using a
    # specific privileged account rather than your own logon:
    .\Update-ServiceAccountManagerNotes.ps1 -ExcelPath 'C:\Data\AD-ServiceAccountFile.xlsx' -Mode Update -Confirm -Server 'dc01.corp.contoso.com' -Credential (Get-Credential)

.EXAMPLE
    # Apply changes but simulate them first via PowerShell's native -WhatIf
    # (prints what Set-ADUser WOULD do, without touching AD, even in Update mode):
    .\Update-ServiceAccountManagerNotes.ps1 -ExcelPath 'C:\Data\AD-ServiceAccountFile.xlsx' -Mode Update -WhatIf

.NOTES
    Required modules  : ActiveDirectory (RSAT), ImportExcel (PowerShell Gallery)
    Required rights    : Read access to AD; Write access to the Manager/Notes(info)
                          attributes of the target service account OUs.
    Tested pattern      : PowerShell 5.1 / 7.x
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ExcelPath,

    [string]$WorksheetName = 'Sheet1',

    [ValidateSet('Report', 'Update')]
    [string]$Mode = 'Report',

    [string]$OwnerDelimiter = ';',

    [ValidateSet('info', 'description')]
    [string]$NotesAttribute = 'info',

    [string]$OutputFolder = $PSScriptRoot,

    [string]$Server,

    [System.Management.Automation.PSCredential]$Credential
)

# Every Get-ADUser / Set-ADUser call in this script is splatted with $ADConnectionParams,
# so -Server / -Credential (if supplied) apply consistently to every single AD call —
# there is no call anywhere in this script that silently falls back to a different
# identity or a different domain controller than the one shown in the connectivity
# check below.
$ADConnectionParams = @{}
if ($Server)     { $ADConnectionParams['Server']     = $Server }
if ($Credential) { $ADConnectionParams['Credential'] = $Credential }

#region ---------------------------------------------------------------------
# COLUMN MAPPING - adjust here if your Excel headers differ, without touching
# any logic further down. These names must match the source file's headers
# exactly (case-insensitive).
#endregion --------------------------------------------------------------------
$Col_ServiceAccount   = 'Samaccountname'                       # preferred unique key
$Col_AccountFallback  = 'Account'                              # domain\sam, used if Samaccountname blank
$Col_Manager          = 'Manager'
$Col_ManagedBy        = 'ManagedBy'                             # reported only, never written
$Col_Notes            = 'Notes'
$Col_Safe             = 'CyberArk Safes'
$Col_OwnerName        = 'Safe Access Group Owner Names'         # "Last, First" display name
$Col_OwnerAccount     = 'Safe Access Group Owner Accounts'      # domain\samAccountName - preferred for resolution

$RequiredColumns = @(
    $Col_ServiceAccount, $Col_AccountFallback, $Col_Manager, $Col_ManagedBy,
    $Col_Notes, $Col_Safe, $Col_OwnerName, $Col_OwnerAccount
)

# This source file has a duplicate header ("AccountlsDisabled" appears twice),
# which makes Import-Excel's automatic header detection fail. To make import
# reliable regardless of that, headers are supplied explicitly, in the exact
# column order of the known source file. If your file's column order differs,
# update this array to match (order must mirror row 1 of the worksheet).
$ExplicitHeaders = @(
    'Account', 'Samaccountname', 'Mail', 'InteractiveLogon', 'InteractiveLogonGroup',
    'AD LastLogon', 'AD PasswordLastSet', 'Logon Age', 'Password Age', 'Manager',
    'ManagedBy', 'Notes', 'Notes Data Current', 'AccountlsDisabled', 'AccountlsDisabled2',
    'Description', 'CyberArk Safes', 'Safe Access Groups', 'Safe Access Group Owner Names',
    'Safe Access Group Owner Accounts', 'Safe Access Group Owner Emails',
    'Safe Access Group Owner Notes', 'msds-cloudextensionattribute', 'extensionAttribute11',
    'extensionAttribute7', 'department', 'given', 'givenName', 'sn',
    'physicalDeliveryOfficeName', 'extensionAttribute12', 'extensionAttribute1',
    'telephoneNumber', 'title', 'employeeType'
)

#region ---------------------------------------------------------------------
# SETUP: modules, output paths, logging
#endregion --------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$reportPath = Join-Path $OutputFolder "ServiceAccount_ManagerNotes_Report_$timestamp.csv"
$logPath    = Join-Path $OutputFolder "ServiceAccount_ManagerNotes_Log_$timestamp.txt"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $line | Tee-Object -FilePath $logPath -Append | Out-Null
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

Write-Log "=== Service Account Manager/Notes Update - Mode: $Mode ==="
Write-Log "Source file: $ExcelPath"

foreach ($mod in @('ActiveDirectory', 'ImportExcel')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Log "Required module '$mod' is not installed. Install it (e.g. 'Install-Module ImportExcel -Scope CurrentUser') and re-run." 'ERROR'
        throw "Missing required module: $mod"
    }
    Import-Module $mod -ErrorAction Stop
}

#region ---------------------------------------------------------------------
# AD CONNECTIVITY CHECK - confirms which domain/DC and which identity every
# subsequent Get-ADUser / Set-ADUser call in this script will actually use,
# BEFORE any row is processed. Aborts immediately if AD isn't reachable at all.
#endregion --------------------------------------------------------------------
try {
    $domainInfo = Get-ADDomain @ADConnectionParams -ErrorAction Stop
    $whoAmI     = if ($Credential) { $Credential.UserName } else { "$env:USERDOMAIN\$env:USERNAME (current session)" }
    $dcUsed     = if ($Server) { $Server } else { "$($domainInfo.PDCEmulator) (auto-discovered)" }

    Write-Log "AD connectivity OK."
    Write-Log "  Domain      : $($domainInfo.DNSRoot)"
    Write-Log "  DC in use   : $dcUsed"
    Write-Log "  Running as  : $whoAmI"
}
catch {
    Write-Log "Could not contact Active Directory with the given -Server/-Credential. Aborting before reading Excel or touching any account." 'ERROR'
    Write-Log "Underlying error: $($_.Exception.Message)" 'ERROR'
    throw
}

#region ---------------------------------------------------------------------
# READ + VALIDATE EXCEL
#endregion --------------------------------------------------------------------
Write-Log "Reading worksheet '$WorksheetName'..."
try {
    $rawRows = Import-Excel -Path $ExcelPath -WorksheetName $WorksheetName `
                             -HeaderName $ExplicitHeaders -StartRow 2 -ErrorAction Stop
}
catch {
    Write-Log "Failed to read Excel file: $($_.Exception.Message)" 'ERROR'
    throw
}

$missingCols = $RequiredColumns | Where-Object { $_ -notin $ExplicitHeaders }
if ($missingCols) {
    Write-Log "Excel file is missing required column(s): $($missingCols -join ', ')" 'ERROR'
    throw "Required columns not found. Aborting before touching AD."
}
Write-Log "Loaded $($rawRows.Count) row(s) from source file."

#region ---------------------------------------------------------------------
# HELPER FUNCTIONS
#endregion --------------------------------------------------------------------

function Get-CleanSamAccountName {
    <# Accepts either a plain samAccountName or a domain\samAccountName string
       and returns just the samAccountName portion. #>
    param([string]$RawValue)
    if ([string]::IsNullOrWhiteSpace($RawValue)) { return $null }
    if ($RawValue -match '\\') { return ($RawValue -split '\\')[-1].Trim() }
    return $RawValue.Trim()
}

function Resolve-SafeOwner {
    <#
        Determines the single AD user responsible for a Safe, given the row's
        owner-name and owner-account cell values. Returns a hashtable:
          @{ Success = $true/$false; ADUser = <ADUser or $null>;
             Reason  = <string, only when Success = $false>;
             OwnerRawNames = <string used for logging> }
        Handles: missing owner, multiple owners, unresolvable owner.
    #>
    param(
        [string]$OwnerNamesRaw,
        [string]$OwnerAccountsRaw,
        [string]$Delimiter,
        [hashtable]$ADConnectionParams = @{}
    )

    if ([string]::IsNullOrWhiteSpace($OwnerNamesRaw) -and [string]::IsNullOrWhiteSpace($OwnerAccountsRaw)) {
        return @{ Success = $false; ADUser = $null; Reason = 'Owner missing on source row'; OwnerRawNames = $null }
    }

    # Prefer the ready-made account column: it is already an AD-resolvable identity
    # (domain\samAccountName) and avoids ambiguous display-name matching.
    $accountTokens = @()
    if (-not [string]::IsNullOrWhiteSpace($OwnerAccountsRaw)) {
        $accountTokens = $OwnerAccountsRaw -split [regex]::Escape($Delimiter) |
                         ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    }

    if ($accountTokens.Count -gt 1) {
        return @{ Success = $false; ADUser = $null; Reason = "Multiple owners found ($($accountTokens -join ', '))"; OwnerRawNames = $OwnerNamesRaw }
    }

    if ($accountTokens.Count -eq 1) {
        $sam = Get-CleanSamAccountName -RawValue $accountTokens[0]
        try {
            $u = Get-ADUser -Identity $sam -Properties DistinguishedName @ADConnectionParams -ErrorAction Stop
            return @{ Success = $true; ADUser = $u; Reason = $null; OwnerRawNames = $OwnerNamesRaw }
        }
        catch {
            return @{ Success = $false; ADUser = $null; Reason = "Owner account '$sam' could not be resolved in AD ($($_.Exception.Message))"; OwnerRawNames = $OwnerNamesRaw }
        }
    }

    # Fallback: no usable Owner Accounts value - try resolving the display name instead.
    $nameTokens = $OwnerNamesRaw -split [regex]::Escape($Delimiter) |
                  ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    if ($nameTokens.Count -eq 0) {
        return @{ Success = $false; ADUser = $null; Reason = 'Owner missing on source row'; OwnerRawNames = $OwnerNamesRaw }
    }
    if ($nameTokens.Count -gt 1) {
        return @{ Success = $false; ADUser = $null; Reason = "Multiple owners found ($($nameTokens -join ', '))"; OwnerRawNames = $OwnerNamesRaw }
    }

    $displayName = $nameTokens[0]
    try {
        $matches = @(Get-ADUser -Filter "DisplayName -eq '$displayName'" -Properties DistinguishedName @ADConnectionParams -ErrorAction Stop)
    }
    catch {
        return @{ Success = $false; ADUser = $null; Reason = "AD lookup by display name failed: $($_.Exception.Message)"; OwnerRawNames = $OwnerNamesRaw }
    }

    if ($matches.Count -eq 0) {
        return @{ Success = $false; ADUser = $null; Reason = "Owner '$displayName' could not be matched to any AD user"; OwnerRawNames = $OwnerNamesRaw }
    }
    if ($matches.Count -gt 1) {
        return @{ Success = $false; ADUser = $null; Reason = "Owner '$displayName' matched multiple AD users - manual resolution required"; OwnerRawNames = $OwnerNamesRaw }
    }

    return @{ Success = $true; ADUser = $matches[0]; Reason = $null; OwnerRawNames = $OwnerNamesRaw }
}

#region ---------------------------------------------------------------------
# MAIN PROCESSING LOOP
#endregion --------------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[Object]
$rowNum = 1

foreach ($row in $rawRows) {
    $rowNum++

    $svcAccountRaw = if (-not [string]::IsNullOrWhiteSpace($row.$Col_ServiceAccount)) {
        $row.$Col_ServiceAccount
    } else {
        $row.$Col_AccountFallback
    }
    $samAccountName = Get-CleanSamAccountName -RawValue $svcAccountRaw

    $entry = [ordered]@{
        RowNumber              = $rowNum
        ServiceAccount          = $samAccountName
        CyberArkSafe            = $row.$Col_Safe
        SafeAccessGroupOwner    = $row.$Col_OwnerName
        ExistingAD_Manager      = $null
        ExistingAD_ManagedBy    = $null
        ExistingAD_Notes        = $null
        New_Manager             = $null
        New_Notes               = $null
        UpdateStatus             = 'Not Processed'
        ErrorReason              = $null
    }

    if ([string]::IsNullOrWhiteSpace($samAccountName)) {
        $entry.UpdateStatus = 'Skipped'
        $entry.ErrorReason  = 'No service account identifier on this row'
        $results.Add([PSCustomObject]$entry)
        continue
    }

    # --- Verify the service account exists in AD, and pull its current values ---
    try {
        $adAccount = Get-ADUser -Identity $samAccountName -Properties Manager, ManagedBy, $NotesAttribute @ADConnectionParams -ErrorAction Stop
    }
    catch {
        $entry.UpdateStatus = 'Error'
        $entry.ErrorReason  = "Service account '$samAccountName' not found in AD"
        Write-Log $entry.ErrorReason 'WARN'
        $results.Add([PSCustomObject]$entry)
        continue
    }

    $entry.ExistingAD_Manager   = $adAccount.Manager
    $entry.ExistingAD_ManagedBy = $adAccount.ManagedBy
    $entry.ExistingAD_Notes     = $adAccount.$NotesAttribute

    $managerMissingInAD = [string]::IsNullOrWhiteSpace($adAccount.Manager)
    $notesMissingInAD   = [string]::IsNullOrWhiteSpace($adAccount.$NotesAttribute)

    if (-not $managerMissingInAD -and -not $notesMissingInAD) {
        $entry.UpdateStatus = 'Skipped'
        $entry.ErrorReason  = 'Manager and Notes already populated in AD - no action needed'
        $results.Add([PSCustomObject]$entry)
        continue
    }

    # --- Safe / owner lookup (only needed if something is actually missing) ---
    if ([string]::IsNullOrWhiteSpace($row.$Col_Safe)) {
        $entry.UpdateStatus = 'Error'
        $entry.ErrorReason  = 'CyberArk Safe is missing on source row'
        Write-Log "$samAccountName - $($entry.ErrorReason)" 'WARN'
        $results.Add([PSCustomObject]$entry)
        continue
    }

    $ownerResult = Resolve-SafeOwner -OwnerNamesRaw $row.$Col_OwnerName `
                                      -OwnerAccountsRaw $row.$Col_OwnerAccount `
                                      -Delimiter $OwnerDelimiter `
                                      -ADConnectionParams $ADConnectionParams

    if (-not $ownerResult.Success) {
        $entry.UpdateStatus = 'Error'
        $entry.ErrorReason  = $ownerResult.Reason
        Write-Log "$samAccountName - $($entry.ErrorReason)" 'WARN'
        $results.Add([PSCustomObject]$entry)
        continue
    }

    $ownerUser = $ownerResult.ADUser

    # --- Build the proposed new values (only for whichever attribute is actually missing) ---
    if ($managerMissingInAD) {
        $entry.New_Manager = $ownerUser.DistinguishedName
    }
    if ($notesMissingInAD) {
        $entry.New_Notes = "Managed via CyberArk Safe '$($row.$Col_Safe)' - responsible owner: $($row.$Col_OwnerName) (auto-populated $(Get-Date -Format 'yyyy-MM-dd'))"
    }

    $entry.UpdateStatus = if ($Mode -eq 'Report') { 'Proposed (Report mode)' } else { 'Pending Update' }
    $results.Add([PSCustomObject]$entry)
}

#region ---------------------------------------------------------------------
# APPLY UPDATES (Update mode only)
#endregion --------------------------------------------------------------------
if ($Mode -eq 'Update') {
    Write-Log "Applying updates to AD..."
    foreach ($entry in $results) {
        if ($entry.UpdateStatus -ne 'Pending Update') { continue }

        $setParams = @{ Identity = $entry.ServiceAccount }
        foreach ($key in $ADConnectionParams.Keys) { $setParams[$key] = $ADConnectionParams[$key] }
        if ($entry.New_Manager) { $setParams['Manager'] = $entry.New_Manager }
        if ($entry.New_Notes)   { $setParams['Replace']  = @{ $NotesAttribute = $entry.New_Notes } }

        $target = "AD account '$($entry.ServiceAccount)'"
        $action = @()
        if ($entry.New_Manager) { $action += "Manager -> $($entry.SafeAccessGroupOwner)" }
        if ($entry.New_Notes)   { $action += "Notes/$NotesAttribute -> '$($entry.New_Notes)'" }

        if ($PSCmdlet.ShouldProcess($target, ($action -join '; '))) {
            try {
                Set-ADUser @setParams -ErrorAction Stop
                $entry.UpdateStatus = 'Updated'
                Write-Log "$($entry.ServiceAccount) - Updated ($($action -join '; '))"
            }
            catch {
                $entry.UpdateStatus = 'Error'
                $entry.ErrorReason  = "Set-ADUser failed: $($_.Exception.Message)"
                Write-Log "$($entry.ServiceAccount) - $($entry.ErrorReason)" 'ERROR'
            }
        }
        else {
            $entry.UpdateStatus = 'Skipped (WhatIf/Declined)'
        }
    }
}

#region ---------------------------------------------------------------------
# REPORT
#endregion --------------------------------------------------------------------
$results | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
Write-Log "Report written to: $reportPath"
Write-Log "Log written to:    $logPath"

$summary = $results | Group-Object UpdateStatus | Select-Object Name, Count
Write-Log "----- Summary -----"
$summary | ForEach-Object { Write-Log ("{0,-28} {1}" -f $_.Name, $_.Count) }

if ($Mode -eq 'Report') {
    Write-Log "Report-only run complete. No AD changes were made. Review '$reportPath', then re-run with -Mode Update once satisfied."
}