<#
.SYNOPSIS
    AD Service Account Ownership Reconciliation & Compliance Flagging.

    Ingests the weekly AD Service Accounts report (CSV), determines each
    account's ownership from its ManagedBy attribute, cross-validates that
    against the Manager attribute, and flags accounts that fail to meet the
    minimum ownership documentation requirement.

.DESCRIPTION
    Source of truth: the weekly AD Service Accounts CSV export, with one row
    per service account. This script is read-only — it never writes to AD or
    to the source CSV; it only produces a compliance report.

    For every row:

        1. Ownership resolution — ManagedBy is treated as the authoritative
           source of ownership. Its raw value (typically a Distinguished
           Name, e.g. 'CN=Doe\, John,OU=ServiceAccounts,DC=corp,DC=com') is
           resolved to a readable identity (a display name / username) for
           reporting as 'ResolvedOwner'.

        2. Cross-field validation — the resolved ManagedBy identity is
           compared against the Manager value (resolved the same way) to
           determine whether both fields point at the same person:
             - 'Matched'              — both resolve to the same identity.
             - 'Mismatched'           — they resolve to different identities,
                                        or only one of the two is populated.
             - 'Non-Cyber-Compliant'  — both ManagedBy and Manager are
                                        null/empty (no traceable ownership at
                                        all). This status always takes
                                        precedence over Matched/Mismatched.

        3. Notes correlation — the Notes field is scanned (best-effort, via
           a configurable regex) for a supplementary/conflicting ownership
           reference (e.g. "Owner: jdoe", "Managed By: John Doe",
           "Contact: jdoe@corp.com"). Any match is reported as supporting
           context in 'NotesOwnerReference' / 'NotesConflictFlag' — it is
           NEVER used to change the ManagedBy/Manager-derived MatchStatus.

        4. Non-compliance flag — see step 2. This is the only condition that
           produces 'Non-Cyber-Compliant'; every other row is Matched or
           Mismatched.

    Resolving a Distinguished Name to a readable identity:
    By default this is done with pure text parsing of the DN/CSV value
    (extracting the CN component, or the samAccountName portion of a
    'domain\samAccountName' value) — no Active Directory connectivity is
    required to run this script, which keeps it deployable as an
    unattended/scheduled job with no AD read/write rights whatsoever.

    Pass -ResolveWithActiveDirectory to instead resolve ManagedBy/Manager
    via live Get-ADUser lookups (authoritative SamAccountName-based
    comparison instead of best-effort string comparison). If AD is
    unreachable, or the ActiveDirectory module isn't installed, the script
    automatically falls back to text parsing for that run rather than
    failing outright — a report is still produced either way.

.PARAMETER CsvPath
    Path to the weekly AD Service Accounts CSV export.

.PARAMETER OutputFolder
    Folder to write the CSV report and text log to. Defaults to the script's
    own folder.

.PARAMETER ResolveWithActiveDirectory
    Optional. When set, ManagedBy/Manager values are resolved via live
    Get-ADUser lookups (falling back to text parsing per-value if a lookup
    fails) instead of pure text parsing for every value. Requires the
    ActiveDirectory (RSAT) module; if it isn't installed the switch is
    ignored (with a warning) and the script proceeds text-only.

.PARAMETER Server
    Optional, only used when -ResolveWithActiveDirectory is set. A specific
    domain controller or domain FQDN to target for every AD read in this run.

.PARAMETER Credential
    Optional, only used when -ResolveWithActiveDirectory is set. A
    PSCredential to run every AD read as, instead of the account currently
    running the script.

.PARAMETER NotesOwnerPattern
    Regex used to extract a candidate ownership reference from the Notes
    field. Must contain exactly one capture group holding the reference
    text. Defaults to matching "Owner:", "Managed By:", "Contact:", "POC:"
    or "Responsible:" followed by a value; falls back internally to a bare
    email address or 'domain\samAccountName' token if the keyword pattern
    doesn't match.

.PARAMETER FailOnNonCompliant
    Optional. When set, the script exits with code 1 if any account is
    flagged 'Non-Cyber-Compliant' — useful for surfacing failures to a
    scheduled-task runner, CI job, or monitoring system. Without this
    switch the script always exits 0 once the report is written; compliance
    failures are still fully recorded in the CSV report either way.

.EXAMPLE
    # Weekly run, text-parsing only, no AD connectivity required.
    .\Get-ServiceAccountOwnershipCompliance.ps1 -CsvPath 'C:\Data\AD-ServiceAccounts-Weekly.csv'

.EXAMPLE
    # Authoritative AD-backed resolution against a specific DC.
    .\Get-ServiceAccountOwnershipCompliance.ps1 -CsvPath 'C:\Data\AD-ServiceAccounts-Weekly.csv' -ResolveWithActiveDirectory -Server 'dc01.corp.contoso.com'

.EXAMPLE
    # Scheduled task that should fail (non-zero exit) when any account is non-compliant.
    .\Get-ServiceAccountOwnershipCompliance.ps1 -CsvPath 'C:\Data\AD-ServiceAccounts-Weekly.csv' -FailOnNonCompliant

.NOTES
    Required modules  : none (ActiveDirectory / RSAT only if -ResolveWithActiveDirectory is used)
    Required rights    : read access to AD only if -ResolveWithActiveDirectory is used; none otherwise.
    Tested pattern      : PowerShell 5.1 / 7.x
    Deployment          : safe to run unattended (scheduled task / CI) — read-only, no AD or file writes
                          other than the report/log this script itself creates in -OutputFolder.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [string]$OutputFolder = $PSScriptRoot,

    [switch]$ResolveWithActiveDirectory,

    [string]$Server,

    [System.Management.Automation.PSCredential]$Credential,

    [string]$NotesOwnerPattern = '(?i)(?:owner|managed\s*by|contact|poc|responsible)\s*[:\-]\s*([^;\r\n]+)',

    [switch]$FailOnNonCompliant
)

#region ---------------------------------------------------------------------
# COLUMN MAPPING - adjust here if your CSV headers differ, without touching
# any logic further down. These names must match the source file's headers
# exactly (case-insensitive).
#endregion --------------------------------------------------------------------
$Col_ServiceAccount   = 'Samaccountname'          # preferred unique key
$Col_AccountFallback  = 'Account'                  # domain\sam, used if Samaccountname blank
$Col_ManagedBy        = 'ManagedBy'                # authoritative ownership source
$Col_Manager          = 'Manager'                  # cross-validated against ManagedBy
$Col_Notes            = 'Notes'                    # scanned for a supplementary owner reference

$RequiredColumns = @(
    $Col_ServiceAccount, $Col_AccountFallback, $Col_ManagedBy, $Col_Manager, $Col_Notes
)

#region ---------------------------------------------------------------------
# SETUP: output paths, logging
#endregion --------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$reportPath = Join-Path $OutputFolder "ServiceAccount_OwnershipCompliance_Report_$timestamp.csv"
$logPath    = Join-Path $OutputFolder "ServiceAccount_OwnershipCompliance_Log_$timestamp.txt"

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

Write-Log "=== Service Account Ownership Reconciliation & Compliance Flagging ==="
Write-Log "Source file: $CsvPath"

if (-not $ResolveWithActiveDirectory -and ($Server -or $Credential)) {
    Write-Log "-Server/-Credential were supplied but -ResolveWithActiveDirectory was not set - they will be ignored." 'WARN'
}

#region ---------------------------------------------------------------------
# OPTIONAL AD CONNECTIVITY (only when -ResolveWithActiveDirectory is set).
# Never fatal: if the module is missing or AD is unreachable, the script
# logs a warning and continues with text-only parsing so the report still
# gets produced on an unattended run.
#endregion --------------------------------------------------------------------
$ADConnectionParams = @{}
if ($ResolveWithActiveDirectory) {
    if ($Server)     { $ADConnectionParams['Server']     = $Server }
    if ($Credential) { $ADConnectionParams['Credential'] = $Credential }

    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Log "-ResolveWithActiveDirectory was requested but the ActiveDirectory module is not installed. Continuing with text-based identity parsing only." 'WARN'
        $ResolveWithActiveDirectory = $false
    }
    else {
        Import-Module ActiveDirectory -ErrorAction Stop
        try {
            $domainInfo = Get-ADDomain @ADConnectionParams -ErrorAction Stop
            $whoAmI     = if ($Credential) { $Credential.UserName } else { "$env:USERDOMAIN\$env:USERNAME (current session)" }
            $dcUsed     = if ($Server) { $Server } else { "$($domainInfo.PDCEmulator) (auto-discovered)" }

            Write-Log "AD connectivity OK - resolving ManagedBy/Manager via live AD lookups."
            Write-Log "  Domain      : $($domainInfo.DNSRoot)"
            Write-Log "  DC in use   : $dcUsed"
            Write-Log "  Running as  : $whoAmI"
        }
        catch {
            Write-Log "Could not contact Active Directory with the given -Server/-Credential. Continuing with text-based identity parsing only." 'WARN'
            Write-Log "Underlying error: $($_.Exception.Message)" 'WARN'
            $ResolveWithActiveDirectory = $false
        }
    }
}
else {
    Write-Log "Running in text-parsing mode (no AD connectivity) - pass -ResolveWithActiveDirectory for live AD-backed resolution."
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
    throw "Required columns not found. Aborting."
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

function Get-DnCommonName {
    <# Extracts the CN=... component of a Distinguished Name, unescaping
       '\,' and '\\' so "CN=Doe\, John,OU=..." becomes "Doe, John". #>
    param([string]$DistinguishedName)
    if ($DistinguishedName -match '(?i)^CN=((?:[^,\\]|\\.)*)') {
        return ($Matches[1] -replace '\\,', ',' -replace '\\\\', '\').Trim()
    }
    return $null
}

function Resolve-OwnershipIdentity {
    <#
        Resolves a raw ManagedBy/Manager cell value to a readable identity.
        Returns a PSCustomObject:
          Raw, DisplayName, CanonicalKey (used for equality comparison),
          ResolvedViaAD (bool), IsBlank (bool).

        With -UseActiveDirectory, tries Get-ADUser first (CanonicalKey =
        SamAccountName); on failure, or when the switch isn't set, falls
        back to text parsing: DN -> CN, 'domain\sam' -> sam, else the raw
        trimmed text.
    #>
    param(
        [string]$RawValue,
        [switch]$UseActiveDirectory,
        [hashtable]$ADConnectionParams = @{}
    )

    $result = [ordered]@{
        Raw           = $RawValue
        DisplayName   = $null
        CanonicalKey  = $null
        ResolvedViaAD = $false
        IsBlank       = $false
    }

    if ([string]::IsNullOrWhiteSpace($RawValue)) {
        $result.IsBlank = $true
        return [PSCustomObject]$result
    }

    $trimmed = $RawValue.Trim()

    if ($UseActiveDirectory) {
        try {
            $identity = if ($trimmed -match '(?i)^CN=') { $trimmed } else { Get-CleanSamAccountName -RawValue $trimmed }
            $u = Get-ADUser -Identity $identity -Properties DisplayName @ADConnectionParams -ErrorAction Stop
            $result.DisplayName   = $u.DisplayName
            $result.CanonicalKey  = $u.SamAccountName.ToLowerInvariant()
            $result.ResolvedViaAD = $true
            return [PSCustomObject]$result
        }
        catch {
            Write-Log "AD resolution failed for '$trimmed' - falling back to text parsing ($($_.Exception.Message))" 'WARN'
        }
    }

    if ($trimmed -match '(?i)^CN=') {
        $cn = Get-DnCommonName -DistinguishedName $trimmed
        $result.DisplayName  = if ($cn) { $cn } else { $trimmed }
    }
    elseif ($trimmed -match '\\') {
        $result.DisplayName = Get-CleanSamAccountName -RawValue $trimmed
    }
    else {
        $result.DisplayName = $trimmed
    }
    $result.CanonicalKey = ($result.DisplayName.ToLowerInvariant() -replace '\s+', ' ').Trim()

    return [PSCustomObject]$result
}

function Get-NotesOwnerReference {
    <# Best-effort extraction of a supplementary ownership reference from a
       Notes cell: first tries the keyword pattern (Owner:/Managed By:/etc.),
       then falls back to a bare email address or 'domain\sam' token. Returns
       $null if nothing is found. #>
    param(
        [string]$NotesText,
        [string]$KeywordPattern
    )
    if ([string]::IsNullOrWhiteSpace($NotesText)) { return $null }

    if ($NotesText -match $KeywordPattern) { return $Matches[1].Trim() }

    if ($NotesText -match '(?i)([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|[A-Za-z0-9.\-]+\\[A-Za-z0-9._-]+)') {
        return $Matches[1].Trim()
    }

    return $null
}

#region ---------------------------------------------------------------------
# MAIN PROCESSING LOOP
#endregion --------------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[Object]
$rowNum = 1

foreach ($row in $rawRows) {
    $rowNum++

    $acctRaw = if (-not [string]::IsNullOrWhiteSpace($row.$Col_ServiceAccount)) {
        $row.$Col_ServiceAccount
    } else {
        $row.$Col_AccountFallback
    }
    $accountIdentifier = Get-CleanSamAccountName -RawValue $acctRaw
    if ([string]::IsNullOrWhiteSpace($accountIdentifier)) {
        Write-Log "Row $rowNum has no account identifier (Samaccountname/Account both blank)" 'WARN'
        $accountIdentifier = "(unknown - row $rowNum)"
    }

    # --- Step 1 & 4: resolve ManagedBy (authoritative) and Manager, both the same way ---
    $managedByResolved = Resolve-OwnershipIdentity -RawValue $row.$Col_ManagedBy -UseActiveDirectory:$ResolveWithActiveDirectory -ADConnectionParams $ADConnectionParams
    $managerResolved    = Resolve-OwnershipIdentity -RawValue $row.$Col_Manager    -UseActiveDirectory:$ResolveWithActiveDirectory -ADConnectionParams $ADConnectionParams

    # --- Step 2: cross-field validation (Non-Cyber-Compliant always takes precedence) ---
    if ($managedByResolved.IsBlank -and $managerResolved.IsBlank) {
        $matchStatus = 'Non-Cyber-Compliant'
        $matchReason = 'Both ManagedBy and Manager are empty - no traceable ownership'
        Write-Log "$accountIdentifier - Non-Cyber-Compliant: $matchReason" 'WARN'
    }
    elseif ($managedByResolved.IsBlank -or $managerResolved.IsBlank) {
        $matchStatus = 'Mismatched'
        $matchReason = if ($managedByResolved.IsBlank) { 'ManagedBy is empty while Manager is populated' } else { 'Manager is empty while ManagedBy is populated' }
    }
    elseif ($managedByResolved.CanonicalKey -eq $managerResolved.CanonicalKey) {
        $matchStatus = 'Matched'
        $matchReason = "ManagedBy and Manager both resolve to '$($managedByResolved.DisplayName)'"
    }
    else {
        $matchStatus = 'Mismatched'
        $matchReason = "ManagedBy resolves to '$($managedByResolved.DisplayName)' but Manager resolves to '$($managerResolved.DisplayName)'"
    }

    # --- Step 3: Notes correlation - supporting context only, never changes MatchStatus above ---
    $notesOwnerRef = Get-NotesOwnerReference -NotesText $row.$Col_Notes -KeywordPattern $NotesOwnerPattern
    $notesConflict =
        if (-not $notesOwnerRef) { 'N/A' }
        elseif ($managedByResolved.IsBlank) { 'N/A - ManagedBy empty' }
        else {
            $notesKey = (Get-CleanSamAccountName -RawValue $notesOwnerRef).ToLowerInvariant()
            if ($notesKey -eq $managedByResolved.CanonicalKey -or $notesOwnerRef.Trim().ToLowerInvariant() -eq $managedByResolved.CanonicalKey) { 'No' } else { 'Yes' }
        }

    $managedByResolvedViaAD = if ($managedByResolved.IsBlank) { 'N/A' } elseif ($managedByResolved.ResolvedViaAD) { 'Yes' } else { 'No' }
    $managerResolvedViaAD   = if ($managerResolved.IsBlank) { 'N/A' } elseif ($managerResolved.ResolvedViaAD) { 'Yes' } else { 'No' }

    $results.Add([PSCustomObject][ordered]@{
        RowNumber               = $rowNum
        AccountIdentifier        = $accountIdentifier
        ManagedByRaw              = $row.$Col_ManagedBy
        ResolvedOwner              = $managedByResolved.DisplayName
        ManagedByResolvedViaAD      = $managedByResolvedViaAD
        ManagerValue                 = $row.$Col_Manager
        ManagerResolvedIdentity       = $managerResolved.DisplayName
        ManagerResolvedViaAD           = $managerResolvedViaAD
        MatchStatus                     = $matchStatus
        MatchReason                      = $matchReason
        NotesContent                      = $row.$Col_Notes
        NotesOwnerReference                = $notesOwnerRef
        NotesConflictFlag                    = $notesConflict
    })
}

#region ---------------------------------------------------------------------
# REPORT
#endregion --------------------------------------------------------------------
$results | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
Write-Log "Report written to: $reportPath"
Write-Log "Log written to:    $logPath"

$summary = $results | Group-Object MatchStatus | Select-Object Name, Count
Write-Log "----- Summary -----"
$summary | ForEach-Object { Write-Log ("{0,-20} {1}" -f $_.Name, $_.Count) }

$nonCompliantCount = ($results | Where-Object { $_.MatchStatus -eq 'Non-Cyber-Compliant' }).Count
Write-Log "Non-Cyber-Compliant accounts: $nonCompliantCount"

if ($FailOnNonCompliant -and $nonCompliantCount -gt 0) {
    Write-Log "-FailOnNonCompliant is set and $nonCompliantCount account(s) are Non-Cyber-Compliant - exiting with code 1." 'ERROR'
    exit 1
}

exit 0
