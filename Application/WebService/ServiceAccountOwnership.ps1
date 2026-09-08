# ============================================================
# AD SERVICE ACCOUNT OWNERSHIP RECONCILIATION
# NOTES = SOURCE OF TRUTH | NO EMAIL NOTIFICATIONS - FLAGGING ONLY
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

$InputFile = "C:\Reports\AD-ServiceAccountFile.xlsx"

$OutputFile = "C:\Reports\AD-ServiceAccountFile_Result.xlsx"

$NonCompliantFile = "C:\Reports\NonCyberCompliant_Accounts.xlsx"

$LogFile = "C:\Reports\AD-ServiceAccountFile_Log.txt"


# ============================================================
# IMPORT EXCEL MODULE
# ============================================================

try {
    Import-Module ImportExcel -ErrorAction Stop
}
catch {
    Write-Host "ERROR: ImportExcel module is not installed." -ForegroundColor Red
    Write-Host "Run: Install-Module ImportExcel -Scope CurrentUser"
    exit
}


# ============================================================
# FUNCTIONS
# ============================================================

function Write-Log {

    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $LogMessage = "$TimeStamp [$Level] $Message"

    Write-Host $LogMessage

    Add-Content -Path $LogFile -Value $LogMessage
}


function Test-IsEmpty {

    param(
        $Value
    )

    return [string]::IsNullOrWhiteSpace([string]$Value)
}


function Compare-NormalizedValue {

    param(
        $ValueA,
        $ValueB
    )

    return $ValueA.ToString().Trim().ToLower() -eq $ValueB.ToString().Trim().ToLower()
}


function Get-AuthoritativeNote {

    # Source of truth for documented ownership. 'Notes Data Current' is the
    # most recently confirmed value, so it wins whenever populated; 'Notes'
    # is only a fallback for rows that haven't been re-confirmed yet.

    param(
        $Notes,
        $NotesDataCurrent
    )

    if (!(Test-IsEmpty $NotesDataCurrent)) {
        return $NotesDataCurrent.ToString().Trim()
    }

    if (!(Test-IsEmpty $Notes)) {
        return $Notes.ToString().Trim()
    }

    return $null
}


function Resolve-OwnershipStatus {

    # Reconciliation is driven by the authoritative Notes value against BOTH
    # ManagedBy and Manager independently - Notes is the source of truth,
    # and either AD field drifting away from it is a discrepancy worth
    # flagging, not just ManagedBy.

    param(
        $Account,
        $Manager,
        $ManagedBy,
        $AuthoritativeNote
    )

    $Result = [PSCustomObject]@{
        Status          = ""
        Flag            = ""
        ActionRequired  = ""
        NoteVsManagedBy = "Not Applicable"
        NoteVsManager   = "Not Applicable"
    }

    if (!(Test-IsEmpty $AuthoritativeNote)) {

        if (!(Test-IsEmpty $ManagedBy)) {
            $Result.NoteVsManagedBy = if (Compare-NormalizedValue $AuthoritativeNote $ManagedBy) { "Matched" } else { "Mismatched" }
        }

        if (!(Test-IsEmpty $Manager)) {
            $Result.NoteVsManager = if (Compare-NormalizedValue $AuthoritativeNote $Manager) { "Matched" } else { "Mismatched" }
        }
    }


    # --------------------------------------------------------
    # SCENARIO 1: no documented owner in Notes at all
    # --------------------------------------------------------

    if (Test-IsEmpty $AuthoritativeNote) {

        if ((Test-IsEmpty $ManagedBy) -and (Test-IsEmpty $Manager)) {

            $Result.Status = "Non-Cyber-Compliant"
            $Result.Flag = "No Traceable Ownership - No Notes, ManagedBy, or Manager"
            $Result.ActionRequired = "Immediate ownership remediation required"

            Write-Log "NON-CYBER-COMPLIANT: $Account | No Notes, ManagedBy, or Manager on file" "WARNING"
        }
        else {

            $Result.Status = "FLAGGED"
            $Result.Flag = "Notes Missing - Cannot Validate Ownership"
            $Result.ActionRequired = "Document the confirmed owner in Notes / Notes Data Current"

            Write-Log "FLAGGED: $Account | Notes not documented, ownership cannot be validated" "WARNING"
        }

        return $Result
    }


    # --------------------------------------------------------
    # SCENARIO 2: Notes documents an owner, but neither AD field is set
    # --------------------------------------------------------

    if ((Test-IsEmpty $ManagedBy) -and (Test-IsEmpty $Manager)) {

        $Result.Status = "FLAGGED"
        $Result.Flag = "ManagedBy and Manager Missing - Notes Documents Owner"
        $Result.ActionRequired = "Update ManagedBy/Manager in AD to match the documented owner in Notes"

        Write-Log "FLAGGED: $Account | Notes documents an owner but both ManagedBy and Manager are empty" "WARNING"

        return $Result
    }


    # --------------------------------------------------------
    # SCENARIO 3: Notes present - validate whichever of ManagedBy/Manager exist
    # --------------------------------------------------------

    $Mismatches = @()
    if ($Result.NoteVsManagedBy -eq "Mismatched") { $Mismatches += "ManagedBy" }
    if ($Result.NoteVsManager -eq "Mismatched") { $Mismatches += "Manager" }

    $MissingFields = @()
    if (Test-IsEmpty $ManagedBy) { $MissingFields += "ManagedBy" }
    if (Test-IsEmpty $Manager) { $MissingFields += "Manager" }

    if ($Mismatches.Count -gt 0) {

        $Result.Status = "Mismatched"
        $Result.Flag = "Ownership Discrepancy - $($Mismatches -join ' and ') Differs from Notes"
        $Result.ActionRequired = "Manual review required: $($Mismatches -join '/') does not match the documented owner in Notes"

        Write-Log "MISMATCHED: $Account | $($Mismatches -join ', ') does not match documented owner in Notes" "WARNING"
    }
    elseif ($MissingFields.Count -gt 0) {

        $Result.Status = "Matched"
        $Result.Flag = "$($MissingFields -join ' and ') Missing - Remaining Field Matches Notes"
        $Result.ActionRequired = "Populate missing $($MissingFields -join '/') to fully confirm ownership"

        Write-Log "MATCHED (partial): $Account | $($MissingFields -join ', ') missing but remaining field matches Notes" "WARNING"
    }
    else {

        $Result.Status = "Matched"
        $Result.Flag = "No Flag"
        $Result.ActionRequired = "Ownership validated against Notes"

        Write-Log "MATCHED: $Account | ManagedBy and Manager both match documented owner in Notes"
    }

    return $Result
}


function Export-ReconciliationReports {

    param(
        $FinalResults,
        $OutputFile,
        $NonCompliantFile
    )

    try {

        $FinalResults | Export-Excel `
            -Path $OutputFile `
            -WorksheetName "Ownership Reconciliation" `
            -AutoSize `
            -BoldTopRow `
            -FreezeTopRow `
            -TableName "ServiceAccountOwnership" `
            -ClearSheet

        Write-Log "Main output file created successfully: $OutputFile"
    }
    catch {

        Write-Log "Failed to create output Excel file: $($_.Exception.Message)" "ERROR"
    }


    $NonCompliantAccounts = $FinalResults | Where-Object { $_.Status -eq "Non-Cyber-Compliant" }

    if ($NonCompliantAccounts.Count -gt 0) {

        $NonCompliantAccounts | Export-Excel `
            -Path $NonCompliantFile `
            -WorksheetName "Non-Compliant Accounts" `
            -AutoSize `
            -BoldTopRow `
            -FreezeTopRow `
            -TableName "NonCyberCompliantAccounts"

        Write-Log "Non-Compliant report created: $NonCompliantFile"
    }
}


# ============================================================
# VALIDATE INPUT FILE
# ============================================================

if (!(Test-Path $InputFile)) {

    Write-Host "ERROR: Input file not found:" -ForegroundColor Red
    Write-Host $InputFile

    exit
}


Write-Log "Starting Service Account Ownership Reconciliation"


# ============================================================
# IMPORT EXCEL FILE
# ============================================================

try {

    $Records = Import-Excel -Path $InputFile

    Write-Log "Total rows read: $($Records.Count)"
}
catch {

    Write-Log "Failed to read Excel file: $($_.Exception.Message)" "ERROR"

    exit
}


# ============================================================
# PROCESS EACH RECORD
# ============================================================

$FinalResults = @()

$TotalProcessed = 0
$MatchedCount = 0
$MismatchedCount = 0
$BothFieldsMissingCount = 0
$NotesMissingCount = 0
$NonCompliantCount = 0
$SkippedCount = 0


foreach ($Record in $Records) {

    # --------------------------------------------------------
    # READ COLUMNS FROM EXCEL
    # --------------------------------------------------------

    $Account = $Record.Account
    $SamAccountName = $Record.Samaccountname
    $AccountMail = $Record.Mail
    $Manager = $Record.Manager
    $ManagedBy = $Record.ManagedBy
    $Notes = $Record.Notes
    $NotesDataCurrent = $Record.'Notes Data Current'
    $Description = $Record.Description
    $SafeOwnerNames = $Record.'Safe Access Group Owner Names'
    $SafeOwnerAccounts = $Record.'Safe Access Group Owner Accounts'
    $SafeOwnerEmails = $Record.'Safe Access Group Owner Emails'
    $CyberArkSafes = $Record.'CyberArk Safes'


    # --------------------------------------------------------
    # SKIP COMPLETELY EMPTY ROWS
    # --------------------------------------------------------

    if ((Test-IsEmpty $Account) -and (Test-IsEmpty $SamAccountName)) {

        $SkippedCount++
        continue
    }

    $TotalProcessed++

    Write-Log "Processing Account: $Account | SamAccountName: $SamAccountName"


    # --------------------------------------------------------
    # RESOLVE STATUS AGAINST NOTES (SOURCE OF TRUTH)
    # --------------------------------------------------------

    $AuthoritativeNote = Get-AuthoritativeNote -Notes $Notes -NotesDataCurrent $NotesDataCurrent

    $Reconciliation = Resolve-OwnershipStatus `
        -Account $Account `
        -Manager $Manager `
        -ManagedBy $ManagedBy `
        -AuthoritativeNote $AuthoritativeNote

    switch ($Reconciliation.Status) {
        "Matched"              { $MatchedCount++ }
        "Mismatched"           { $MismatchedCount++ }
        "Non-Cyber-Compliant"  { $NonCompliantCount++ }
        "FLAGGED" {
            if ($Reconciliation.Flag -eq "Notes Missing - Cannot Validate Ownership") { $NotesMissingCount++ }
            else { $BothFieldsMissingCount++ }
        }
    }


    # --------------------------------------------------------
    # CREATE OUTPUT RECORD
    # --------------------------------------------------------

    $FinalResults += [PSCustomObject]@{

        Account                       = $Account
        SamAccountName                = $SamAccountName
        AccountMail                   = $AccountMail
        Manager                       = $Manager
        ManagedBy                     = $ManagedBy
        Notes                         = $Notes
        NotesDataCurrent              = $NotesDataCurrent
        AuthoritativeNote             = $AuthoritativeNote
        Status                        = $Reconciliation.Status
        Flag                          = $Reconciliation.Flag
        ActionRequired                = $Reconciliation.ActionRequired
        NoteVsManagedBy               = $Reconciliation.NoteVsManagedBy
        NoteVsManager                 = $Reconciliation.NoteVsManager
        Description                   = $Description
        CyberArkSafes                 = $CyberArkSafes
        SafeAccessGroupOwnerNames     = $SafeOwnerNames
        SafeAccessGroupOwnerAccounts  = $SafeOwnerAccounts
        SafeAccessGroupOwnerEmails    = $SafeOwnerEmails
        ProcessedDate                 = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
}


# ============================================================
# EXPORT REPORTS
# ============================================================

Export-ReconciliationReports `
    -FinalResults $FinalResults `
    -OutputFile $OutputFile `
    -NonCompliantFile $NonCompliantFile


# ============================================================
# DISPLAY SUMMARY
# ============================================================

Write-Host ""
Write-Host "===================================================="
Write-Host "SERVICE ACCOUNT OWNERSHIP RECONCILIATION COMPLETED"
Write-Host "===================================================="
Write-Host ""

Write-Host "Total Processed: $TotalProcessed"
Write-Host "Matched (ManagedBy/Manager align with Notes): $MatchedCount"
Write-Host "Mismatched (ManagedBy and/or Manager differ from Notes): $MismatchedCount"
Write-Host "ManagedBy and Manager Both Missing (Notes Available): $BothFieldsMissingCount"
Write-Host "Notes Missing (Cannot Validate): $NotesMissingCount"
Write-Host "Non-Cyber-Compliant: $NonCompliantCount"
Write-Host "Skipped Empty Rows: $SkippedCount"

Write-Host ""
Write-Host "Main Output File:"
Write-Host $OutputFile

Write-Host ""
Write-Host "Non-Compliant Report:"
Write-Host $NonCompliantFile

Write-Host ""
Write-Host "Log File:"
Write-Host $LogFile

Write-Host ""
Write-Host "PROCESS COMPLETED SUCCESSFULLY"
