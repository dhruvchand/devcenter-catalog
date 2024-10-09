param(
    [Parameter(ValueFromPipeline = $true)]
    [string] $configurationPath,
    [Parameter()]
    $inlineConfiguration
)

# Perform download of DSC from GitHub
function Invoke-DSCDownload {
    # Download latest release from GitHub
    $project = 'PowerShell/DSC'
    $arch = 'x86_64-pc-windows-msvc'
    $restParameters = @{
        SslProtocol = 'Tls13'
        Headers     = @{'X-GitHub-Api-Version' = '2022-11-28' }
    }
    # Call GitHub public API to get latest release URL
    $tags = Invoke-RestMethod -Uri "https://api.github.com/repos/$project/tags" @restParameters
    $releaseDownloadUrl = Invoke-RestMethod -Uri "https://api.github.com/repos/$project/releases/tags/$($tags[0].name)" @restParameters | ForEach-Object assets | Where-Object name -Match $arch | ForEach-Object browser_download_url
    Invoke-WebRequest -Uri $releaseDownloadUrl -UseBasicParsing -OutFile "$env:temp\DSC.zip" | Out-Null
    return $(Join-Path $env:temp 'DSC.zip')
}

# Determine the install location based on user context
function Get-InstallLocation {
    param(
        [ValidateSet('system', 'user')]
        [string] $pathType
    )
    $installPath = switch ($pathType) {
        'system' { $env:ProgramData }
        'user' { $env:LOCALAPPDATA }
    }
    if (!(Test-Path "$installPath\Microsoft\" -ErrorAction Ignore)) {
        New-Item -Path "$installPath\Microsoft\" -ItemType Directory
    }
    if (!(Test-Path "$installPath\Microsoft\DSC" -ErrorAction Ignore)) {
        New-Item -Path "$installPath\Microsoft\DSC" -ItemType Directory
    }
    $installLocation = Join-Path (Join-Path $installPath 'Microsoft') 'DSC'
    return $installLocation.ToString()
}

# Download and install DSC from GitHub
function Install-DSC {
    [CmdletBinding()]
    param(
        [ValidateSet('system', 'user')]
        [string] $pathType
    )
    $installLocation = Get-InstallLocation -path $pathType
    $dscDownload = Invoke-DSCDownload
    Expand-Archive -Path $dscDownload -DestinationPath $installLocation.ToString() -Force
    Remove-Item -Path $dscDownload
    Write-Output "DSC installed to $installLocation"
}

# Determine if script is running as a user or as local system
function Get-UserContext {
    $userContext = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ('NT AUTHORITY\SYSTEM' -eq $userContext) {
        $pathType = 'system'
    }
    else {
        $pathType = 'user'
    }
    return $pathType
}

# Test if DSC is installed, given the user context
function Test-DSCInstalled {
    # first test if it is available in PATH, since it could have been installed from the store
    if ($null -ne $(Get-Command 'dsc' -ErrorAction Ignore)) {
        return $true
    }
    else {
        # next try file path
        $pathType = Get-UserContext
        $installLocation = Get-InstallLocation -path $pathType
        if (Test-Path (Join-Path $installLocation 'dsc.exe')) {
            return $true
        }
        else {
            return $false
        }
    }
}

# Return if a string is a uri or a file path
function Get-PathType {
    param(
        [string] $path
    )
    if ([uri]::IsWellFormedUriString($path, [urikind]::Absolute)) {
        return 'uri'
    }
    elseif (Test-Path $path -ErrorAction Ignore) {
        return 'file'
    }
    else {
        throw 'Configuration path provided as input is neither a URI nor a file path that exists on this machine.'
    }
}

# Main

# If DSC is not installed, install it
if (-not (Test-DSCInstalled)) {
    Install-DSC -path (Get-UserContext)
}

# Get path to dsc.exe
$dsc = Get-Command 'dsc' -ErrorAction Ignore | ForEach-Object Source
if ($null -eq $dsc) {
    $dsc = Join-Path (Get-InstallLocation -Path (Get-UserContext)) 'dsc.exe'
}

# Make sure inline content is string
if ('string' -ne $inlineConfiguration.gettype().name) { $inlineConfiguration = $inlineConfiguration | Out-String }

# Run DSC
if (-not [string]::IsNullorEmpty($configurationPath) ) {
    $pathType = Get-PathType -path $configurationPath
    switch ($pathType) {
        'uri' { $configuration = Invoke-WebRequest -Uri $configurationPath -UseBasicParsing | ForEach-Object content }
        'file' { $configuration = Get-Content $configurationPath }
    }
}
elseif (-not [string]::IsNullorEmpty($inlineConfiguration)) {
    $configuration = $inlineConfiguration
}
else {
    throw 'No configuration provided'
}

$configuration | & $dsc config set
