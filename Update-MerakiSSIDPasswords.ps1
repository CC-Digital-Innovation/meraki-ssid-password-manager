#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Interactive PowerShell script to update Meraki SSID passwords across multiple networks.

.DESCRIPTION
    This script connects to the Meraki Dashboard API, allows you to select SSIDs across
    different networks, and programmatically applies password changes to all selected SSIDs.

    Features interactive preview mode - you can preview changes before applying them,
    or run in full preview mode to see what would be changed without making any modifications.

    REQUIRES: config.ini file in script directory with your Meraki Dashboard API key.

    The config.ini file can optionally include an organization_id to skip organization selection.

.PARAMETER OrganizationId
    Specific organization ID to use. If provided, skips organization selection.
    Can also be set in config.ini under [settings] section.

.PARAMETER NewPassword
    New password to apply to selected SSIDs. If not provided, will prompt for input.

.PARAMETER AuditLogPath
    Path for audit log file. If not provided, creates timestamped log in script directory.

.PARAMETER ApiDelayMs
    Delay in milliseconds between API calls for rate limiting. Default: 100ms.

.PARAMETER UpdateDelayMs
    Additional delay in milliseconds between SSID updates. Default: 200ms.

.PARAMETER NetworkDelayMs
    Additional delay in milliseconds between network SSID fetches. Default: 150ms.

.PARAMETER MaxRetries
    Maximum number of retries for rate-limited API calls. Default: 3.

.PARAMETER PreviewMode
    When specified, shows what changes would be made without actually executing them.
    Alternatively, you can use the interactive preview option when prompted during normal execution.

.EXAMPLE
    # Create config.ini with:
    # [credentials]
    # api_key = your_api_key_here
    # [settings]
    # organization_id = 123456  # Optional: auto-select this organization
    ./Update-MerakiSSIDPasswords.ps1

    # The script will guide you through selecting organizations, networks, and SSIDs.
    # When ready to apply changes, you'll be prompted with:
    # Choose an option: (P)review changes, (A)pply immediately, (C)ancel

.EXAMPLE
    ./Update-MerakiSSIDPasswords.ps1 -NewPassword "NewSecurePassword123!"

.EXAMPLE
    ./Update-MerakiSSIDPasswords.ps1 -OrganizationId "123456" -NewPassword "NewPassword123!"

.EXAMPLE
    # Custom rate limiting for slower processing
    ./Update-MerakiSSIDPasswords.ps1 -ApiDelayMs 200 -UpdateDelayMs 500 -MaxRetries 5

.EXAMPLE
    # Preview changes without executing them
    ./Update-MerakiSSIDPasswords.ps1 -PreviewMode

.EXAMPLE
    # Preview with specific password (dry-run mode)
    ./Update-MerakiSSIDPasswords.ps1 -PreviewMode -NewPassword "NewPassword123!"

.NOTES
    PREVIEW OPTIONS:
    - Interactive Preview: During normal execution, choose (P)review to see changes before applying
    - Full Preview Mode: Use -PreviewMode parameter for complete dry-run without any modifications
    - Both options show detailed information about what SSIDs would be updated
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$OrganizationId,

    [Parameter(Mandatory=$false)]
    [SecureString]$NewPassword,

    [Parameter(Mandatory=$false)]
    [string]$AuditLogPath,

    [Parameter(Mandatory=$false)]
    [int]$ApiDelayMs = 100,

    [Parameter(Mandatory=$false)]
    [int]$UpdateDelayMs = 200,

    [Parameter(Mandatory=$false)]
    [int]$NetworkDelayMs = 150,

    [Parameter(Mandatory=$false)]
    [int]$MaxRetries = 3,

    [Parameter(Mandatory=$false)]
    [switch]$PreviewMode
)

# Configuration constants
$script:BaseUrl = "https://api.meraki.com/api/v1"

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Invoke-MerakiAPI {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [hashtable]$Body = $null,
        [string]$ApiKey,
        [int]$MaxRetries = 3,
        [int]$BaseDelayMs = 100
    )

    $Uri = "$script:BaseUrl$Endpoint"
    $Headers = @{
        "X-Cisco-Meraki-API-Key" = $ApiKey
        "Content-Type" = "application/json"
    }

    # Rate limiting: Wait between API calls to respect 10 calls/sec limit
    Start-Sleep -Milliseconds $script:ApiDelayMs

    $retryCount = 0
    do {
        try {
            $params = @{
                Uri = $Uri
                Method = $Method
                Headers = $Headers
            }

            if ($Body -and $Method -ne "GET") {
                $params.Body = ($Body | ConvertTo-Json -Depth 10)
            }

            $response = Invoke-RestMethod @params
            return $response
        }
        catch {
            $statusCode = $null
            $retryAfter = $null

            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode

                # Check for Retry-After header in rate limit responses
                if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers["Retry-After"]) {
                    $retryAfter = [int]$_.Exception.Response.Headers["Retry-After"].ToString()
                }
            }

            # Handle rate limiting (429) with retry logic
            if ($statusCode -eq 429 -and $retryCount -lt $MaxRetries) {
                $retryCount++
                $waitTime = if ($retryAfter) { $retryAfter } else { [Math]::Pow(2, $retryCount) }

                Write-RateLimitLog -Endpoint $Endpoint -RetryCount $retryCount -WaitTime $waitTime -AuditLogPath $script:CurrentAuditLogPath
                Start-Sleep -Seconds $waitTime
                continue
            }

            # Log the error details
            Write-ColorOutput "Error calling API endpoint $Endpoint`: $($_.Exception.Message)" "Red"
            if ($_.Exception.Response) {
                Write-ColorOutput "Status Code: $($_.Exception.Response.StatusCode)" "Red"
                if ($_.ErrorDetails.Message) {
                    Write-ColorOutput "Response: $($_.ErrorDetails.Message)" "Red"
                }
            }

            # If we've exhausted retries or it's not a rate limit error, throw
            throw
        }
    } while ($retryCount -le $MaxRetries)
}

function Get-Organizations {
    param([string]$ApiKey)

    Write-ColorOutput "Fetching organizations..." "Yellow"
    return Invoke-MerakiAPI -Endpoint "/organizations" -ApiKey $ApiKey -MaxRetries $script:MaxRetries
}

function Get-OrganizationNetworks {
    param(
        [string]$OrganizationId,
        [string]$ApiKey
    )

    Write-ColorOutput "Fetching networks for organization $OrganizationId..." "Yellow"
    return Invoke-MerakiAPI -Endpoint "/organizations/$OrganizationId/networks" -ApiKey $ApiKey -MaxRetries $script:MaxRetries
}

function Get-NetworkSSIDs {
    param(
        [string]$NetworkId,
        [string]$ApiKey
    )

    return Invoke-MerakiAPI -Endpoint "/networks/$NetworkId/wireless/ssids" -ApiKey $ApiKey -MaxRetries $script:MaxRetries
}

function Update-NetworkSSID {
    param(
        [string]$NetworkId,
        [int]$SSIDNumber,
        [SecureString]$Password
    )

    # Convert SecureString to plain text only for API call
    $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))

    try {
        $body = @{
            psk = $PlainPassword
        }

        return Invoke-MerakiAPI -Endpoint "/networks/$NetworkId/wireless/ssids/$SSIDNumber" -Method "PUT" -Body $body -ApiKey $script:CurrentApiKey -MaxRetries $script:MaxRetries
    }
    finally {
        # Clear the plain text password from memory
        $PlainPassword = $null
        [System.GC]::Collect()
    }
}

function Select-Organization {
    param(
        [string]$SpecificOrgId,
        [string]$ApiKey
    )

    if ($SpecificOrgId) {
        $organizations = Get-Organizations -ApiKey $ApiKey
        $selectedOrg = $organizations | Where-Object { $_.id -eq $SpecificOrgId }

        if (-not $selectedOrg) {
            throw "Organization with ID '$SpecificOrgId' not found or not accessible with this API key"
        }

        Write-ColorOutput "Using specified organization: $($selectedOrg.name)" "Green"
        return $selectedOrg
    }

    $organizations = Get-Organizations -ApiKey $ApiKey

    if ($organizations.Count -eq 0) {
        throw "No organizations found for this API key"
    }

    if ($organizations.Count -eq 1) {
        Write-ColorOutput "Using organization: $($organizations[0].name)" "Green"
        return $organizations[0]
    }

    Write-ColorOutput "`nAvailable Organizations:" "Cyan"
    for ($i = 0; $i -lt $organizations.Count; $i++) {
        Write-Host "[$($i + 1)] $($organizations[$i].name) (ID: $($organizations[$i].id))"
    }

    do {
        $selection = Read-Host "`nSelect organization (1-$($organizations.Count))"
        if (-not (Validate-Selection -UserInput $selection -MaxValue $organizations.Count -AllowAll $false)) {
            Write-ColorOutput "Invalid selection. Please enter a number between 1 and $($organizations.Count)" "Red"
            continue
        }
        $index = [int]$selection - 1
    } while ($index -lt 0 -or $index -ge $organizations.Count)

    return $organizations[$index]
}

function Select-Networks {
    param(
        [string]$OrganizationId,
        [string]$ApiKey
    )

    $networks = Get-OrganizationNetworks -OrganizationId $OrganizationId -ApiKey $ApiKey
    $wirelessNetworks = $networks | Where-Object { $_.productTypes -contains "wireless" }

    if ($wirelessNetworks.Count -eq 0) {
        throw "No wireless networks found in this organization"
    }

    Write-ColorOutput "`nAvailable Wireless Networks:" "Cyan"
    for ($i = 0; $i -lt $wirelessNetworks.Count; $i++) {
        Write-Host "[$($i + 1)] $($wirelessNetworks[$i].name)"
    }
    Write-Host "[A] Select All"

    do {
        $selection = Read-Host "`nSelect networks (comma-separated numbers, or 'A' for all)"
        if (Validate-Selection -UserInput $selection -MaxValue $wirelessNetworks.Count) {
            break
        }
        Write-ColorOutput "Invalid selection. Please enter valid numbers between 1 and $($wirelessNetworks.Count), or 'A' for all" "Red"
    } while ($true)

    if ($selection.ToUpper() -eq "A") {
        return $wirelessNetworks
    }

    $selectedNetworks = @()
    $indices = $selection.Split(",") | ForEach-Object { $_.Trim() }

    foreach ($index in $indices) {
        $arrayIndex = [int]$index - 1
        if ($arrayIndex -ge 0 -and $arrayIndex -lt $wirelessNetworks.Count) {
            $selectedNetworks += $wirelessNetworks[$arrayIndex]
        }
    }

    return $selectedNetworks
}

function Get-AllSSIDs {
    param(
        [array]$Networks,
        [string]$AuditLogPath,
        [string]$ApiKey
    )

    $allSSIDs = @()
    $skippedNetworks = @()

    $networkIndex = 0
    foreach ($network in $Networks) {
        $networkIndex++
        Write-ColorOutput "[$networkIndex/$($Networks.Count)] Fetching SSIDs for network: $($network.name)" "Yellow"

        try {
            $ssids = Get-NetworkSSIDs -NetworkId $network.id -ApiKey $ApiKey

            foreach ($ssid in $ssids) {
                if ($ssid.authMode -like "*psk*" -and $ssid.enabled) {
                    $ssidInfo = [PSCustomObject]@{
                        NetworkId = $network.id
                        NetworkName = $network.name
                        SSIDNumber = $ssid.number
                        SSIDName = $ssid.name
                        AuthMode = $ssid.authMode
                        Enabled = $ssid.enabled
                    }
                    $allSSIDs += $ssidInfo
                }
            }
        }
        catch {
            $errorMsg = "Warning: Could not fetch SSIDs for network $($network.name): $($_.Exception.Message)"
            Write-ColorOutput $errorMsg "Yellow"
            Write-AuditLog $errorMsg $AuditLogPath
            $skippedNetworks += $network.name
        }

        # Add throttling delay between network SSID fetches (additional to the base delay in Invoke-MerakiAPI)
        if ($networkIndex -lt $Networks.Count) {
            Start-Sleep -Milliseconds $script:NetworkDelayMs
        }
    }

    if ($skippedNetworks.Count -gt 0) {
        Write-ColorOutput "`nNetworks skipped due to errors: $($skippedNetworks -join ', ')" "Yellow"
        Write-AuditLog "Networks skipped: $($skippedNetworks -join ', ')" $AuditLogPath
    }

    return $allSSIDs
}

function Select-SSIDs {
    param([array]$SSIDs)

    if ($SSIDs.Count -eq 0) {
        throw "No PSK-enabled SSIDs found in selected networks"
    }

    Write-ColorOutput "`nAvailable PSK-enabled SSIDs:" "Cyan"
    for ($i = 0; $i -lt $SSIDs.Count; $i++) {
        Write-Host "[$($i + 1)] $($SSIDs[$i].NetworkName) - $($SSIDs[$i].SSIDName) ($($SSIDs[$i].AuthMode))"
    }
    Write-Host "[A] Select All"

    do {
        $selection = Read-Host "`nSelect SSIDs to update (comma-separated numbers, or 'A' for all)"
        if (Validate-Selection -UserInput $selection -MaxValue $SSIDs.Count) {
            break
        }
        Write-ColorOutput "Invalid selection. Please enter valid numbers between 1 and $($SSIDs.Count), or 'A' for all" "Red"
    } while ($true)

    if ($selection.ToUpper() -eq "A") {
        return $SSIDs
    }

    $selectedSSIDs = @()
    $indices = $selection.Split(",") | ForEach-Object { $_.Trim() }

    foreach ($index in $indices) {
        $arrayIndex = [int]$index - 1
        if ($arrayIndex -ge 0 -and $arrayIndex -lt $SSIDs.Count) {
            $selectedSSIDs += $SSIDs[$arrayIndex]
        }
    }

    return $selectedSSIDs
}

function Update-SelectedSSIDs {
    param(
        [array]$SSIDs,
        [SecureString]$Password,
        [string]$AuditLogPath,
        [bool]$PreviewMode = $false
    )

    $successCount = 0
    $failureCount = 0
    $successfulSSIDs = @()
    $failedSSIDs = @()

    if ($PreviewMode) {
        Write-ColorOutput "`n=== PREVIEW MODE - No changes will be made ===" "Magenta"
        Write-ColorOutput "The following SSIDs would have their passwords updated:" "Yellow"
        Write-AuditLog "PREVIEW MODE: Starting password update preview for $($SSIDs.Count) SSIDs" $AuditLogPath
    } else {
        Write-ColorOutput "`nUpdating SSID passwords..." "Yellow"
        Write-AuditLog "Starting password update for $($SSIDs.Count) SSIDs" $AuditLogPath
    }

    $currentIndex = 0
    foreach ($ssid in $SSIDs) {
        $currentIndex++

        if ($PreviewMode) {
            Write-Host "[$currentIndex/$($SSIDs.Count)] Would update: $($ssid.NetworkName) - $($ssid.SSIDName) (SSID #$($ssid.SSIDNumber))" -ForegroundColor Cyan
            Write-Host "    Network ID: $($ssid.NetworkId)" -ForegroundColor Gray
            Write-Host "    Auth Mode: $($ssid.AuthMode)" -ForegroundColor Gray
            $successCount++
            $successfulSSIDs += "$($ssid.NetworkName) - $($ssid.SSIDName)"
            Write-AuditLog "PREVIEW: Would update password for $($ssid.NetworkName) - $($ssid.SSIDName)" $AuditLogPath
        } else {
            Write-Host "[$currentIndex/$($SSIDs.Count)] Updating $($ssid.NetworkName) - $($ssid.SSIDName)... " -NoNewline

            try {
                Update-NetworkSSID -NetworkId $ssid.NetworkId -SSIDNumber $ssid.SSIDNumber -Password $Password
                Write-ColorOutput "SUCCESS" "Green"
                $successCount++
                $successfulSSIDs += "$($ssid.NetworkName) - $($ssid.SSIDName)"
                Write-AuditLog "SUCCESS: Updated password for $($ssid.NetworkName) - $($ssid.SSIDName)" $AuditLogPath
            }
            catch {
                $errorMsg = "FAILED - $($_.Exception.Message)"
                Write-ColorOutput $errorMsg "Red"
                $failureCount++
                $failedSSIDs += "$($ssid.NetworkName) - $($ssid.SSIDName): $($_.Exception.Message)"
                Write-AuditLog "FAILED: $($ssid.NetworkName) - $($ssid.SSIDName) - $($_.Exception.Message)" $AuditLogPath
            }

            # Add throttling delay between SSID updates (additional to the base delay in Invoke-MerakiAPI)
            if ($currentIndex -lt $SSIDs.Count) {
                Start-Sleep -Milliseconds $script:UpdateDelayMs
            }
        }
    }

    if ($PreviewMode) {
        Write-ColorOutput "`n=== PREVIEW SUMMARY ===" "Magenta"
        Write-ColorOutput "  SSIDs that would be updated: $successCount" "Cyan"
        Write-ColorOutput "`nTo execute these changes, run the script again without -PreviewMode" "Yellow"
        Write-AuditLog "PREVIEW: $successCount SSIDs would be updated" $AuditLogPath
    } else {
        Write-ColorOutput "`nPassword update completed:" "Cyan"
        Write-ColorOutput "  Successful: $successCount" "Green"
        Write-ColorOutput "  Failed: $failureCount" "Red"

        if ($failedSSIDs.Count -gt 0) {
            Write-ColorOutput "`nFailed SSIDs:" "Red"
            foreach ($failed in $failedSSIDs) {
                Write-ColorOutput "  - $failed" "Red"
            }
        }

        Write-AuditLog "Password update completed: $successCount successful, $failureCount failed" $AuditLogPath
    }
}

# Main script execution
function Read-ConfigFile {
    param([string]$ConfigPath)

    $config = @{
        ApiKey = $null
        OrganizationId = $null
    }

    if (-not (Test-Path $ConfigPath)) {
        return $config
    }

    try {
        $content = Get-Content $ConfigPath -Raw
        $lines = $content -split "`n"
        $currentSection = ""

        foreach ($line in $lines) {
            $line = $line.Trim()

            # Check for section headers
            if ($line -match '^\[(.+)\]$') {
                $currentSection = $matches[1]
                continue
            }

            # Skip empty lines and comments
            if (-not $line -or $line.StartsWith("#") -or $line.StartsWith(";")) {
                continue
            }

            # Parse key-value pairs
            if ($line -match '^(.+?)\s*=\s*(.+)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()

                if ($currentSection -eq "credentials" -and $key -eq "api_key") {
                    $config.ApiKey = $value
                }
                elseif ($currentSection -eq "settings" -and $key -eq "organization_id") {
                    $config.OrganizationId = $value
                }
            }
        }

        return $config
    }
    catch {
        Write-ColorOutput "Warning: Error reading config file: $($_.Exception.Message)" "Yellow"
        return $config
    }
}

function Write-AuditLog {
    param(
        [string]$Message,
        [string]$LogPath
    )

    if ($LogPath) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
    }
}

function Write-RateLimitLog {
    param(
        [string]$Endpoint,
        [int]$RetryCount,
        [int]$WaitTime,
        [string]$AuditLogPath
    )

    $message = "RATE LIMIT: Endpoint $Endpoint hit rate limit. Retry $RetryCount, waiting $WaitTime seconds"
    Write-ColorOutput $message "Yellow"
    Write-AuditLog $message $AuditLogPath
}

function Validate-Selection {
    param(
        [string]$UserInput,
        [int]$MaxValue,
        [bool]$AllowAll = $true
    )

    if ($AllowAll -and $UserInput.ToUpper() -eq "A") {
        return $true
    }

    $indices = $UserInput.Split(",") | ForEach-Object { $_.Trim() }

    foreach ($index in $indices) {
        # Use a different approach to test if it's a valid integer
        try {
            $numIndex = [int]$index
            if ($numIndex -lt 1 -or $numIndex -gt $MaxValue) {
                return $false
            }
        }
        catch {
            return $false
        }
    }

    return $true
}

function Main {
    if ($PreviewMode) {
        Write-ColorOutput "=== Meraki SSID Password Update Tool (PREVIEW MODE) ===" "Magenta"
        Write-ColorOutput "*** NO CHANGES WILL BE MADE - PREVIEW ONLY ***" "Yellow"
    } else {
        Write-ColorOutput "=== Meraki SSID Password Update Tool ===" "Cyan"
    }

    # Initialize script-level configuration variables
    $script:ApiDelayMs = $ApiDelayMs
    $script:UpdateDelayMs = $UpdateDelayMs
    $script:NetworkDelayMs = $NetworkDelayMs
    $script:MaxRetries = $MaxRetries

    # Get config settings from config file
    $configPath = Join-Path $PSScriptRoot "config.ini"
    $config = Read-ConfigFile -ConfigPath $configPath
    $ApiKey = $config.ApiKey

    # If OrganizationId parameter wasn't provided, use the one from config
    if (-not $OrganizationId -and $config.OrganizationId) {
        $OrganizationId = $config.OrganizationId
        Write-ColorOutput "Using organization ID from config.ini: $OrganizationId" "Cyan"
    }

    if (-not $ApiKey) {
        Write-ColorOutput "ERROR: API key not found in config.ini" "Red"
        Write-ColorOutput "Please create a config.ini file in the script directory with:" "Yellow"
        Write-ColorOutput "[credentials]" "Yellow"
        Write-ColorOutput "api_key = your_api_key_here" "Yellow"
        exit 1
    }

    # Initialize audit log path if not provided
    if (-not $AuditLogPath) {
        $AuditLogPath = Join-Path $PSScriptRoot "audit_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    }

    Write-AuditLog "Script started by user: $env:USERNAME$(if ($PreviewMode) { ' (PREVIEW MODE)' })" $AuditLogPath
    Write-AuditLog "Rate limiting configuration: API delay=$($script:ApiDelayMs)ms, Update delay=$($script:UpdateDelayMs)ms, Network delay=$($script:NetworkDelayMs)ms, Max retries=$($script:MaxRetries)" $AuditLogPath

    # Store API key and audit log path for use in nested functions
    $script:CurrentApiKey = $ApiKey
    $script:CurrentAuditLogPath = $AuditLogPath

    try {
        # Step 1: Select Organization
        $organization = Select-Organization -SpecificOrgId $OrganizationId -ApiKey $ApiKey
        Write-ColorOutput "Selected organization: $($organization.name)" "Green"

        # Step 2: Select Networks
        $networks = Select-Networks -OrganizationId $organization.id -ApiKey $ApiKey
        Write-ColorOutput "Selected $($networks.Count) network(s)" "Green"

        # Step 3: Get all SSIDs from selected networks
        $allSSIDs = Get-AllSSIDs -Networks $networks -AuditLogPath $AuditLogPath -ApiKey $ApiKey

        # Step 4: Select SSIDs to update
        $selectedSSIDs = Select-SSIDs -SSIDs $allSSIDs
        Write-ColorOutput "Selected $($selectedSSIDs.Count) SSID(s) for password update" "Green"

        # Step 5: Get new password if not provided
        if (-not $NewPassword) {
            do {
                $NewPassword = Read-Host "Enter new password (minimum 8 characters)" -AsSecureString
                $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPassword))

                if ($PlainPassword.Length -lt 8) {
                    Write-ColorOutput "Password must be at least 8 characters long" "Red"
                }
                else {
                    # Clear the temporary plain text password
                    $PlainPassword = $null
                    [System.GC]::Collect()
                    break
                }
            } while ($true)
        }

        # Step 6: Handle preview mode or confirm before updating
        if ($PreviewMode) {
            Write-ColorOutput "`nPREVIEW MODE: The following $($selectedSSIDs.Count) SSID(s) would be updated:" "Magenta"
            foreach ($ssid in $selectedSSIDs) {
                Write-Host "  - $($ssid.NetworkName) - $($ssid.SSIDName)"
            }
            Write-AuditLog "PREVIEW MODE: User selected $($selectedSSIDs.Count) SSIDs for preview" $AuditLogPath
            Update-SelectedSSIDs -SSIDs $selectedSSIDs -Password $NewPassword -AuditLogPath $AuditLogPath -PreviewMode $true
        } else {
            Write-ColorOutput "`nYou are about to update passwords for $($selectedSSIDs.Count) SSID(s):" "Yellow"
            foreach ($ssid in $selectedSSIDs) {
                Write-Host "  - $($ssid.NetworkName) - $($ssid.SSIDName)"
            }

            # Offer preview option
            $choice = Read-Host "`nChoose an option: (P)review changes, (A)pply immediately, (C)ancel"

            switch ($choice.ToLower()) {
                "p" {
                    Write-ColorOutput "`nShowing preview of changes..." "Cyan"
                    Write-AuditLog "User requested preview before applying changes" $AuditLogPath
                    Update-SelectedSSIDs -SSIDs $selectedSSIDs -Password $NewPassword -AuditLogPath $AuditLogPath -PreviewMode $true

                    $applyConfirm = Read-Host "`nApply these changes now? (y/N)"
                    if ($applyConfirm.ToLower() -eq "y") {
                        Write-AuditLog "User confirmed password update after preview" $AuditLogPath
                        Update-SelectedSSIDs -SSIDs $selectedSSIDs -Password $NewPassword -AuditLogPath $AuditLogPath -PreviewMode $false
                    } else {
                        Write-ColorOutput "Changes not applied" "Yellow"
                        Write-AuditLog "User cancelled after preview" $AuditLogPath
                    }
                }
                "a" {
                    Write-AuditLog "User chose to apply changes immediately" $AuditLogPath
                    Update-SelectedSSIDs -SSIDs $selectedSSIDs -Password $NewPassword -AuditLogPath $AuditLogPath -PreviewMode $false
                }
                default {
                    Write-ColorOutput "Operation cancelled by user" "Yellow"
                    Write-AuditLog "Operation cancelled by user" $AuditLogPath
                }
            }
        }

    }
    catch {
        $errorMsg = "Script execution failed: $($_.Exception.Message)"
        Write-ColorOutput $errorMsg "Red"
        Write-AuditLog $errorMsg $AuditLogPath
        exit 1
    }
    finally {
        Write-AuditLog "Script execution completed" $AuditLogPath
        Write-ColorOutput "`nRate limiting was enabled with the following settings:" "Cyan"
        Write-ColorOutput "  API Delay: $($script:ApiDelayMs)ms between calls" "White"
        Write-ColorOutput "  Update Delay: $($script:UpdateDelayMs)ms between SSID updates" "White"
        Write-ColorOutput "  Network Delay: $($script:NetworkDelayMs)ms between network fetches" "White"
        Write-ColorOutput "  Max Retries: $($script:MaxRetries) for rate limit errors" "White"
    }
}

# Run the main function
Main