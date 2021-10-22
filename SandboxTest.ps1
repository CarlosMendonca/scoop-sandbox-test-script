# Script to test a scoop.sh manifest inside Windows Sandbox. Adapted from the original created for WinGet.

# Parse arguments

Param(
  [Parameter(Position = 0, HelpMessage = "The Manifest to install in the Sandbox.")]
  [String] $Manifest,
  [Parameter(Position = 1, HelpMessage = "The script to run in the Sandbox.")]
  [ScriptBlock] $Script,
  [Parameter(HelpMessage = "The folder to map in the Sandbox.")]
  [String] $MapFolder = $pwd,
  [switch] $SkipManifestValidation
)

$ErrorActionPreference = "Stop"

$mapFolder = (Resolve-Path -Path $MapFolder).Path

if (-Not (Test-Path -Path $mapFolder -PathType Container)) {
  Write-Error -Category InvalidArgument -Message 'The provided MapFolder is not a folder.'
}

# Validate manifest file

if (-Not $SkipManifestValidation -And -Not [String]::IsNullOrWhiteSpace($Manifest)) {
  Write-Host '--> Validating Manifest'

  if (-Not (Test-Path -Path $Manifest)) {
    throw [System.IO.DirectoryNotFoundException]::new('The Manifest does not exist.')
  }

  # AFAIK, scoop.sh dooesn't have an equivalent validation command, so I'm commenting out this section
  # winget.exe validate $Manifest
  # switch ($LASTEXITCODE) {
  #   '-1978335191' { throw [System.Activities.ValidationException]::new('Manifest validation failed.')}
  #   '-1978335192' { Start-Sleep -Seconds 5 }
  #   Default { continue }
  # }

  Write-Host
}

# Check if Windows Sandbox is enabled

if (-Not (Get-Command 'WindowsSandbox' -ErrorAction SilentlyContinue)) {
  Write-Error -Category NotInstalled -Message @'
Windows Sandbox does not seem to be available. Check the following URL for prerequisites and further details:
https://docs.microsoft.com/windows/security/threat-protection/windows-sandbox/windows-sandbox-overview

You can run the following command in an elevated PowerShell for enabling Windows Sandbox:
$ Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM'
'@
}

# Close Windows Sandbox, if it's already open

$sandbox = Get-Process 'WindowsSandboxClient' -ErrorAction SilentlyContinue
if ($sandbox) {
  Write-Host '--> Closing Windows Sandbox'

  $sandbox | Stop-Process
  Start-Sleep -Seconds 5

  Write-Host
}
Remove-Variable sandbox

# Initialize Temp folder, but clean up first

$tempFolderName = 'SandboxTest'
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath $tempFolderName

Remove-Item -Recurse -Force -ErrorAction Ignore $tempFolder
New-Item $tempFolder -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

# Copy Manifest to Temp directory

if (-Not [String]::IsNullOrWhiteSpace($Manifest)) {
  Copy-Item -Path $Manifest -Recurse -Destination $tempFolder
}

$desktopInSandbox = 'C:\Users\WDAGUtilityAccount\Desktop'

Write-Host

# Create Bootstrap script

# See: https://stackoverflow.com/a/22670892/12156188
$bootstrapPs1Content = @"
Write-Host @'
--> Installing scoop.sh
'@
iwr -useb get.scoop.sh | iex

"@

if (-Not [String]::IsNullOrWhiteSpace($Manifest)) {
  $manifestFileName = Split-Path $Manifest -Leaf
  $manifestPathInSandbox = Join-Path -Path $desktopInSandbox -ChildPath (Join-Path -Path $tempFolderName -ChildPath $manifestFileName)
  Write-Host "DEBUG: $manifestPathInSandbox"
  $bootstrapPs1Content += @"

Write-Host @'`n
--> Installing the Manifest $manifestFileName
'@
scoop install $manifestPathInSandbox

"@
}

if (-Not [String]::IsNullOrWhiteSpace($Script)) {
  $bootstrapPs1Content += @"
Write-Host @'

--> Running the following script:

{
$Script
}

'@

$Script

"@
}

$bootstrapPs1Content += @"
Write-Host
"@

$bootstrapPs1FileName = 'Bootstrap.ps1'
$bootstrapPs1Content | Out-File (Join-Path -Path $tempFolder -ChildPath $bootstrapPs1FileName)

# Create Wsb file

$bootstrapPs1InSandbox = Join-Path -Path $desktopInSandbox -ChildPath (Join-Path -Path $tempFolderName -ChildPath $bootstrapPs1FileName)
$mapFolderInSandbox = Join-Path -Path $desktopInSandbox -ChildPath (Split-Path -Path $mapFolder -Leaf)

$sandboxTestWsbContent = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$tempFolder</HostFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$mapFolder</HostFolder>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
  <Command>PowerShell Start-Process PowerShell -WindowStyle Maximized -WorkingDirectory '$mapFolderInSandbox' -ArgumentList '-ExecutionPolicy Bypass -NoExit -NoLogo -File $bootstrapPs1InSandbox'</Command>
  </LogonCommand>
</Configuration>
"@

$sandboxTestWsbFileName = 'SandboxTest.wsb'
$sandboxTestWsbFile = Join-Path -Path $tempFolder -ChildPath $sandboxTestWsbFileName
$sandboxTestWsbContent | Out-File $sandboxTestWsbFile

Write-Host @"
--> Starting Windows Sandbox, and:
    - Mounting the following directories:
      - $tempFolder as read-only
      - $mapFolder as read-and-write
    - Installing scoop.sh
"@

if (-Not [String]::IsNullOrWhiteSpace($Manifest)) {
  Write-Host @"
    - Installing the Manifest '$manifestFileName'
"@
}

if (-Not [String]::IsNullOrWhiteSpace($Script)) {
  Write-Host @"
    - Running the following script:

{
$Script
}
"@
}

Write-Host

WindowsSandbox $SandboxTestWsbFile