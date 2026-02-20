# Ever-Covered.md

The goal is to write a utility script that will produce a report showing all the mailbox users that have ever been backed up in a connector. This script will use the Keepit PowerShekll tools module.

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

## design

1. Use PowerShell best practices for error handling, user input, display, etc.

## parameters

- Credential: optional. If supplied, use it to connect to the Keepit service. If not, prompt the user for username and password and create a Credential object
- Environment: required. Must be one of the supported Keepit environment regions.
- Connector: optional. If not supplied, we'll prompt the user

## business logic

1. Load the Keepit PowerShell tools module. Fail if it's not available
2. Connect to the Keepit service
3. Validate the connector:
- If the user didn't supply a connector, call Get-keepitConnector -type o365-admin and give them a list to choose from.
- if the user did supply a connector name, call Get-KeepitConnector on its name and verify that it exists and is of type o365-admin.
4. Generate the report, which will be output as a CSV file.

### building the report

1. Create an empty list of users. Each entry in the list contains the user UPN and a timestamp.
2. Get the first snapshot on the connector
3. use Search-KeepitSnapshot to search that snapshot for "/Users/". That will create a list of all the users that were included in the snapshot.
4. Filter that list to exclude user whose path doesn't have /Outlook (e.g. ignore any users where there is no path for /Users/abcde/Outlook)
Add the results of step 4 to the list if they don't already exist
Go to the next snapshot
repeat steps 2-6