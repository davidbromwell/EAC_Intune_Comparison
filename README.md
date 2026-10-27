GET-EAMCATALOGCOMPARISON.PS1
README - Configuration and Usage
===========================================

PURPOSE
-------
This script reads the Microsoft Intune Enterprise App Catalog through Microsoft
Graph and compares catalog application names with an existing Intune managed-apps
CSV export. It creates a full-catalog CSV report and, when matches are found, a
second CSV report with possible matches.

Line numbers below refer to the ORIGINAL 297-line file:
Get-EAMCatalogComparison.blank(2).ps1
If the script is edited or reformatted, search for the settings by name.

1. REQUIRED CONFIGURATION CHANGES
---------------------------------
LINE 27: Microsoft Entra tenant ID
  Replace YOUR-TENANT-ID-HERE with your own tenant ID.

  Original: $TenantId = "YOUR-TENANT-ID-HERE"
  Example:  $TenantId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

  Find your tenant ID in Microsoft Entra admin center > Identity > Overview.

LINE 30: Intune managed-applications CSV location
  Supply the FULL path to your existing Intune applications CSV export.

  Original: $ManagedAppsCsvPath = "C:\Temp\Client_apps.csv"
  Example:  $ManagedAppsCsvPath = "C:\Users\YourUserName\Downloads\Client_apps.csv"

  The script does NOT create this CSV. It requires a Name column for matching.
  Include Type, Version, and Assigned columns to populate those result fields.
  Example CSV header: Name,Type,Version,Assigned
  Platform and Developer are mentioned by the script's no-match message but
  are not used by its comparison logic.
  If your CSV uses DisplayName instead of Name, rename the CSV header or
  update the reference to $ManagedApp.Name at LINE 205.

LINE 212: Example organization prefixes (MTV, CMT, VIA)
  Replace the example prefixes in the comment with your organization's own
  prefixes, or remove the examples if your app names do not have prefixes.
  IMPORTANT: Line 212 is ONLY A COMMENT. Changing these names does NOT change
  how the comparison works.

LINE 213: Prefix removal REGULAR EXPRESSION
  Review this line and update it to match your actual naming convention.
  This is the line that controls prefix removal.

  Original:
    $ManagedNameClean = $ManagedName -replace '^[A-Z0-9]{2,4}\s[-]\s', ''

  As written, the expression removes ANY two-to-four uppercase-letter/digit
  prefix followed by a space, hyphen, and space. It is not limited to the
  three example prefixes in line 212.

  Example if your organization uses ABC - , XYZ - , and HQ - :
    Line 212 comment: # Strip prefixes (e.g. "ABC - ", "XYZ - ", "HQ - ")
    Line 213 code:    $ManagedNameClean = $ManagedName -replace '^(ABC|XYZ|HQ)\s-\s', ''

  If your organization does not prefix app names, set line 213 to:
    $ManagedNameClean = $ManagedName

  Keep the following .Trim() call at LINE 214.
  Do not copy example prefixes unless they match your own environment.

2. OPTIONAL SETTINGS
--------------------
LINES 33-35: $OutputFolder
  Reports are saved in the script folder by default, with C:\Temp as a fallback.
  To change the location, supply an existing, writable folder. The script
  does not create the destination folder.

LINE 39: $PublicClientId
  This is an application client identifier, not your tenant ID or a secret.
  Do not change it only because you use a different tenant. Change it only
  as part of an approved authentication setup with a correctly registered
  redirect URI and permissions.

LINES 43-44: $LocalPort and $RedirectUri
  The script listens at http://localhost:8400/ for the sign-in response.
  A new port also needs to be allowed by the application registration's
  redirect configuration. Changing just the number may not work.

LINE 82: YubiKey sign-in message
  The YubiKey mention is informational text and can be changed if it does not
  apply in your organization.

3. REQUIREMENTS AND PERMISSIONS
--------------------------------
- Windows PowerShell 5.1 on Windows.
- An Intune tenant and a pre-existing managed-applications CSV file.
- Account permissions to read Intune application information.
- Microsoft Graph delegated DeviceManagementApps.Read.All permission and
  administrator consent where required. A role alone does not guarantee consent.
- Appropriate Enterprise App Management licensing and beta API availability.
  Intune Suite is one possible entitlement; EAM can also be licensed separately.
- Browser-based interactive sign-in, port 8400 usable for the local listener,
  and write permissions in the output folder.
- No additional PowerShell modules are imported or installed by this script.

4. HOW TO RUN
-------------
1. Keep the script and this README together.
2. Edit lines 27, 30, 212, and (as applicable) 213.
3. Confirm the CSV file and output folder exist.
4. Open Windows PowerShell 5.1 and change to the script's directory.
5. To run with the downloaded filename:

     & ".\Get-EAMCatalogComparison.blank(2).ps1"

   Or, if renamed to Get-EAMCatalogComparison.ps1:

     .\Get-EAMCatalogComparison.ps1

6. Complete the browser sign-in and inspect the CSV reports.

Do not disable execution policy, Conditional Access, or tenant consent controls
solely to run this script. Use an approved alternative when required.

5. OUTPUT FILES
---------------
EAM_Full_Catalog_YYYY-MM-DD.csv
  Product IDs, display names, versions, and publishers of retrieved catalog apps.

EAM_Catalog_Matches_YYYY-MM-DD.csv
  Possible matches, with managed-app fields and catalog-app details.
  This file is created ONLY when at least one match exists.

The output folder defaults to the script's directory. Repeated runs on the
same date can overwrite same-named CSV output files. The match report can
contain INTERNAL APPLICATION INVENTORY. Review/sanitize reports separately
before sharing.

Matching is based on partial names and returns the first hit. Results are
candidates for review, not proof that two products are equivalent. The script
does not compare versions to determine update or compliance status.

6. SECURITY AND KNOWN LIMITATIONS
---------------------------------
- The script uses Graph HTTP GET requests. It does not intentionally change
  Intune apps, assignments, or policies, but it writes local CSV files.
- The sign-in flow is custom browser/localhost OAuth, not WAM. It does not
  implement PKCE and has no timeout while waiting for the redirect. It is not
  a hardened authentication design. An approved authentication library or
  Microsoft Graph PowerShell with WAM is preferable for enterprise use.
- The tenant must allow the selected public client and redirect URI. Editing
  the tenant ID does not guarantee a successful sign-in.
- API retry/backoff logic is not implemented.
- Script header LINE 3 displays version 1.0; banner LINE 248 displays v3.0.
- This README describes the original script as written; no tenant execution
  or Windows PowerShell 5.1 validation is claimed.

7. TROUBLESHOOTING
-----------------
CSV not found: Correct line 30 and confirm file permissions.
No matches: Verify the Name column and prefix expression on lines 212-214.
Listener failure: Check port 8400 and HTTP URL reservations.
Sign-in failure: Check tenant ID, client/redirect support, consent, delegated
  permissions, and Conditional Access. Do not bypass security controls.
Graph failure: Check permissions, licensing, and beta API availability.
CSV write failure: Confirm the output folder exists and is writable; close
  applications that may be locking the CSV file.

REDISTRIBUTION REMINDER
-----------------------
Replace tenant, CSV-path, and organization-prefix placeholders for your own
use. Never place passwords, secrets, access tokens, or other credentials in
a shared script or report.
