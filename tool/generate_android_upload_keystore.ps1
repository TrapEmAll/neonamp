param(
    [string]$OutputPath = "android/neonamp-upload.jks",
    [string]$Alias = "neonamp-upload",
    [int]$ValidityDays = 10000
)

$ErrorActionPreference = "Stop"

if (Test-Path -LiteralPath $OutputPath) {
    throw "Refusing to overwrite existing keystore: $OutputPath"
}

$keytool = Get-Command keytool -ErrorAction SilentlyContinue
if ($null -eq $keytool) {
    throw "keytool was not found. Install a JDK 17+ and run this script again."
}

$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent | Out-Null
}

$storePassword = Read-Host "Keystore password"
$keyPassword = Read-Host "Upload-key password"
$subject = Read-Host "Certificate owner (for example: NeonAmp Release)"
if ([string]::IsNullOrWhiteSpace($subject)) {
    throw "Certificate owner cannot be empty."
}

& $keytool.Source -genkeypair `
    -v `
    -keystore $OutputPath `
    -storetype JKS `
    -storepass $storePassword `
    -keypass $keyPassword `
    -alias $Alias `
    -keyalg RSA `
    -keysize 4096 `
    -validity $ValidityDays `
    -dname "CN=$subject,OU=Release,O=NeonAmp,L=Unknown,ST=Unknown,C=US" `
    -noprompt

Write-Host "Created $OutputPath. Keep it outside source control and back it up securely."
Write-Host "Use the file contents, passwords, and alias to configure the four GitHub Actions secrets documented in README.md."

