# Copy-EntraGroupToKeepit.ps1

This script, stored in the /Examples/GroupSync folder, accepts an Entra security or distribution group name, connects to Entra ID, and resolves the group membership into a list of users.

It then uses the Keepit PowerShell tools module to create users with the specified Keepit role.

Parameters:

- GroupName (required, string): the name or GUID of the Entra group to be expanded
- EntraCredential (optional): credential to use when authenticating to Entra/Microsoft Graph; if omitted, browser-based authentication is used
- KeepitCredential (required): credential to use when calling Connect-KeepitService
- Role (required, string): the Keepit role to be assigned to the new user. Must be one of the following: BackupAdmin, MasterAdmin, FullSupport, StandardSupport, ComplianceAdmin, LimitedSupport, Audit, SsoAdmin
- Connectors (required): either the string "all" to grant access to all connectors, or a list of connector names or GUIDs
- SendActivationEmail (optional switch): if specified, send an activation email to each newly created user
- NotificationsEnabled (optional switch): if specified, enable email notifications for each newly created user
- Verbose (optional): give additional verbose output

## Key Design Principles

- **Cross-platform PowerShell**: Code must run on Linux, macOS, and Windows using PowerShell 7+
- **PowerShell script module**: Structured as a script module (.psm1) with module manifest (.psd1)
- **Microsoft guidelines compliance**:
  - Follow [Required Development Guidelines](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/required-development-guidelines)
  - Follow [Strongly Encouraged Guidelines](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/strongly-encouraged-development-guidelines)
  - Follow [Advisory Guidelines](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/advisory-development-guidelines)
- **Pipeline parameter binding**: For parameters that accept pipeline input by property name (e.g., `Connector` binding to output `ConnectorGuid` property), use only `ValueFromPipelineByPropertyName = $true`. Do NOT combine it with `ValueFromPipeline = $true` on `[string]` parameters, as this causes PowerShell to attempt converting the entire pipeline object to a string, which fails silently and produces empty output.
- **Structured exception handling**: Use try/catch blocks throughout
- **Include cmdlet help**: All cmdlets must have comment-based help or MAML help

## Business Logic

1. Load the required Entra module (Microsoft.Graph); fail with a clear message if it can't be loaded or isn't found.
2. Load the Keepit PowerShell tools module; fail with a clear message if it can't be loaded or isn't found.
3. Call `Connect-MgGraph`; if EntraCredential isn't supplied, use browser authentication. Stop the script if auth fails.
4. Call `Connect-KeepitService` using the supplied KeepitCredential; stop the script if auth fails.
5. Recursively expand the membership of the specified GroupName, following nested groups, until a flat list of user objects is obtained. Stop the script if the group is not found or expansion fails.
6. For each user in the expanded list, attempt to call `New-KeepitUser` to create the user, passing the display name, email/UPN, role, connectors, and any supplied switches. If creation fails for a user, display an error and continue to the next user.
7. Emit one per-user result object for each user attempted, regardless of success or failure. Each object should include at minimum: Email, Name, Status (Created / AlreadyExists / Failed), and Error (if applicable).
