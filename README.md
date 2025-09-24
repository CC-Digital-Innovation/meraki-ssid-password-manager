# Meraki SSID Password Manager

An interactive PowerShell tool for bulk updating Meraki SSID passwords across multiple networks and organizations.

## Overview

This script provides a secure, interactive way to update WiFi passwords for multiple SSIDs across your Meraki wireless networks. It features comprehensive preview modes, audit logging, rate limiting, and error handling to ensure safe and reliable password updates.

## Features

- **Interactive Selection**: Choose organizations, networks, and SSIDs through guided prompts
- **Preview Mode**: See exactly what will be changed before applying updates
- **Bulk Operations**: Update multiple SSIDs across different networks simultaneously
- **Audit Logging**: Comprehensive logging of all operations with timestamps
- **Rate Limiting**: Built-in API rate limiting to respect Meraki API limits (10 calls/sec)
- **Error Handling**: Automatic retry logic for rate-limited requests
- **Secure Configuration**: API keys stored in separate config file (gitignored)
- **Cross-Platform**: Works with PowerShell Core on Windows, macOS, and Linux

## Prerequisites

- PowerShell 5.1+ or PowerShell Core 6+
- Meraki Dashboard API access
- Valid Meraki Dashboard API key with wireless write permissions

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/CC-Digital-Innovation/meraki-ssid-password-manager.git
   cd meraki-ssid-password-manager
   ```

2. Copy the example configuration file:

   **Windows (PowerShell/Command Prompt):**
   ```powershell
   copy config.ini.example config.ini
   ```

   **macOS/Linux:**
   ```bash
   cp config.ini.example config.ini
   ```

3. Edit `config.ini` and add your Meraki Dashboard API key:
   ```ini
   [credentials]
   api_key = your_actual_api_key_here

   # Optional: Skip organization selection
   [settings]
   # organization_id = 123456
   ```

## Usage

### Basic Interactive Mode

Run the script with no parameters for full interactive mode:

```powershell
./Update-MerakiSSIDPasswords.ps1
```

This will guide you through:
1. Organization selection (if not configured)
2. Network selection
3. SSID selection
4. Password entry
5. Preview/Apply choice

### Command Line Parameters

```powershell
# Specify organization ID to skip selection
./Update-MerakiSSIDPasswords.ps1 -OrganizationId "123456"

# Provide password via command line
./Update-MerakiSSIDPasswords.ps1 -NewPassword "NewSecurePassword123!"

# Preview mode only (no changes made)
./Update-MerakiSSIDPasswords.ps1 -PreviewMode

# Custom rate limiting for slower processing
./Update-MerakiSSIDPasswords.ps1 -ApiDelayMs 200 -UpdateDelayMs 500 -MaxRetries 5

# Custom audit log location
./Update-MerakiSSIDPasswords.ps1 -AuditLogPath "C:\Logs\meraki_update.log"
```

### Preview Options

The script offers two preview modes:

1. **Interactive Preview**: During normal execution, choose "(P)review changes" to see what will be updated before applying
2. **Full Preview Mode**: Use `-PreviewMode` parameter for complete dry-run without any modifications

## Configuration

### config.ini Structure

```ini
[credentials]
api_key = your_meraki_dashboard_api_key

[settings]
# Optional: Skip organization selection by specifying default org ID
# organization_id = 123456
```

### Rate Limiting Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ApiDelayMs` | 100ms | Delay between all API calls |
| `UpdateDelayMs` | 200ms | Additional delay between SSID updates |
| `NetworkDelayMs` | 150ms | Additional delay between network queries |
| `MaxRetries` | 3 | Maximum retries for rate-limited requests |

## Security Features

- **Secure Password Input**: Passwords entered as SecureString objects
- **Memory Protection**: Plaintext passwords cleared from memory immediately after use
- **Configuration Security**: API keys stored in gitignored config file
- **Audit Trail**: Complete audit logging of all operations
- **Preview Before Apply**: Multiple opportunities to review changes before execution

## Audit Logging

The script creates timestamped audit logs in the format `audit_log_YYYYMMDD_HHMMSS.txt` containing:

- Script execution start/end times
- Rate limiting configuration
- API rate limit encounters and retry attempts
- SSID selection and update operations
- Success/failure status for each operation
- User decisions (preview, apply, cancel)

## Error Handling

- **Rate Limiting**: Automatic exponential backoff for 429 responses
- **API Errors**: Detailed error logging with status codes and responses
- **Network Issues**: Retry logic for transient network problems
- **Input Validation**: Password length and format validation
- **Configuration Errors**: Clear messages for missing or invalid config

## Examples

### Interactive Session Flow

```
=== Meraki SSID Password Update Tool ===

Fetching organizations...
Select an organization:
[1] Acme Corp (123456)
[2] Beta Industries (789012)
Enter selection (1-2): 1

Fetching networks for Acme Corp...
Select networks (comma-separated, 'all', or 'none'):
[1] Main Office (Network1)
[2] Branch Office (Network2)
[3] Guest Network (Network3)
Enter selection: 1,2

Found SSIDs across selected networks:
[1] ☑ Corp-WiFi (Main Office)
[2] ☐ Guest-WiFi (Main Office)
[3] ☑ Corp-WiFi (Branch Office)
Enter selection: 1,3

Selected 2 SSID(s) for password update
Enter new password (minimum 8 characters): [SecureString input]

You are about to update passwords for 2 SSID(s):
- Main Office: Corp-WiFi
- Branch Office: Corp-WiFi

Choose an option: (P)review changes, (A)pply immediately, (C)ancel: p

=== PREVIEW MODE ===
The following SSIDs would have their passwords updated:
✓ Main Office - Corp-WiFi
✓ Branch Office - Corp-WiFi

Apply these changes now? (y/N): y

Updating SSID passwords...
✓ SUCCESS: Updated password for Main Office - Corp-WiFi
✓ SUCCESS: Updated password for Branch Office - Corp-WiFi

Password update completed:
- Successful updates: 2
- Failed updates: 0
```

## Troubleshooting

### Common Issues

1. **"API key not found"**
   - Ensure `config.ini` exists with valid API key
   - Check file permissions on config.ini

2. **"Rate limit exceeded"**
   - Script automatically handles this with retries
   - Increase delay parameters if persistent issues occur

3. **"Network not found"**
   - Verify organization has wireless networks
   - Check API key has appropriate permissions

4. **PowerShell execution policy errors**
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

### Debug Mode

For additional troubleshooting, check the audit logs generated in the script directory. They contain detailed information about API calls, rate limiting, and any errors encountered.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Author

Richard Travellin - [richard.travellin@computacenter.com]

## Acknowledgments

- Cisco Meraki for providing comprehensive Dashboard API documentation
- PowerShell community for secure string handling best practices