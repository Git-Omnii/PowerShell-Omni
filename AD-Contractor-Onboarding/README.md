# AD Contractor Onboarding

A PowerShell tool that creates on-premises Active Directory accounts for vendors and contractors. It can build the account from explicit values or parse a pasted onboarding form and do it in one step. It includes a dry-run preview and a post-creation check.

Everything specific to an environment ships as a placeholder, so nothing real lives in the script.

## Features

- Builds the logon name, UPN, description, and a six month account expiration
- Generates a strong random temporary password by default, with a clearly marked spot to drop in your own scheme if you must match a convention
- Parses a pasted onboarding form and creates the account in one command
- Preview mode (`-WhatIf`) shows exactly what would be created without writing anything
- Verification (`-Verify`) reads the account back and confirms each attribute, and that the password authenticates
- Detects duplicate logon names and adjusts automatically
- Only ever creates and reads. It never deletes or modifies existing accounts

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- The ActiveDirectory module (RSAT)
- An account with rights to create users in the target OU

## Setup

Open `New-SOWContractor.ps1` and edit three things near the top of the `New-SOWContractor` function:

1. `UpnSuffix`, set to your routable UPN suffix
2. `TargetOU`, set to the distinguished name of the OU new accounts go into
3. The password scheme, in the block marked `SET YOUR TEMPORARY PASSWORD SCHEME HERE`. By default it generates a strong random password. Replace it only if you must follow a fixed convention.

If you use the form parser, also adapt the `$labels` list in `New-ContractorFromTicket` to match your onboarding form's field labels.

Then load the functions:
```powershell
. .\New-SOWContractor.ps1
```

## Usage

Create from explicit values:
```powershell
New-SOWContractor -FirstName Jane -LastName Doe -Company "Acme Corp" -Manager j.smith -WhatIf
```

Create from a pasted form. Copy the form first, then run, and it reads the clipboard:
```powershell
New-ContractorFromTicket -TicketNumber 12345 -Verify
```

Drop `-WhatIf` to perform the real creation. Run with `-WhatIf` first every time you change a default.

## Security notes

- The recommended default is a random temporary password. A fixed scheme is supported only for compatibility with an existing process, and a random password is always preferable.
- The script ships with placeholder values only. Keep your real domain, OU, and any password convention out of the committed copy.
- The tool runs under your own privileged account and grants no new access.

## Roadmap

- Vendor short-code lookup so multi-word vendors map to a clean logon name
- Auto-load as a module in every session
- Optional bulk mode from a CSV or multiple forms

## Disclaimer

Provided as is. Test with `-WhatIf` against your own directory before creating live accounts.
