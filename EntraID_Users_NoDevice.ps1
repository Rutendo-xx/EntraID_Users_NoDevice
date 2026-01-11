.SYNOPSIS
Finds ACTIVE Entra ID users from a CSV who have ZERO registered devices in Entra ID.

.DESCRIPTION
This script reads a CSV containing user identifiers (typically email or UPN), checks whether each user
account is enabled (AccountEnabled = True), then checks whether the user has any "registeredDevices"
in Microsoft Entra ID (Azure AD).

Why this matters:
- Identify users who should have a corporate device but do not
- Spot onboarding issues (user exists but device was never enrolled/registered)
- Support device compliance and access reviews

How it works:
1) Connects to Microsoft Graph using delegated permissions
2) Imports users from CSV
3) For each user:
   - Gets user object and confirms AccountEnabled is True
   - Queries the user's registeredDevices with -Top 1 (fast existence check)
   - If no device returned, user is added to results
4) Exports results to CSV

Graph API mapping:
- Get-MgUser translates to: GET /users/{id}?$select=id,displayName,userPrincipalName,accountEnabled
- Get-MgUserRegisteredDevice translates to: GET /users/{id}/registeredDevices?$top=1

REQUIREMENTS
- PowerShell 7+ recommended (works on macOS, Linux, Windows)
- Microsoft Graph PowerShell SDK installed:
    Install-Module Microsoft.Graph -Scope CurrentUser
- Permissions (delegated scopes):
    User.Read.All  (read users to check AccountEnabled)
    Device.Read.All (read device objects / registered devices)
  Note: In many tenants, these require admin consent before they can be used.

INPUT CSV
- Must contain a column with user identifiers.
- Example header: mail
- Example row value: user@company.com

OUTPUT
- CSV file containing only enabled users with no registered devices.

#>

[CmdletBinding()]
param(
    # Path to the input CSV containing user identifiers
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = "/Users/rutendo.mazvi/Downloads/Win10_Users_Entra.csv",

    # Name of the CSV column that holds the user identifier (email/UPN)
    [Parameter(Mandatory = $false)]
    [string]$CsvHeader = "mail",

    # Where to save results
    [Parameter(Mandatory = $false)]
    [string]$OutputCsvPath = "/Users/duro.ojo/Downloads/Win10_Entra_NoDev.csv"

    # Optional: You can add a switch here later if you want Out-GridView on Windows
    # [switch]$ShowGrid
)

# Fail fast on unexpected mistakes (helps catch typos early)
Set-StrictMode -Version Latest

# -------------------------
# 1) Validate input CSV
# -------------------------
if (-not (Test-Path -Path $CsvPath)) {
    throw "CSV file not found at: $CsvPath"
}

$usersToProcess = Import-Csv -Path $CsvPath

if (-not $usersToProcess -or $usersToProcess.Count -eq 0) {
    throw "CSV loaded but contains no rows. Path: $CsvPath"
}

# Ensure the header exists (prevents silent nulls like $row.$CsvHeader returning nothing)
if (-not ($usersToProcess[0].PSObject.Properties.Name -contains $CsvHeader)) {
    $availableHeaders = ($usersToProcess[0].PSObject.Properties.Name -join ", ")
    throw "CSV header '$CsvHeader' not found. Available headers: $availableHeaders"
}

# -------------------------
# 2) Connect to Microsoft Graph
# -------------------------
# Interview point:
# - Use least privilege scopes required for the task.
# - User.Read.All lets us check AccountEnabled.
# - Device.Read.All lets us query registeredDevices.
try {
    Connect-MgGraph -Scopes "User.Read.All", "Device.Read.All" -NoWelcome -ErrorAction Stop
}
catch {
    throw "Could not connect to Microsoft Graph. Error: $($_.Exception.Message)"
}

try {
    # -------------------------
    # 3) Process users
    # -------------------------
    $results = [System.Collections.Generic.List[PSObject]]::new()

    $total = $usersToProcess.Count
    $current = 0

    Write-Host "Processing $total users..." -ForegroundColor Cyan

    foreach ($row in $usersToProcess) {
        $current++

        # Pull the identifier from the chosen CSV column
        $userIdFromCsv = $row.$CsvHeader

        # Skip blank rows safely
        if ([string]::IsNullOrWhiteSpace($userIdFromCsv)) {
            Write-Warning "Row $current has a blank '$CsvHeader' value. Skipping."
            continue
        }

        # Progress is very helpful when CSVs are large
        Write-Progress `
            -Activity "Checking Entra registered devices" `
            -Status "Processing ($current/$total): $userIdFromCsv" `
            -PercentComplete (($current / $total) * 100)

        try {
            # Pull only what we need (performance and clarity)
            # Get-MgUser accepts UPN or ObjectId for -UserId
            $entraUser = Get-MgUser `
                -UserId $userIdFromCsv `
                -Property "id,displayName,userPrincipalName,accountEnabled" `
                -ErrorAction Stop

            # CHECK 1: Only consider enabled accounts
            if ($entraUser.AccountEnabled -ne $true) {
                continue
            }

            # CHECK 2: Does the user have ANY registered device?
            # - Using -Top 1 is an existence check, faster than pulling the full device list.
            # - If the call returns nothing, the user has zero registered devices.
            $device = Get-MgUserRegisteredDevice `
                -UserId $entraUser.Id `
                -Top 1 `
                -ErrorAction SilentlyContinue

            if (-not $device) {
                $results.Add([PSCustomObject]@{
                    UserPrincipalName = $entraUser.UserPrincipalName
                    DisplayName       = $entraUser.DisplayName
                    Status            = "Active"
                    DeviceCount       = 0
                })
            }
        }
        catch {
            # Common causes:
            # - User not found (typo in CSV)
            # - Insufficient Graph permissions or admin consent not granted
            # - Transient Graph errors / throttling
            Write-Warning "Could not process user '$userIdFromCsv'. $($_.Exception.Message)"
        }
    }

    # -------------------------
    # 4) Output results
    # -------------------------
    Write-Progress -Activity "Checking Entra registered devices" -Completed
    Write-Host "`nFound $($results.Count) active users with NO registered devices." -ForegroundColor Green

    # Ensure output directory exists
    $outDir = Split-Path -Path $OutputCsvPath -Parent
    if (-not (Test-Path -Path $outDir)) {
        throw "Output directory does not exist: $outDir"
    }

    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation
    Write-Host "Exported results to: $OutputCsvPath" -ForegroundColor Cyan

    # Optional for Windows only:
    # if ($ShowGrid) { $results | Out-GridView -Title "Active Users Without Devices" }
}
finally {
    # Always clean up the Graph session
    Disconnect-MgGraph | Out-Null
}
