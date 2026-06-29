<#
.SYNOPSIS
    Gera um certificado self-signed, registra a chave publica no App Registration
    do runbook e exporta o .pfx (com chave privada) para upload no Automation Account.

.DESCRIPTION
    Caminho de autenticacao por CERTIFICADO (alternativa ao client secret).
    Usa System.Security.Cryptography (CertificateRequest), portanto funciona tanto
    no Azure Cloud Shell (PowerShell Linux) quanto no Windows PowerShell.

    Passos:
    1. Cria par de chaves RSA 2048 + certificado self-signed (CN=AppGov-Cert).
    2. Registra a chave PUBLICA no App Registration (keyCredentials).
    3. Exporta o .pfx (chave privada) protegido por senha, para o passo 03b.

.PRE-REQUISITOS
    Connect-MgGraph com Application.ReadWrite.All (mesma sessao do 01-grant-permissions.ps1).
    O App Registration ja deve existir (rode o 01 antes, com gerarSecret = $false).

.AVISO DE SEGURANCA
    O .pfx contem a chave privada. Trate como segredo: nao versione (.gitignore ja cobre),
    apague o arquivo local apos subir ao Automation Account, e use senha forte.
#>

# ============================================================
# Preencha estes valores antes de executar
# ============================================================
$appDisplayName = "AppGov-AppsInativos"   # mesmo nome usado no 01-grant-permissions.ps1
$certSubject    = "CN=AppGov-Cert"
$validMonths    = 12
$pfxPath        = "./AppGov-Cert.pfx"

# ============================================================
# 1. Localizar o App Registration
# ============================================================
$app = Get-MgApplication -Filter "displayName eq '$appDisplayName'" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $app) { throw "App Registration '$appDisplayName' nao encontrado. Rode 01-grant-permissions.ps1 primeiro." }
Write-Host "App encontrado. AppId: $($app.AppId)" -ForegroundColor Cyan

# ============================================================
# 2. Gerar certificado self-signed (cross-platform via .NET)
# ============================================================
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$dn  = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($certSubject)
$req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    $dn, $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

$notBefore = [DateTimeOffset]::UtcNow.AddMinutes(-5)
$notAfter  = [DateTimeOffset]::UtcNow.AddMonths($validMonths)
$cert = $req.CreateSelfSigned($notBefore, $notAfter)

Write-Host "Certificado gerado. Thumbprint: $($cert.Thumbprint)" -ForegroundColor Green
Write-Host "Validade ate: $($notAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Green

# ============================================================
# 3. Registrar a chave PUBLICA no App Registration
#    (define keyCredentials; substitui certificados anteriores do app)
# ============================================================
$keyCredential = @{
    type        = "AsymmetricX509Cert"
    usage       = "Verify"
    key         = $cert.GetRawCertData()          # DER da chave publica
    displayName = $certSubject
    startDateTime = $notBefore.UtcDateTime
    endDateTime   = $notAfter.UtcDateTime
}
Update-MgApplication -ApplicationId $app.Id -KeyCredentials @($keyCredential)
Write-Host "Chave publica registrada no App Registration." -ForegroundColor Green

# ============================================================
# 4. Exportar o .pfx (chave privada) para o passo 03b
# ============================================================
$pfxPassword = Read-Host -AsSecureString "Defina uma senha para proteger o .pfx"
$pfxBytes = $cert.Export(
    [System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
    $pfxPassword)
[System.IO.File]::WriteAllBytes((Resolve-Path -LiteralPath (Split-Path $pfxPath) ).Path + "/" + (Split-Path $pfxPath -Leaf), $pfxBytes) 2>$null
if (-not (Test-Path $pfxPath)) { [System.IO.File]::WriteAllBytes($pfxPath, $pfxBytes) }
Write-Host "PFX exportado: $pfxPath" -ForegroundColor Green

# ============================================================
# 5. Resumo
# ============================================================
Write-Host "`n================ RESUMO (CERTIFICADO) ================" -ForegroundColor Cyan
Write-Host "AppId (ClientId)     : $($app.AppId)"
Write-Host "Thumbprint           : $($cert.Thumbprint)"
Write-Host "PFX                  : $pfxPath (proteja e apague apos subir ao Automation)"
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "Proximo passo: 03b-configurar-automation-cert.ps1 (sobe o .pfx e grava as variaveis)." -ForegroundColor Cyan
Write-Host "Propagacao da credencial: ~15-30 min." -ForegroundColor Cyan
