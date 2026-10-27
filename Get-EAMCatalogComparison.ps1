# ==============================================================================
# Script Name  : Get-EAMCatalogComparison.ps1
# Version      : 1.0
# Author       : David Bromwell
# Description  : Queries the Microsoft Graph API for all available Enterprise
#                App Catalog apps and cross-references them against your Intune
#                managed apps CSV export. Outputs two CSV files:
#                  1. Full Enterprise App Catalog list
#                  2. Matched apps (apps in your tenant that are in the catalog)
#
# Requirements : - Intune Suite license (required to query the catalog endpoint)
#                - An account with DeviceManagementApps.Read.All delegated
#                  permission (Intune Administrator role covers this)
#                - PowerShell 5.1
#                - .NET Framework (included with Windows)
#
# Auth Method  : System default browser (Chrome, Edge, etc.) is launched for
#                login. Fully supports FIDO2/WebAuthn/YubiKey and all modern
#                Conditional Access policies. A local HTTP listener on
#                localhost:8400 catches the redirect and auth code automatically.
#                No app registration, client secret, or device code needed.
# ==============================================================================

#region CONFIGURATION
# ----------------------------------------------------------------------------
# Your tenant ID (found in Entra ID > Overview)
$TenantId = "YOUR-TENANT-ID-HERE"

# Path to your Intune managed apps CSV export
$ManagedAppsCsvPath = "C:\Temp\Client_apps.csv"

# Output folder for results (defaults to the folder this script is in)
$OutputFolder = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutputFolder) { $OutputFolder = $PSScriptRoot }
if (-not $OutputFolder) { $OutputFolder = "C:\Temp" }

# Microsoft's well-known public client ID (same one used by Graph Explorer)
# Supports delegated auth without needing your own app registration
$PublicClientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e"

# Local redirect URI - a temporary HTTP listener on this port catches the response
# Port 8400 is used here; change it if something else is already using it
$LocalPort       = 8400
$RedirectUri     = "http://localhost:$LocalPort/"
#endregion CONFIGURATION

# ==============================================================================
#region FUNCTIONS
# ==============================================================================

function Get-BrowserAccessToken {
    param (
        [string]$TenantId,
        [string]$ClientId,
        [string]$RedirectUri,
        [int]$LocalPort
    )

    Add-Type -AssemblyName System.Web

    # Generate a random state value to prevent CSRF
    $State = [System.Guid]::NewGuid().ToString("N")

    $Scope       = [System.Uri]::EscapeDataString("https://graph.microsoft.com/DeviceManagementApps.Read.All offline_access openid profile")
    $RedirectEnc = [System.Uri]::EscapeDataString($RedirectUri)
    $AuthUrl     = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize?client_id=$ClientId&response_type=code&redirect_uri=$RedirectEnc&scope=$Scope&prompt=select_account&state=$State"

    # Start the local HTTP listener before opening the browser
    $Listener = New-Object System.Net.HttpListener
    $Listener.Prefixes.Add($RedirectUri)

    try {
        $Listener.Start()
    }
    catch {
        Write-Host "[ERROR] Could not start local HTTP listener on port $LocalPort." -ForegroundColor Red
        Write-Host "[ERROR] Check if another process is using port $LocalPort and update the LocalPort variable if needed." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "[INFO] Local listener started on $RedirectUri" -ForegroundColor Cyan
    Write-Host "[INFO] Opening your default browser for login. Sign in with your YubiKey-backed admin account..." -ForegroundColor Cyan

    # Launch the default system browser
    Start-Process $AuthUrl

    Write-Host "[INFO] Waiting for you to complete login in the browser..." -ForegroundColor Gray

    # Wait for the browser to redirect back to localhost with the auth code
    $Context  = $Listener.GetContext()
    $Request  = $Context.Request
    $Response = $Context.Response

    # Send a simple response page so the browser tab closes cleanly
    $HtmlResponse = "<html><body><h2>Authentication complete. You can close this tab and return to PowerShell.</h2></body></html>"
    $Buffer       = [System.Text.Encoding]::UTF8.GetBytes($HtmlResponse)
    $Response.ContentLength64 = $Buffer.Length
    $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
    $Response.OutputStream.Close()
    $Listener.Stop()

    # Parse the auth code and state out of the query string
    $QueryString  = $Request.Url.Query.TrimStart("?")
    $Params       = [System.Web.HttpUtility]::ParseQueryString($QueryString)
    $AuthCode     = $Params["code"]
    $ReturnedState = $Params["state"]

    if (-not $AuthCode) {
        $Error = $Params["error"]
        $ErrorDesc = $Params["error_description"]
        Write-Host "[ERROR] No authorization code received." -ForegroundColor Red
        if ($Error) { Write-Host "[ERROR] $Error - $ErrorDesc" -ForegroundColor Red }
        exit 1
    }

    if ($ReturnedState -ne $State) {
        Write-Host "[ERROR] State mismatch. Possible CSRF attempt. Aborting." -ForegroundColor Red
        exit 1
    }

    Write-Host "[INFO] Authorization code received. Exchanging for access token..." -ForegroundColor Cyan

    # Exchange auth code for access token
    $TokenUrl  = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $TokenBody = @{
        grant_type   = "authorization_code"
        client_id    = $ClientId
        code         = $AuthCode
        redirect_uri = $RedirectUri
        scope        = "https://graph.microsoft.com/DeviceManagementApps.Read.All offline_access openid profile"
    }

    try {
        $TokenResponse = Invoke-RestMethod -Uri $TokenUrl -Method POST -Body $TokenBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        Write-Host "[INFO] Access token acquired successfully." -ForegroundColor Green
        return $TokenResponse.access_token
    }
    catch {
        Write-Host "[ERROR] Token exchange failed: $_" -ForegroundColor Red
        exit 1
    }
}

function Get-AllEAMCatalogApps {
    param (
        [string]$AccessToken
    )

    $Headers = @{
        Authorization  = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }

    $Uri       = "https://graph.microsoft.com/beta/deviceAppManagement/mobileAppCatalogPackages"
    $AllApps   = @()
    $PageCount = 0

    Write-Host "[INFO] Querying Enterprise App Catalog via Microsoft Graph (beta)..." -ForegroundColor Cyan
    Write-Host "[INFO] This may take a moment as the catalog contains 1000+ entries..." -ForegroundColor Cyan

    do {
        $PageCount++
        Write-Host "[INFO] Fetching page $PageCount..." -ForegroundColor Gray

        try {
            $Response = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method GET -ErrorAction Stop
        }
        catch {
            Write-Host "[ERROR] Graph API call failed: $_" -ForegroundColor Red
            Write-Host "[ERROR] Ensure your account has DeviceManagementApps.Read.All and the Intune Suite license is active." -ForegroundColor Yellow
            exit 1
        }

        if ($Response.value) {
            $AllApps += $Response.value
        }

        $Uri = $Response.'@odata.nextLink'

    } while ($Uri)

    Write-Host "[INFO] Retrieved $($AllApps.Count) catalog entries." -ForegroundColor Green
    return $AllApps
}

function Compare-AppsAgainstCatalog {
    param (
        [array]$CatalogApps,
        [string]$ManagedAppsCsvPath
    )

    if (-not (Test-Path $ManagedAppsCsvPath)) {
        Write-Host "[ERROR] Managed apps CSV not found at: $ManagedAppsCsvPath" -ForegroundColor Red
        exit 1
    }

    Write-Host "[INFO] Loading managed apps from CSV: $ManagedAppsCsvPath" -ForegroundColor Cyan
    $ManagedApps = Import-Csv -Path $ManagedAppsCsvPath -ErrorAction Stop
    Write-Host "[INFO] Loaded $($ManagedApps.Count) managed app entries." -ForegroundColor Green
    Write-Host "[INFO] Running comparison..." -ForegroundColor Cyan

    $Matches = @()

    foreach ($ManagedApp in $ManagedApps) {
        $ManagedName = ($ManagedApp.Name -replace '"', '').Trim()
        if ([string]::IsNullOrWhiteSpace($ManagedName)) { continue }

        foreach ($CatalogApp in $CatalogApps) {
            $CatalogName = $CatalogApp.productDisplayName
            if ([string]::IsNullOrWhiteSpace($CatalogName)) { continue }

            # Strip common org prefixes (e.g. "MTV - ", "CMT - ", "VIA - ") before comparing
            $ManagedNameClean = $ManagedName -replace '^[A-Z0-9]{2,4}\s[-]\s', ''
            $ManagedNameClean = $ManagedNameClean.Trim()

            $IsMatch = (
                ($ManagedNameClean -like "*$CatalogName*") -or
                ($CatalogName -like "*$ManagedNameClean*")
            )

            if ($IsMatch) {
                $Matches += [PSCustomObject]@{
                    ManagedAppName     = $ManagedName
                    ManagedAppType     = $ManagedApp.Type
                    ManagedAppVersion  = $ManagedApp.Version
                    ManagedAppAssigned = $ManagedApp.Assigned
                    CatalogDisplayName = $CatalogApp.productDisplayName
                    CatalogVersion     = $CatalogApp.productVersionDisplayName
                    CatalogPublisher   = $CatalogApp.publisherDisplayName
                    CatalogProductId   = $CatalogApp.productId
                }
                break
            }
        }
    }

    return $Matches
}

#endregion FUNCTIONS

# ==============================================================================
#region MAIN
# ==============================================================================

Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "  Get-EAMCatalogComparison.ps1 - v3.0 - David Bromwell" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Browser-based login (supports YubiKey/FIDO2/WebAuthn)
$AccessToken = Get-BrowserAccessToken -TenantId $TenantId -ClientId $PublicClientId -RedirectUri $RedirectUri -LocalPort $LocalPort

# Step 2: Pull the full Enterprise App Catalog
$CatalogApps = Get-AllEAMCatalogApps -AccessToken $AccessToken

# Step 3: Export the full catalog to CSV
$CatalogOutputPath = Join-Path $OutputFolder "EAM_Full_Catalog_$(Get-Date -Format 'yyyy-MM-dd').csv"

$CatalogApps | Select-Object @{N="ProductId";   E={$_.productId}},
                              @{N="DisplayName"; E={$_.productDisplayName}},
                              @{N="Version";     E={$_.productVersionDisplayName}},
                              @{N="Publisher";   E={$_.publisherDisplayName}} |
    Export-Csv -Path $CatalogOutputPath -NoTypeInformation -Encoding UTF8

Write-Host "[INFO] Full catalog exported to: $CatalogOutputPath" -ForegroundColor Green

# Step 4: Compare against your managed apps CSV
$MatchedApps = Compare-AppsAgainstCatalog -CatalogApps $CatalogApps -ManagedAppsCsvPath $ManagedAppsCsvPath

# Step 5: Export matches to CSV
if ($MatchedApps.Count -gt 0) {
    $MatchOutputPath = Join-Path $OutputFolder "EAM_Catalog_Matches_$(Get-Date -Format 'yyyy-MM-dd').csv"
    $MatchedApps | Export-Csv -Path $MatchOutputPath -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "=======================================================" -ForegroundColor Green
    Write-Host "  RESULTS SUMMARY" -ForegroundColor Green
    Write-Host "=======================================================" -ForegroundColor Green
    Write-Host "  Total catalog entries    : $($CatalogApps.Count)" -ForegroundColor White
    Write-Host "  Matched apps in your CSV : $($MatchedApps.Count)" -ForegroundColor White
    Write-Host "  Full catalog saved to    : $CatalogOutputPath" -ForegroundColor White
    Write-Host "  Matches saved to         : $MatchOutputPath" -ForegroundColor White
    Write-Host "=======================================================" -ForegroundColor Green
    Write-Host ""

    Write-Host "Matched Applications:" -ForegroundColor Yellow
    $MatchedApps | Format-Table ManagedAppName, CatalogDisplayName, CatalogVersion, CatalogPublisher -AutoSize
}
else {
    Write-Host "[WARN] No matches found. Verify your CSV column headers match: Name, Platform, Type, Version, Assigned, Developer" -ForegroundColor Yellow
}

Write-Host "[INFO] Script completed." -ForegroundColor Green

#endregion MAIN
