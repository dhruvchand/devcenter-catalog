param(
    [Parameter()]
    [string]$repoName,
    [Parameter()]
    [string]$branch,
    [Parameter()]
    [string]$basePath
)
 
$path = "$($env:USERPROFILE)\Repos"
$localPath = "$($path)\$($repoName)"
$remotePath = "$($basePath)/$($repoName)"
 
Write-host "Pinning Repos to Quick Access"
$o = new-object -com shell.application
$o.Namespace($path).Self.InvokeVerb("pintohome")
 
# Start a New Repos Folder
If (!(test-path -PathType container $path)) {
    Write-host "Creating Repo Directory"
    New-Item -ItemType Directory -Path $path
}
else {
    Write-host "Archiving existing C:\Repo directory and starting fresh"
    Rename-Item -Path $path -NewName "$path-$(((get-date).ToUniversalTime()).ToString("yyyyMMddTHHmmssZ"))"
    New-Item -ItemType Directory -Path $path
}
 
# Initialize the repos
Set-Location $path
git clone $remotePath -b $branch
 
do {
    if (-not (Test-Path $localPath)) {
        Write-Host "waiting on $localPath...."
        Start-Sleep -s 3
    }
} until (Test-Path $localPath)
 
Set-Location $localPath
git submodule update --init --recursive
git submodule update --remote
$packageDirectoryLocations = Get-ChildItem -Path $localPath -Filter package.json -Recurse | ForEach-Object { $_.Directory }
 
foreach ($packageDirectory in $packageDirectoryLocations) {
    Set-Location $packageDirectory
    npm install
}
 
if ($env:TERM_PROGRAM -ne 'vscode') {
    $localPath
    code .
}
