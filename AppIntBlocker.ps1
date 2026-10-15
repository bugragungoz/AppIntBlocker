# ===============================================================
# GENERAL PURPOSE APPLICATION INTERNET ACCESS BLOCKER TOOL
# ===============================================================
# DESCRIPTION:
# This script blocks or manages internet access for executable files
# by creating/removing Windows Firewall rules. Includes options for
# system restore points and logging.
#
# Only .exe files are blocked. Windows Firewall matches a program rule
# against the executable of the process that owns the connection; a
# DLL runs inside such a process, so a rule for a .dll never matches
# any traffic.
#
# INTENDED USE CASES:
# - Enhancing privacy, reducing bandwidth, improving performance.
# - Blocking distracting updates/notifications.
# - Configuring local network applications.
#
# !!! LEGAL DISCLAIMER AND RESPONSIBILITY !!!
# Use this tool responsibly and legally. Circumventing licenses or
# copyright protection is ILLEGAL and the user's SOLE responsibility.
# Comply with all software licenses and laws. Author is not liable for misuse.
# ===============================================================

#Requires -RunAsAdministrator

# --- Script Configuration ---
$LogFileName = "AppBlocker.log"
$LogFilePath = Join-Path -Path $PSScriptRoot -ChildPath $LogFileName
$RuleNamePrefix = "AppBlocker Rule -" # Consistent prefix for rules created by this script

# --- UI Colors ---
$titleColor = "Cyan"
$menuColor = "Yellow"
$successColor = "Green"
$warningColor = "DarkYellow"
$errorColor = "Red"
$infoColor = "White"
$processColor = "DarkGray"
$promptColor = "Magenta"

# --- Functions ---

# Function to write messages to a log file
function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO"
    )

    $logEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    try {
        Add-Content -Path $LogFilePath -Value $logEntry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file '$LogFilePath'. Error: $($_.Exception.Message)"
    }
}

# Returns the firewall rules created by this script, optionally only those of one application.
# The application is matched here instead of in the query, so [ and ] in its name are not
# read as wildcards.
function Get-BlockRule {
    param (
        [string]$ApplicationName
    )

    $rules = @(Get-NetFirewallRule -DisplayName "$($RuleNamePrefix)*" -ErrorAction SilentlyContinue)
    if ($ApplicationName) {
        $appPrefix = "$($RuleNamePrefix)$($ApplicationName) - "
        $rules = @($rules | Where-Object { $_.DisplayName.StartsWith($appPrefix, [System.StringComparison]::OrdinalIgnoreCase) })
    }
    return $rules
}

# Creates a Windows Firewall rule for a specific file
function New-BlockRule {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        [Parameter(Mandatory=$true)]
        [string]$DisplayName,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Inbound", "Outbound")]
        [string]$Direction
    )

    try {
        New-NetFirewallRule -DisplayName $DisplayName -Direction $Direction -Program $FilePath -Action Block -Profile Any -Enabled True -ErrorAction Stop | Out-Null
        $logMsg = "Successfully created rule '$DisplayName' for '$FilePath'."
        Write-Log -Message $logMsg -Level "INFO"
        return $true
    }
    catch {
        $errMsg = "Failed to create rule '$DisplayName' for '$FilePath'. Error: $($_.Exception.Message)"
        Write-Warning "  $errMsg"
        Write-Log -Message $errMsg -Level "ERROR"
        return $false
    }
}

# Removes existing firewall rules matching the application name pattern
function Remove-ExistingRule {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ApplicationName # Used to build the display name pattern
    )

    # Use the consistent prefix and the specific app name
    $rulePattern = "$($RuleNamePrefix)$($ApplicationName) - *"
    Write-Host "`nChecking for existing rules matching '$rulePattern'..." -ForegroundColor $infoColor
    Write-Log -Message "Checking for existing rules matching pattern '$rulePattern'."

    $existingRules = @()
    try {
        $existingRules = @(Get-BlockRule -ApplicationName $ApplicationName)
    }
    catch {
         $errMsg = "An error occurred while retrieving firewall rules: $($_.Exception.Message)"
         Write-Warning $errMsg
         Write-Log -Message $errMsg -Level "ERROR"
         return
    }

    $ruleCount = $existingRules.Count

    if ($ruleCount -gt 0) {
        Write-Host "Found $ruleCount existing rule(s) for '$ApplicationName'." -ForegroundColor $warningColor
        Write-Log -Message "Found $ruleCount existing rules for '$ApplicationName'."
        $removeChoice = Read-Host -Prompt "Do you want to remove these rules before creating new ones? (Y/N)"

        if ($removeChoice -match '^y') {
            Write-Host "Removing $ruleCount existing rule(s)..." -ForegroundColor $infoColor
            Write-Log -Message "User chose to remove $ruleCount existing rules for '$ApplicationName'."
            try {
                $existingRules | Remove-NetFirewallRule -ErrorAction Stop
                Write-Host "Successfully removed $ruleCount rule(s)." -ForegroundColor $successColor
                Write-Log -Message "Successfully removed $ruleCount rules for '$ApplicationName'."
                return
            }
            catch {
                 $errMsg = "An error occurred while removing rules for '$ApplicationName': $($_.Exception.Message)"
                 Write-Warning $errMsg
                 Write-Log -Message $errMsg -Level "ERROR"
                 Write-Warning "Some rules might not have been removed. Please check Windows Firewall manually."
                 return
            }
        } else {
            Write-Host "Keeping existing rules." -ForegroundColor $warningColor
            Write-Log -Message "User chose to keep existing rules for '$ApplicationName'."
            return
        }
    } else {
        Write-Host "No existing rules found matching the pattern for '$ApplicationName'." -ForegroundColor $infoColor
        Write-Log -Message "No existing rules found for '$ApplicationName'."
        return
    }
}

# Blocks internet access for the .exe files in the specified directory
function Block-Application {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ApplicationPath,
        [Parameter(Mandatory=$true)]
        [string]$ApplicationName, # This name is used in the rule DisplayName
        [string[]]$ExcludedKeywords = @(),
        [string[]]$ExcludedFiles = @()
    )

    Write-Log -Message "Starting blocking process for App: '$ApplicationName', Path: '$ApplicationPath', ExcludedKeywords: $($ExcludedKeywords -join ', '), ExcludedFiles: $($ExcludedFiles -join ', ')"

    # Validate the directory path
    if (-not (Test-Path -Path $ApplicationPath -PathType Container)) {
        $errMsg = "ERROR: The specified path '$ApplicationPath' was not found or is not a valid directory."
        Write-Host $errMsg -ForegroundColor $errorColor
        Write-Log -Message $errMsg -Level "ERROR"
        return
    }

    $rootPath = (Get-Item -Path $ApplicationPath).FullName
    Write-Host "`nScanning directory '$ApplicationPath' (and subdirectories) for .exe files..." -ForegroundColor $infoColor

    $filesToProcess = @()
    try {
        $filesToProcess = @(Get-ChildItem -Path $ApplicationPath -Recurse -Filter "*.exe" -File -ErrorAction SilentlyContinue)
    }
    catch {
         $errMsg = "An error occurred during file scanning in '$ApplicationPath': $($_.Exception.Message)"
         Write-Warning $errMsg
         Write-Log -Message $errMsg -Level "ERROR"
         return
    }

    if ($filesToProcess.Count -eq 0) {
        $warnMsg = "No .exe files found in '$ApplicationPath'."
        Write-Warning $warnMsg
        Write-Log -Message $warnMsg -Level "WARN"
        return
    }

    Write-Host "Found $($filesToProcess.Count) .exe file(s)." -ForegroundColor $infoColor
    Write-Log -Message "Found $($filesToProcess.Count) potential files to process for '$ApplicationName'."

    # Filter files based on exclusions
    $filesToBlock = @()
    $filesToSkip = @()

    foreach ($file in $filesToProcess) {
        $shouldSkip = $false
        if ($ExcludedFiles -contains $file.Name) {
            $shouldSkip = $true
            Write-Log -Message "Skipping file '$($file.Name)' due to exact filename exclusion." -Level "DEBUG"
        }
        if (-not $shouldSkip -and $ExcludedKeywords.Count -gt 0) {
            foreach ($keyword in $ExcludedKeywords) {
                if ($file.Name -like "*$keyword*") {
                    $shouldSkip = $true
                    Write-Log -Message "Skipping file '$($file.Name)' due to keyword '$keyword' exclusion." -Level "DEBUG"
                    break
                }
            }
        }
        if ($shouldSkip) { $filesToSkip += $file } else { $filesToBlock += $file }
    }

    Write-Host "Files to block after exclusions: $($filesToBlock.Count)" -ForegroundColor $infoColor
    if ($filesToSkip.Count -gt 0) { Write-Host "Files skipped due to exclusions: $($filesToSkip.Count)" -ForegroundColor $infoColor }
    Write-Log -Message "Files to block for '$ApplicationName': $($filesToBlock.Count). Files skipped: $($filesToSkip.Count)."

    if ($filesToBlock.Count -eq 0) {
        $warnMsg = "No files remaining to block for '$ApplicationName' after applying exclusions."
        Write-Warning $warnMsg
        Write-Log -Message $warnMsg -Level "WARN"
         if ($filesToSkip.Count -gt 0) {
             Write-Host "`nSkipped files:" -ForegroundColor $infoColor
             $filesToSkip | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor $processColor }
        }
        return
    }

    # --- Create Firewall Rules ---
    $totalFilesToBlock = $filesToBlock.Count
    $currentFileIndex = 0
    $successRuleCount = 0
    $errorFileCount = 0

    Write-Host "`nCreating firewall rules..." -ForegroundColor $infoColor
    Write-Log -Message "Starting firewall rule creation for $($filesToBlock.Count) files for '$ApplicationName'."

    # Read the application's existing rules once, rather than querying the firewall for every
    # rule name in the loop below
    $existingRuleNames = @{}
    foreach ($rule in @(Get-BlockRule -ApplicationName $ApplicationName)) { $existingRuleNames[$rule.DisplayName] = $true }

    foreach ($file in $filesToBlock) {
        $currentFileIndex++
        $percentComplete = [math]::Round(($currentFileIndex / $totalFilesToBlock) * 100)
        Write-Progress -Activity "Creating rules for '$($ApplicationName)'" -Status "$percentComplete% Complete" -PercentComplete $percentComplete -CurrentOperation "Processing: $($file.Name)"

        # Use the consistent prefix + App Name + the file's path inside the application folder, so
        # files with the same name in different subfolders (x86\setup.exe, x64\setup.exe) each get
        # their own rules. Files directly in the folder keep the plain file name.
        $relativePath = $file.Name
        if ($file.FullName.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $file.FullName.Substring($rootPath.Length).TrimStart('\', '/')
        }
        $baseRuleName = "$($RuleNamePrefix)$($ApplicationName) - $relativePath"
        if ($baseRuleName.Length -gt 220) { $baseRuleName = $baseRuleName.Substring(0, 220) + "..." }

        Write-Host "Processing: $($file.FullName)" -ForegroundColor $processColor

        $fileFailed = $false
        foreach ($direction in @("Inbound", "Outbound")) {
            $ruleName = "$($baseRuleName) ($direction)"
            if ($existingRuleNames.ContainsKey($ruleName)) {
                $logMsg = "Skipping: Rule '$ruleName' already exists for '$($file.FullName)'."
                Write-Host "  $logMsg" -ForegroundColor $processColor
                Write-Log -Message $logMsg -Level "DEBUG"
            }
            elseif (New-BlockRule -FilePath $file.FullName -DisplayName $ruleName -Direction $direction) {
                $existingRuleNames[$ruleName] = $true
            }
            else {
                $fileFailed = $true
            }
        }

        if (-not $fileFailed) {
            $successRuleCount++
        } else {
            $errorFileCount++
            Write-Warning "  -> Failed to create one or both rules for: $($file.Name)"
            # Specific errors logged within New-BlockRule
        }
    }

    Write-Progress -Activity "Creating rules for '$($ApplicationName)'" -Completed

    $summaryMsg = "Operation completed for '$ApplicationName'. Successfully created rule pairs for $successRuleCount file(s)."
    Write-Host "`n$summaryMsg" -ForegroundColor $successColor
    Write-Log -Message $summaryMsg -Level "INFO"

    if ($errorFileCount -gt 0) {
        $warnMsg = "Failed to create one or both rules for $errorFileCount file(s). Check warnings/log for details."
        Write-Warning "  $warnMsg"
        Write-Log -Message $warnMsg -Level "WARN"
    }

    if ($filesToSkip.Count -gt 0) {
        Write-Host "`nThe following files were skipped based on exclusion criteria:" -ForegroundColor $infoColor
        $filesToSkip | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor $processColor }
    }
}

# Function to manage (list and remove) firewall rules created by this script
function Show-RuleManager {
    Write-Host "`n--- Manage Firewall Rules ---" -ForegroundColor $titleColor
    Write-Log -Message "Entered rule management function."

    $rulePattern = "$($RuleNamePrefix)*" # Find all rules starting with our prefix
    Write-Host "Searching for firewall rules created by this script (pattern: '$rulePattern')..." -ForegroundColor $infoColor

    $scriptRules = @()
    try {
        $scriptRules = Get-NetFirewallRule -DisplayName $rulePattern -ErrorAction Stop
    }
    catch {
        $errMsg = "Error retrieving firewall rules: $($_.Exception.Message)"
        Write-Warning $errMsg
        Write-Log -Message $errMsg -Level "ERROR"
        return # Exit function if rules can't be retrieved
    }

    if ($scriptRules.Count -eq 0) {
        Write-Host "No firewall rules created by this script were found." -ForegroundColor $infoColor
        Write-Log -Message "No script-created firewall rules found."
        return
    }

    Write-Host "Found $($scriptRules.Count) firewall rule(s) created by this script:" -ForegroundColor $successColor

    # Group rules by Application Name (extracted from DisplayName)
    $groupedRules = $scriptRules | Group-Object {
        if ($_.DisplayName -match "^$([regex]::Escape($RuleNamePrefix))(.*?)\s+-") { $matches[1] } else { "Unknown Application" }
    }

    $appIndex = 1
    $appMap = @{} # Map index to app name
    Write-Host "Applications with blocking rules:" -ForegroundColor $menuColor
    foreach ($group in $groupedRules) {
        Write-Host "  $appIndex. $($group.Name) ($($group.Count) rules)" -ForegroundColor $menuColor
        $appMap[$appIndex] = $group.Name
        $appIndex++
    }

    Write-Host "`nOptions:" -ForegroundColor $menuColor
    Write-Host "  A. Remove ALL rules listed above." -ForegroundColor $menuColor
    Write-Host "  S. Remove rules for a SPECIFIC application (select by number)." -ForegroundColor $menuColor
    Write-Host "  C. Cancel and return to main menu." -ForegroundColor $menuColor

    $choice = Read-Host -Prompt "Enter your choice (A, S, or C)"

    switch ($choice.ToUpper()) {
        "A" {
            Write-Host "`nRemoving ALL $($scriptRules.Count) rules created by this script..." -ForegroundColor $warningColor
            Write-Log -Message "User chose to remove all $($scriptRules.Count) script-created rules."
            try {
                $scriptRules | Remove-NetFirewallRule -ErrorAction Stop
                Write-Host "Successfully removed all rules." -ForegroundColor $successColor
                Write-Log -Message "Successfully removed all script-created rules."
            } catch {
                $errMsg = "Error removing all rules: $($_.Exception.Message)"
                Write-Warning $errMsg
                Write-Log -Message $errMsg -Level "ERROR"
            }
        }
        "S" {
            $appChoice = Read-Host -Prompt "Enter the NUMBER of the application whose rules you want to remove"
            # TryParse instead of an [int] cast: the cast throws on input like "a", which ended the script
            $appNumber = 0
            if ([int]::TryParse($appChoice, [ref]$appNumber) -and $appMap.ContainsKey($appNumber)) {
                $appNameToRemove = $appMap[$appNumber]
                $rulesToRemove = $scriptRules | Where-Object { $_.DisplayName -match "^$([regex]::Escape($RuleNamePrefix))$([regex]::Escape($appNameToRemove))\s+-" }

                if ($rulesToRemove.Count -gt 0) {
                    Write-Host "`nRemoving $($rulesToRemove.Count) rules for application '$appNameToRemove'..." -ForegroundColor $warningColor
                    Write-Log -Message "User chose to remove $($rulesToRemove.Count) rules for application '$appNameToRemove'."
                    try {
                        $rulesToRemove | Remove-NetFirewallRule -ErrorAction Stop
                        Write-Host "Successfully removed rules for '$appNameToRemove'." -ForegroundColor $successColor
                        Write-Log -Message "Successfully removed rules for '$appNameToRemove'."
                    } catch {
                        $errMsg = "Error removing rules for '$appNameToRemove': $($_.Exception.Message)"
                        Write-Warning $errMsg
                        Write-Log -Message $errMsg -Level "ERROR"
                    }
                } else {
                    Write-Warning "No rules found matching the selected application '$appNameToRemove' (this shouldn't happen)."
                    Write-Log -Message "Rule removal logic error: No rules found for selected app '$appNameToRemove'." -Level "ERROR"
                }
            } else {
                Write-Warning "Invalid application number selected."
                Write-Log -Message "User entered invalid application number '$appChoice' for rule removal." -Level "WARN"
            }
        }
        "C" {
            Write-Host "Rule removal cancelled." -ForegroundColor $infoColor
            Write-Log -Message "User cancelled rule management."
        }
        default {
            Write-Warning "Invalid choice."
            Write-Log -Message "User entered invalid choice '$choice' in rule management." -Level "WARN"
        }
    }
}

# --- Main Script Body ---

# Initial log entry
Write-Log -Message "Script started. PID: $PID"

try {
    Clear-Host
    # Display Title and Disclaimer
    Write-Host "===============================================================" -ForegroundColor $titleColor
    Write-Host "  GENERAL PURPOSE APPLICATION INTERNET ACCESS BLOCKER TOOL" -ForegroundColor $titleColor
    Write-Host "===============================================================" -ForegroundColor $titleColor
    Write-Host "(Logs are saved to: $LogFilePath)" -ForegroundColor $processColor
    Write-Host ""
    Write-Host "LEGAL DISCLAIMER:" -ForegroundColor $warningColor
    Write-Host "Use responsibly and legally. Circumventing licenses is illegal." -ForegroundColor $warningColor
    Write-Host "YOU ARE SOLELY RESPONSIBLE FOR YOUR USE OF THIS SCRIPT." -ForegroundColor $warningColor
    Write-Host "---------------------------------------------------------------" -ForegroundColor $infoColor

    # --- Offer to create a System Restore Point ---
    $restorePointCreated = $false
    $askCreateRestorePoint = Read-Host -Prompt "Do you want to ATTEMPT creating a System Restore Point before proceeding? (Recommended: Y/N)"
    if ($askCreateRestorePoint -match '^y') {
        Write-Host "Attempting to create System Restore Point... (this may take a moment)" -ForegroundColor $infoColor
        Write-Log -Message "User requested System Restore Point creation attempt."
        try {
            # Checkpoint-Computer starts the Volume Shadow Copy service itself if needed.
            Checkpoint-Computer -Description "Before AppBlocker script execution $(Get-Date)" -ErrorAction Stop
            Write-Host "System Restore Point created successfully." -ForegroundColor $successColor
            Write-Log -Message "System Restore Point created successfully."
            $restorePointCreated = $true
        } catch {
            $errMsg = "Failed to create System Restore Point. Error: $($_.Exception.Message). Please ensure System Restore is enabled and functional for your system drive (VSS service might be disabled or unable to start)."
            Write-Warning $errMsg
            Write-Log -Message $errMsg -Level "ERROR"
            # Let the user continue even without a restore point
            $continueAnyway = Read-Host -Prompt "Could not create restore point. Continue with the script anyway? (Y/N)"
            if (-not ($continueAnyway -match '^y')) {
                 Write-Log -Message "User chose to exit after failed restore point creation."
                 exit 1
            }
            Write-Log -Message "User chose to continue after failed restore point creation."
        }
    } else {
         Write-Host "Skipping System Restore Point creation." -ForegroundColor $warningColor
         Write-Log -Message "User skipped System Restore Point creation."
    }
    # --- End: System Restore Point ---


    # --- Main Menu Loop ---
    $exitScript = $false
    while (-not $exitScript) {
        Write-Host "`n--- Main Menu ---" -ForegroundColor $titleColor
        Write-Host "1. Block Internet Access for an Application" -ForegroundColor $menuColor
        Write-Host "2. Manage/Remove Existing Firewall Rules" -ForegroundColor $menuColor
        Write-Host "3. Open Windows Firewall with Advanced Security (wf.msc)" -ForegroundColor $menuColor
        Write-Host "4. Exit" -ForegroundColor $menuColor

        $choice = Read-Host -Prompt "Enter your choice (1-4)"
        Write-Log -Message "User selected main menu option: $choice"

        switch ($choice) {
            "1" {
                # --- Get User Input for Blocking ---
                Write-Host "`n--- Block Application ---" -ForegroundColor $titleColor
                Write-Host "Please provide details for the application you want to block:" -ForegroundColor $infoColor

                $inputAppName = ""
                while (-not $inputAppName) {
                    $inputAppName = Read-Host -Prompt " Enter a unique name for this application (e.g., 'My Drawing App')"
                    if (-not $inputAppName) { Write-Warning "Application name cannot be empty." }
                }

                $inputAppPath = ""
                while (-not $inputAppPath -or -not (Test-Path -Path $inputAppPath -PathType Container)) {
                    $inputAppPath = Read-Host -Prompt " Enter the main installation directory path (e.g., C:\Program Files\MyApp)"
                    if (-not $inputAppPath) { Write-Warning "Directory path cannot be empty." }
                    elseif (-not (Test-Path -Path $inputAppPath -PathType Container)) { Write-Warning "Path '$inputAppPath' not found or is not a directory." }
                }

                $inputExcludedKeywords = @()
                $inputExcludedFiles = @()
                $useExclusions = Read-Host -Prompt " Specify files or keywords to exclude from blocking? (Y/N)"
                if ($useExclusions -match '^y') {
                    $keywordsInput = Read-Host -Prompt "  Keywords to exclude (part of filename, comma-separated)"
                    if ($keywordsInput.Trim()) { $inputExcludedKeywords = $keywordsInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
                    $filesInput = Read-Host -Prompt "  Exact filenames to exclude (comma-separated)"
                    if ($filesInput.Trim()) { $inputExcludedFiles = $filesInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
                     if ($inputExcludedKeywords.Count -gt 0 -or $inputExcludedFiles.Count -gt 0) { Write-Host " Exclusion rules applied." -ForegroundColor $infoColor }
                     Write-Log -Message "Exclusions for '$inputAppName': Keywords='$($inputExcludedKeywords -join ',')', Files='$($inputExcludedFiles -join ',')'"
                } else {
                    Write-Log -Message "No exclusions specified for '$inputAppName'."
                }

                # --- Execute Blocking Process ---
                Remove-ExistingRule -ApplicationName $inputAppName
                Block-Application -ApplicationPath $inputAppPath -ApplicationName $inputAppName -ExcludedKeywords $inputExcludedKeywords -ExcludedFiles $inputExcludedFiles
            }
            "2" {
                Show-RuleManager
            }
            "3" {
                Write-Host "Opening Windows Firewall with Advanced Security (wf.msc)..." -ForegroundColor $infoColor
                Write-Log -Message "Attempting to open wf.msc."
                try {
                    Start-Process "wf.msc" -ErrorAction Stop
                } catch {
                    $errMsg = "Failed to open wf.msc. Ensure the tool is available on your system. Error: $($_.Exception.Message)"
                    Write-Warning $errMsg
                    Write-Log -Message $errMsg -Level "ERROR"
                }
            }
            "4" {
                $exitScript = $true
                Write-Log -Message "User chose to exit."
            }
            default {
                Write-Warning "Invalid selection. Please try again."
                Write-Log -Message "User entered invalid main menu choice: $choice" -Level "WARN"
            }
        } # End Switch

        if (-not $exitScript) {
             Write-Host "`nPress Enter to return to the main menu..." -ForegroundColor $promptColor
             Read-Host | Out-Null
             Clear-Host # Clear screen for the next menu display
        }

    } # End While Loop

    Write-Host "`nScript finished." -ForegroundColor $successColor

}
catch {
    # Catch unexpected script-level errors
    $finalErrorMsg = "AN UNEXPECTED SCRIPT-LEVEL ERROR OCCURRED: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
    Write-Host "`n$finalErrorMsg" -ForegroundColor $errorColor
    Write-Error $_ # Display the full error record for debugging
    Write-Log -Message $finalErrorMsg -Level "ERROR"
    Write-Log -Message "Script terminated due to error."
}
finally {
    # Pause before exiting
    Write-Log -Message "Script execution ended."
    Write-Host "`nPress Enter to exit..." -ForegroundColor $infoColor
    Read-Host | Out-Null
}