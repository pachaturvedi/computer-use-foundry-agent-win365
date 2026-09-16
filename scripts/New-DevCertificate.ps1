#Requires -Version 7.4
[CmdletBinding()]
param([string]$OutputDirectory = '.local')
$ErrorActionPreference = 'Stop'
$directory = [IO.Path]::GetFullPath($OutputDirectory)
if ((Test-Path "$directory\blueprint.pfx") -or (Test-Path "$directory\blueprint.cer")) {
    throw 'Certificate files already exist. Do not replace an identity credential implicitly.'
}
$password = Read-Host 'New PFX password (store it in user-secrets or a password manager)' -AsSecureString
if ($password.Length -lt 12) { throw 'Use a password of at least 12 characters.' }
[IO.Directory]::CreateDirectory($directory) | Out-Null
$rsa = [Security.Cryptography.RSA]::Create(3072)
try {
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=foundry-w365-local-sample', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(90))
    try {
        [IO.File]::WriteAllBytes("$directory\blueprint.pfx", $certificate.Export(
            [Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password))
        [IO.File]::WriteAllBytes("$directory\blueprint.cer", $certificate.Export(
            [Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    } finally { $certificate.Dispose() }
} finally { $rsa.Dispose(); $password.Dispose() }
Write-Output "Created encrypted PFX and public CER in $directory. Restrict directory access to your account. Register only the CER."
