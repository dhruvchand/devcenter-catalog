# Copyright (c) Microsoft Corporation.

<#
.SYNOPSIS
    Create Dev Drive "x" drive volume. 
.DESCRIPTION
    Create Dev Drive "x" drive volume. If "x" volume already exists then it will be overwritten.
.PARAMETER DevBoxDevDrive (optional)
    Drive letter. Default value is "E".
.PARAMETER OsDriveMinSizeGB (optional)
    The required minimum size of NTFS C drive in GB when Dev Drive volume is created. 
    Default value is 250.
.PARAMETER EnableGVFS (optional)
    When set, the PrjFlt filesystem minifilter driver is allowed on the Dev Drive. 
    This supports use of GVFS/VFSForGit repo enlistments at the cost of reduced Dev Drive performance.
.PARAMETER EnableContainers
    When set, the wcifs and bindflt filesystem minifilter drivers are allowed on the Dev Drive.
    This supports mounting Windows containers on the Dev Drive at the cost of reduced Dev Drive performance.

.EXAMPLE
        DevBoxDevDrive: 'e'
        OsDriveMinSizeGB: 250
        EnableGVFS: false
        EnableContainers: false
#>

param
(
    [string] $DevBoxDevDrive = "E",
    [int] $OsDriveMinSizeGB = 250,
    [bool] $EnableGVFS = $false,
    [bool] $EnableContainers = $false
)

Set-StrictMode -Version latest
$ErrorActionPreference = "Stop"

function LogWithTimestamp([string] $message) {
    Write-Host "$(Get-Date -Format "[yyyy-MM-dd HH:mm:ss.fff]") $message"
}

function Invoke-Program(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][String] $Program,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][String] $Arguments,
    [Parameter(Mandatory = $false)][bool] $IgnoreExitCode = $false,
    [Parameter(Mandatory = $false)][int] $RetryAttempts = 3
) {
    $attempt = 1
    $progExitCode = 0
    while ($attempt -le $RetryAttempts) {
        LogWithTimestamp "-- Executing command (attempt $attempt): $Program $Arguments"
        # Use Start-Process to reliably capture process exit code and handle input/output redirects in arguments
        $progExitCode = (Start-Process -FilePath $Program -ArgumentList $Arguments -Wait -Passthru -NoNewWindow).ExitCode
        if ($progExitCode -ne 0) {
            $errorMessage = "Command '$Program $Arguments' exited with code $progExitCode"
            if ($IgnoreExitCode -or ($attempt -lt $RetryAttempts)) {
                LogWithTimestamp "[WARN] $errorMessage"
            }
            else {
                LogWithTimestamp "[ERROR] $errorMessage"
                throw $errorMessage
            }
        }
        else {
            break
        }

        $attempt++
        LogWithTimestamp "-- Waiting $attempt seconds before next attempt"
        Start-Sleep -Seconds $attempt
    }

    LogWithTimestamp "-- Completed command: $Program $Arguments"
    return $progExitCode
}

function Set-PackagePath(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][String] $EnvName,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][String] $PackagePath,
    [Parameter(Mandatory = $false)][String] $EnvValue
) {
    Write-Host "Setting environment $EnvName to package path $PackagePath"
    New-Item -ItemType Directory -Force -Path $PackagePath

    if ([string]::IsNullOrEmpty($EnvValue)) {
        $EnvValue = $PackagePath
    }
    setx /M $EnvName "$EnvValue"
}

Write-Host "`nSTART creating dev drive: $(Get-Date -Format u)"
Write-Host "Check that /DevDrv parameter is visible on format command."
format /?
Write-Host "`nStarted with volumes:$(Get-Volume | Out-String)"

$TempDir = $env:TEMP

try
{
    $osVersion = [System.Environment]::OSVersion.Version
    if ((($osVersion.Major -eq 10) -and ($osVersion.Build -lt 22621)) -or ($osVersion.Major -lt 10))
    {
        throw "Dev Drive can only be enabled on Windows 11 22H2 22621 or later."
    }

    $firstReFSVolume = (Get-Volume | Where-Object { $_.FileSystemType -eq "ReFS" } | Select-Object -First 1)
    if ($firstReFSVolume) {
        $fromDriveLetterOrNull = $firstReFSVolume.DriveLetter
        if ($DevBoxDevDrive -eq $fromDriveLetterOrNull) {
            Write-Host "Code drive letter ${DevBoxDevDrive} already matches the first ReFS/Dev Drive volume."
        }
        else {
            Write-Host "Assigning code drive letter to $DevBoxDevDrive"
            $firstReFSVolume | Get-Partition | Set-Partition -NewDriveLetter $DevBoxDevDrive
        }
    
        Write-Host "`nDone with volumes:$(Get-Volume | Out-String)"
    
        # This will mount the drive and open a handle to it which is important to get the drive ready.
        Write-Host "Checking dir contents of ${DevBoxDevDrive}: drive"
        Get-ChildItem ${DevBoxDevDrive}:
    }
    else {
        $cSizeGB = (Get-Volume C).Size / 1024 / 1024 / 1024
        $targetDevDriveSizeGB = $cSizeGB - $OsDriveMinSizeGB
        $diffGB = $cSizeGB - $targetDevDriveSizeGB
        Write-Host "Target DevDrive size $targetDevDriveSizeGB GB, current C: size $cSizeGB GB"

        # Sanity checks
        if ($diffGB -lt 50)
        {
            throw "Dev Drive target size 50 GB would leave less than 50 GB free on drive C: which is not enough for Windows and apps. Drive C: size $cSizeGB GB"
        }
        if ($targetDevDriveSizeGB -lt 20)
        {
            throw "Dev Drive target size 20 GB is below the min size 20 GB. Drive C: size $cSizeGB GB"
        }

        $targetDevDriveSizeMB = ([math]::Round($targetDevDriveSizeGB, 0)) * 1024

        if ((Get-PSDrive).Name -match "^" + $DevBoxDevDrive + "$") {
            $DiskPartDeleteScriptPath = $TempDir + "/CreateDevDriveDelExistingVolume.txt"
            $rmcmd = "SELECT DISK 0 `r`n SELECT VOLUME=$DevBoxDevDrive `r`n DELETE VOLUME OVERRIDE"
            If (!(Test-Path $DiskPartDeleteScriptPath)) {New-Item -Path $DiskPartDeleteScriptPath -Force}
            $rmcmd | Set-Content -Path $DiskPartDeleteScriptPath
            Write-Host "Delete existing $DevBoxDevDrive `r`n $rmcmd"
            diskpart /s $DiskPartDeleteScriptPath
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                Write-Host "Successfully deleted existing $DevBoxDevDrive volume" 
            }
            else {
                Write-Host "[ERROR] Delete volume diskpart command failed with exit code: $exitCode"
                exit 1
            }
        }
        
        # https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/shrink
        $DiskPartScriptPath = $TempDir + "/CreateDevDriveFromExistingVolume.txt"
        $cmd = "SELECT VOLUME C: `r`n SHRINK desired = $targetDevDriveSizeMB minimum = $targetDevDriveSizeMB `r`n CREATE PARTITION PRIMARY `r`n ASSIGN LETTER=$DevBoxDevDrive `r`n"
        If (!(Test-Path $DiskPartScriptPath)) {New-Item -Path $DiskPartScriptPath -Force}
        $cmd | Set-Content -Path $DiskPartScriptPath
        Write-Host "Creating $DevBoxDevDrive ReFS volume: diskpart:`r`n $cmd"
        diskpart /s $DiskPartScriptPath
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Write-Host "Successfully created ReFS $DevBoxDevDrive volume"
        }
        else {
            Write-Host "[ERROR] ReFS volume creation command failed with exit code: $exitCode"
            exit 1
        }

        Format-Volume -DriveLetter $DevBoxDevDrive -FileSystem 'REFS' -DevDrive -Confirm:$false -NewFileSystemLabel 'DevDrive' -Force

        Write-Host "Successfully formatted DevDrive $DevBoxDevDrive volume. Final volume list:"
        Get-Volume | Out-String
    }

    $AllowedFilterList = "MsSecFlt,ProcMon24"
    if ($EnableGVFS) {
        $AllowedFilterList += ",PrjFlt"
    }
    if ($EnableContainers) {
        $AllowedFilterList += ",wcifs,bindFlt"
    }

    Write-Host ""
    Write-Host "Allowing the following filesystem filter drivers to mount to any Dev Drive:"
    Write-Host "  $AllowedFilterList"
    Invoke-Program fsutil "devdrv setFiltersAllowed $AllowedFilterList"
    $DevBoxDriveWithColon = $DevBoxDevDrive + ":"
    Write-Host "Setting DevDrive $DevBoxDriveWithColon as trusted"
    Invoke-Program fsutil "devdrv trust $DevBoxDriveWithColon"

    Invoke-Program fsutil "devdrv query $DevBoxDriveWithColon"
    Write-Host "Dev Drive creation completed."

    # Setting package folders https://learn.microsoft.com/en-us/windows/dev-drive/#storing-package-cache-on-dev-drive
    $RootPackageFolder = "$DevBoxDriveWithColon\packages"
    New-Item -ItemType Directory -Force -Path $RootPackageFolder

    Set-PackagePath "npm_config_cache" "$RootPackageFolder\npm"
    Set-PackagePath "NUGET_PACKAGES" "$RootPackageFolder\.nuget\packages"
    Set-PackagePath "VCPKG_DEFAULT_BINARY_CACHE" "$RootPackageFolder\vcpkg"
    Set-PackagePath "PIP_CACHE_DIR" "$RootPackageFolder\pip"
    Set-PackagePath "CARGO_HOME" "$RootPackageFolder\cargo"
    Set-PackagePath "MAVEN_OPTS" "$RootPackageFolder\maven" "-Dmaven.repo.local=$RootPackageFolder\maven"
    Set-PackagePath "GRADLE_USER_HOME" "$RootPackageFolder\gradle"

    # Reboot to have the change take effect
    Write-Host "Reboot to have the change take effect"
}
catch
{
    Write-Host '!!! [ERROR] Unhandled exception: windows-create-devdrive failed.'
    Write-Host -Object $_
    Write-Host -Object $_.ScriptStackTrace
    exit 1
}
