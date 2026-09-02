<#
.SYNOPSIS
    Identifies service accounts in Active Directory that are missing Manager and/or
    Notes (info) attributes, resolves the correct value from a CSV source file, and
    updates AD.

.DESCRIPTION
    Source of truth: a CSV export containing one row per service account, with a
    'Manager' column (the samAccountName or domain\samAccountName of the manager
    to set) and a 'Notes' column (the free-text note to write).

    For every row where the AD account is actually missing Manager and/or Notes
    (the CSV columns are only used to build the initial candidate list — the
    live AD attribute value is always re-checked before any write, so existing
    valid AD values are never overwritten):

        1. Verify the service account exists in AD.
        2. If Manager is missing in AD, take the CSV row's 'Manager' value and
           resolve it to an AD user; use that user's DistinguishedName as the
           new Manager.
        3. If Notes/info is missing in AD, take the CSV row's 'Notes' value
           verbatim as the new note.
        4. Log every account processed (updated, skipped, or errored) with full
           before/after values to a CSV report.

    The script never writes to AD unless -Mode Update is passed. Even in Update
    mode, it is a native PowerShell ShouldProcess cmdlet, so -WhatIf and -Confirm
    both work normally on top of the built-in Report mode.

.PARAMETER CsvPath
    Path to the source .csv file.

.PARAMETER Mode
    'Report'  (default) - analyze only, write the CSV report, change nothing in AD.
    'Update'  - after the same analysis, actually apply the changes to AD.

.PARAMETER NotesAttribute
    Which AD attribute the CSV's "Notes" concept should be written to.
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
    .\Update-ServiceAccountManagerNotes.ps1 -CsvPath 'C:\Data\AD-ServiceAccountFile.csv' -Mode Report

.EXAMPLE
    # Report mode, explicitly targeting a specific domain controller:
    .\Update-ServiceAccountManagerNotes.ps1 -CsvPath 'C:\Data\AD-ServiceAccountFile.csv' -Mode Report -Server 'dc01.corp.contoso.com'

.EXAMPLE
    # Review the CSV report from the run above, then apply the changes for real,
    # with an extra interactive confirmation prompt per account, using a
    # specific privileged account rather than your own logon:
    .\Update-ServiceAccountManagerNotes.ps1 -CsvPath 'C:\Data\AD-ServiceAccountFile.csv' -Mode Update -Confirm -Server 'dc01.corp.contoso.com' -Credential (Get-Credential)

.EXAMPLE
    # Apply changes but simulate them first via PowerShell's native -WhatIf
    # (prints what Set-ADUser WOULD do, without touching AD, even in Update mode):
    .\Update-ServiceAccountManagerNotes.ps1 -CsvPath 'C:\Data\AD-ServiceAccountFile.csv' -Mode Update -WhatIf

.NOTES
    Required modules  : ActiveDirectory (RSAT)
    Required rights    : Read access to AD; Write access to the Manager/Notes(info)
                          attributes of the target service account OUs.
    Tested pattern      : PowerShell 5.1 / 7.x
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [ValidateSet('Report', 'Update')]
    [string]$Mode = 'Report',

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
# COLUMN MAPPING - adjust here if your CSV headers differ, without touching
# any logic further down. These names must match the source file's headers
# exactly (case-insensitive).
#endregion --------------------------------------------------------------------
$Col_ServiceAccount   = 'Samaccountname'                       # preferred unique key
$Col_AccountFallback  = 'Account'                              # domain\sam, used if Samaccountname blank
$Col_Manager          = 'Manager'                               # source value for the new Manager
$Col_ManagedBy        = 'ManagedBy'                             # reported only, never written
$Col_Notes            = 'Notes'                                 # source value for the new Notes/info

$RequiredColumns = @(
    $Col_ServiceAccount, $Col_AccountFallback, $Col_Manager, $Col_ManagedBy, $Col_Notes
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
Write-Log "Source file: $CsvPath"

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Log "Required module 'ActiveDirectory' is not installed. Install RSAT and re-run." 'ERROR'
    throw "Missing required module: ActiveDirectory"
}
Import-Module ActiveDirectory -ErrorAction Stop

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
    Write-Log "Could not contact Active Directory with the given -Server/-Credential. Aborting before reading the CSV or touching any account." 'ERROR'
    Write-Log "Underlying error: $($_.Exception.Message)" 'ERROR'
    throw
}

#region ---------------------------------------------------------------------
# READ + VALIDATE CSV
#endregion --------------------------------------------------------------------
Write-Log "Reading CSV '$CsvPath'..."
try {
    $rawRows = Import-Csv -Path $CsvPath -ErrorAction Stop
}
catch {
    Write-Log "Failed to read CSV file: $($_.Exception.Message)" 'ERROR'
    throw
}

$csvHeaders  = if ($rawRows.Count -gt 0) { $rawRows[0].PSObject.Properties.Name } else { @() }
$missingCols = $RequiredColumns | Where-Object { $_ -notin $csvHeaders }
if ($missingCols) {
    Write-Log "CSV file is missing required column(s): $($missingCols -join ', ')" 'ERROR'
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

function Resolve-ManagerFromCsv {
    <#
        Resolves the CSV row's raw Manager value (samAccountName or
        domain\samAccountName) to an AD user. Returns a hashtable:
          @{ Success = $true/$false; ADUser = <ADUser or $null>; Reason = <string, only when Success = $false> }
    #>
    param(
        [string]$ManagerRaw,
        [hashtable]$ADConnectionParams = @{}
    )

    if ([string]::IsNullOrWhiteSpace($ManagerRaw)) {
        return @{ Success = $false; ADUser = $null; Reason = 'Manager missing in AD and no Manager value provided in CSV source row' }
    }

    $sam = Get-CleanSamAccountName -RawValue $ManagerRaw
    try {
        $u = Get-ADUser -Identity $sam -Properties DistinguishedName @ADConnectionParams -ErrorAction Stop
        return @{ Success = $true; ADUser = $u; Reason = $null }
    }
    catch {
        return @{ Success = $false; ADUser = $null; Reason = "Manager '$sam' from CSV could not be resolved in AD ($($_.Exception.Message))" }
    }
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
        SourceManager            = $row.$Col_Manager
        SourceNotes              = $row.$Col_Notes
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

    # --- Build the proposed new values (only for whichever attribute is actually missing) ---
    $rowErrors = @()

    if ($managerMissingInAD) {
        $managerResult = Resolve-ManagerFromCsv -ManagerRaw $row.$Col_Manager -ADConnectionParams $ADConnectionParams
        if ($managerResult.Success) {
            $entry.New_Manager = $managerResult.ADUser.DistinguishedName
        }
        else {
            $rowErrors += $managerResult.Reason
        }
    }

    if ($notesMissingInAD) {
        if ([string]::IsNullOrWhiteSpace($row.$Col_Notes)) {
            $rowErrors += 'Notes missing in AD and no Notes value provided in CSV source row'
        }
        else {
            $entry.New_Notes = $row.$Col_Notes
        }
    }

    if ($rowErrors.Count -gt 0) {
        $entry.UpdateStatus = 'Error'
        $entry.ErrorReason  = $rowErrors -join '; '
        Write-Log "$samAccountName - $($entry.ErrorReason)" 'WARN'
        $results.Add([PSCustomObject]$entry)
        continue
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
        if ($entry.New_Manager) { $action += "Manager -> $($entry.SourceManager)" }
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
