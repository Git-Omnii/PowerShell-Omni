#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Creates an on-premises Active Directory account for a vendor or contractor,
    and optionally parses a pasted onboarding form to do it in one step.

.DESCRIPTION
    Two functions:
      New-SOWContractor         builds and creates the account from explicit values
      New-ContractorFromTicket  parses a pasted onboarding form, then calls the above

    Before first use, set three things near the top of New-SOWContractor:
    your UpnSuffix, your TargetOU, and your temporary password scheme. They ship
    with safe placeholder values so nothing real lives in this file.

    Includes a dry-run preview (-WhatIf) and a post-creation check (-Verify).

.NOTES
    Requires the ActiveDirectory module (RSAT) and rights to create users in the
    target OU. Always run with -WhatIf first after changing any defaults.
#>

# ---------------------------------------------------------------------------
# Helper: strong random temporary password (look-alike characters removed)
# ---------------------------------------------------------------------------
function New-TempPassword {
    param([int]$Length = 16)
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'.ToCharArray()
    $lower = 'abcdefghijkmnpqrstuvwxyz'.ToCharArray()
    $digit = '23456789'.ToCharArray()
    $sym   = '!@#$%^&*?'.ToCharArray()
    $all   = $upper + $lower + $digit + $sym
    $chars = @($upper | Get-Random), ($lower | Get-Random), ($digit | Get-Random), ($sym | Get-Random)
    for ($i = $chars.Count; $i -lt $Length; $i++) { $chars += $all | Get-Random }
    -join ($chars | Sort-Object { Get-Random })
}

# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------
function New-SOWContractor {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$FirstName,
        [Parameter(Mandatory)][string]$LastName,
        [Parameter(Mandatory)][string]$Company,

        [string]$CompanyCode,      # logon token only; defaults to Company stripped
        [string]$TicketNumber,     # available to a custom password scheme below
        [string]$EmailAddress,     # defaults to the UPN
        [string]$Manager,          # sAMAccountName of the manager

        # >>> EDIT THESE TWO DEFAULTS FOR YOUR ENVIRONMENT <<<
        [string]$UpnSuffix = 'example.com',
        [string]$TargetOU  = 'OU=Contractors,DC=example,DC=com',

        [string]$Title = 'Contractor',
        [int]$ExpirationMonths = 6,

        # Off by default. Add the switch to require a change at first logon.
        [switch]$ChangePasswordAtLogon
    )

    # Logon: first initial + lastname - companycode  (e.g. Jdoe-AcmeCorp)
    # The description keeps the full company name; the logon uses a clean token
    if (-not $CompanyCode) { $CompanyCode = ($Company -replace '[^A-Za-z0-9]', '') }
    $firstInitial = $FirstName.Substring(0,1).ToUpper()
    $cleanLast    = ($LastName -replace '[^a-zA-Z0-9]', '').ToLower()
    $logonName    = "$firstInitial$cleanLast-$CompanyCode"

    # sAMAccountName has a 20-char ceiling; keep the UPN full, trim sAM if needed
    $samAccount = $logonName
    if ($samAccount.Length -gt 20) {
        $samAccount = $samAccount.Substring(0, 20)
        Write-Warning "sAMAccountName trimmed to 20 chars: $samAccount (UPN keeps the full name)"
    }

    # Ensure the logon is unique, append a number if it already exists
    $candidate = $samAccount; $i = 1
    while (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction SilentlyContinue) {
        $i++; $candidate = '{0}{1}' -f $samAccount, $i
    }
    $samAccount = $candidate

    $upn = "$logonName@$UpnSuffix"
    if (-not $EmailAddress) { $EmailAddress = $upn }

    # =====================================================================
    # >>> SET YOUR TEMPORARY PASSWORD SCHEME HERE <<<
    # Default below generates a strong random password, which is recommended
    # and safe to publish. If your team must follow a fixed convention,
    # replace the line with your own pattern. The user initials and the
    # $TicketNumber are useful building blocks. Do NOT commit a real
    # convention to a public repository.
    # =====================================================================
    $plainPassword = New-TempPassword
    # Fixed-pattern example only (edit to your scheme, then uncomment):
    # $plainPassword = ('{0}{1}{2}!' -f $FirstName.Substring(0,1), $LastName.Substring(0,1), $TicketNumber).ToLower()

    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force

    # Full name (CN). Append company if a plain First Last already exists
    $displayName = "$FirstName $LastName"
    $cn = $displayName
    if (Get-ADUser -Filter "Name -eq '$cn'" -SearchBase $TargetOU -ErrorAction SilentlyContinue) {
        $cn = "$displayName ($Company)"
    }

    # Resolve the manager to a DN before creation
    $managerDN = $null
    if ($Manager) {
        try { $managerDN = (Get-ADUser -Identity $Manager -ErrorAction Stop).DistinguishedName }
        catch { Write-Warning "Manager '$Manager' not found. Creating without a manager." }
    }

    $userParams = @{
        Name                  = $cn
        GivenName             = $FirstName
        Surname               = $LastName
        DisplayName           = $displayName
        SamAccountName        = $samAccount
        UserPrincipalName     = $upn
        Path                  = $TargetOU
        AccountPassword       = $securePassword
        EmailAddress          = $EmailAddress
        Title                 = $Title
        Description           = "Contractor ($Company)"
        AccountExpirationDate = (Get-Date).AddMonths($ExpirationMonths)
        Enabled               = $true
        ChangePasswordAtLogon = [bool]$ChangePasswordAtLogon
        ErrorAction           = 'Stop'
    }
    if ($managerDN) { $userParams.Manager = $managerDN }

    if ($PSCmdlet.ShouldProcess($cn, 'Create contractor in AD')) {
        try {
            New-ADUser @userParams
            Write-Host "Created $cn ($samAccount)" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to create $cn : $_"
            return
        }
    }

    [pscustomobject]@{
        Name              = $cn
        SamAccountName    = $samAccount
        UserPrincipalName = $upn
        Email             = $EmailAddress
        TempPassword      = $plainPassword
        Manager           = if ($managerDN) { $Manager } else { 'not set' }
        Expires           = (Get-Date).AddMonths($ExpirationMonths).ToString('yyyy-MM-dd')
        OU                = $TargetOU
    }
}

# ---------------------------------------------------------------------------
# Ticket adapter: parse a pasted onboarding form, then create the account
# ---------------------------------------------------------------------------
function New-ContractorFromTicket {
    [CmdletBinding()]
    param(
        # The pasted form block. If omitted, it is read from the clipboard.
        [string]$TicketForm,
        [string]$TicketNumber,
        [string]$CompanyCode,
        [string]$UpnSuffix,
        [string]$TargetOU,
        [switch]$WhatIf,
        [switch]$Verify
    )

    if (-not $TicketForm) { $TicketForm = Get-Clipboard -Raw }
    if ([string]::IsNullOrWhiteSpace($TicketForm)) {
        Write-Warning "No form text supplied and the clipboard was empty."
        return
    }

    # >>> ADAPT THESE LABELS to match your onboarding form exactly <<<
    $labels = @(
        'Vendor Name','Vendor Coordinator','Onboarding Type','First Name',
        'Last Name','Email Address','Manager','Work Location',
        'Start Date','Role(s)','Is a VDI required?'
    )

    # Parse: a known label starts a field, the last non-empty line before the
    # next label is its value (this skips helper text under a label)
    $fields  = @{}
    $current = $null
    foreach ($raw in ($TicketForm -split "`r?`n")) {
        $line = ($raw -replace '[\u200B\uFEFF]', '') -replace '\s+', ' '
        $line = $line.Trim().TrimEnd(':').Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($labels -contains $line) { $current = $line; $fields[$current] = '' }
        elseif ($current)            { $fields[$current] = $line }
    }

    $firstName   = $fields['First Name']
    $lastName    = $fields['Last Name']
    $vendorName  = $fields['Vendor Name']
    $managerName = $fields['Manager']

    foreach ($req in 'First Name','Last Name','Vendor Name') {
        if (-not $fields[$req]) { Write-Warning "Form did not yield '$req' - check the labels and the paste." }
    }

    # Resolve the manager display name to a sAMAccountName
    $managerSam = $managerName
    if ($managerName) {
        $mgr = Get-ADUser -Filter "Name -eq '$managerName'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $mgr) { $mgr = Get-ADUser -Filter "DisplayName -eq '$managerName'" -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if ($mgr) { $managerSam = $mgr.SamAccountName }
        else { Write-Warning "Could not resolve manager '$managerName' in AD." }
    }

    Write-Host "`n--- Parsed from form ---" -ForegroundColor Cyan
    [pscustomobject]@{
        FirstName    = $firstName
        LastName     = $lastName
        Vendor       = $vendorName
        Manager      = "$managerName  ->  $managerSam"
        WorkLocation = $fields['Work Location']
        StartDate    = $fields['Start Date']
        Roles        = $fields['Role(s)']
        VDIRequired  = $fields['Is a VDI required?']
    } | Format-List

    $coreParams = @{
        FirstName    = $firstName
        LastName     = $lastName
        Company      = $vendorName
        TicketNumber = $TicketNumber
    }
    if ($managerSam) { $coreParams.Manager     = $managerSam }
    if ($CompanyCode){ $coreParams.CompanyCode = $CompanyCode }
    if ($UpnSuffix)  { $coreParams.UpnSuffix   = $UpnSuffix }
    if ($TargetOU)   { $coreParams.TargetOU    = $TargetOU }
    if ($WhatIf)     { $coreParams.WhatIf      = $true }

    $result = New-SOWContractor @coreParams
    $result | Format-List

    if ($Verify -and $WhatIf) {
        Write-Host "`n(-Verify skipped on a -WhatIf dry run)" -ForegroundColor DarkGray
    }
    elseif ($Verify) {
        Write-Host "`n--- Verifying the created account ---" -ForegroundColor Cyan
        $u = Get-ADUser -Filter "UserPrincipalName -eq '$($result.UserPrincipalName)'" `
                -Properties SamAccountName,UserPrincipalName,EmailAddress,Title,Description,Manager,AccountExpirationDate,Enabled,pwdLastSet `
                -ErrorAction SilentlyContinue
        if (-not $u) { Write-Host "  FAIL  account not found" -ForegroundColor Red; return }
        function Write-Check ($label, $ok, $actual) {
            $tag = if ($ok) { 'PASS' } else { 'FAIL' }
            $col = if ($ok) { 'Green' } else { 'Red' }
            Write-Host ("  {0}  {1}: {2}" -f $tag, $label, $actual) -ForegroundColor $col
        }
        Write-Check 'sAMAccountName'    ($u.SamAccountName    -eq $result.SamAccountName)    $u.SamAccountName
        Write-Check 'UserPrincipalName' ($u.UserPrincipalName -eq $result.UserPrincipalName) $u.UserPrincipalName
        Write-Check 'Enabled'           ($u.Enabled -eq $true)                               $u.Enabled
        Write-Check 'Manager set'       ([bool]$u.Manager)                                   $u.Manager
        Write-Check 'Must-change off'   ($u.pwdLastSet -ne 0)                                $u.pwdLastSet
        Write-Host  ("  INFO  Expires: {0}" -f $u.AccountExpirationDate) -ForegroundColor Gray
        try {
            Add-Type -AssemblyName System.DirectoryServices.AccountManagement
            $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Domain')
            Write-Check 'Password works' ($ctx.ValidateCredentials($result.SamAccountName, $result.TempPassword)) '(hidden)'
        } catch { Write-Host "  WARN  could not test password: $_" -ForegroundColor Yellow }
    }

    # --- Manual follow-ups this script does not handle ---
    Write-Host "`n--- Manual tasks from this ticket ---" -ForegroundColor Yellow
    Write-Host ("  VDI required:  {0}" -f $fields['Is a VDI required?'])
    Write-Host ("  Access group:  decide from Role(s) = '{0}' and add in your cloud directory" -f $fields['Role(s)'])
    Write-Host ("  Start date:    {0}" -f $fields['Start Date'])
}
