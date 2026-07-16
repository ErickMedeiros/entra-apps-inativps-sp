<#
.SYNOPSIS
    Detecta App Registrations inativas no Microsoft Entra ID e envia
    relatorio (HTML + CSV anexo) por email para um grupo de administradores.

.DESCRIPTION
    Abordagem 100% Microsoft Graph (sem Log Analytics):
    - Inventario completo dos apps via Get-MgApplication.
    - Ultimo sign-in por app via relatorio servicePrincipalSignInActivities (beta).
    Cruza por AppId e classifica: Ativo / Inativo / Nunca logou.
    Avalia tambem credenciais (Atual / Expirando em breve / Expirado).

    Vantagem sobre Log Analytics: roda no proprio tenant do app (sem cross-tenant),
    usa AuditLog.Read.All (ja concedida) e dispensa workspace/Diagnostic Settings.
    O relatorio e beta e tem latencia de horas/dias (ok para janelas de 30/90 dias).

    AUTENTICACAO: Service Principal, com DUAS alternativas selecionaveis por -AuthMode:
      - 'Secret'      : client_credentials com client secret.
      - 'Certificate' : client_credentials com client assertion (JWT assinado
                        pelo certificado). Sem secret em texto; mais seguro.
    Os tokens (Graph e Log Analytics) sao obtidos sempre via o mesmo endpoint
    /oauth2/v2.0/token; muda apenas a prova de identidade (secret vs assertion).

.PARAMETER DiasSemUso
    Janela de inatividade (default 90).

.PARAMETER AuthMode
    'Secret' (default) ou 'Certificate'.

.PARAMETER TenantId
    GUID do tenant. Placeholder => Automation Variable 'AppGov-TenantId'.

.PARAMETER ClientId
    AppId do Service Principal. Placeholder => Automation Variable 'AppGov-ClientId'.

.PARAMETER ClientSecret
    [AuthMode=Secret] Valor do secret. Vazio => Automation Variable encriptada
    definida em -SecretVariableName.

.PARAMETER SecretVariableName
    [AuthMode=Secret] Nome da Automation Variable encriptada (default 'AppGov-ClientSecret').

.PARAMETER CertificateName
    [AuthMode=Certificate] Nome do Automation Certificate asset (default 'AppGov-Cert').

.PARAMETER CertificateThumbprint
    [AuthMode=Certificate] Thumbprint para localizar o certificado no store local
    (usado quando executado fora do Azure Automation).

.PARAMETER WorkspaceId
    Customer ID (GUID) do workspace. Placeholder => Automation Variable 'AppGov-WorkspaceId'.

.PARAMETER Remetente
    UPN da mailbox que envia o email. Deve ter licenca Exchange Online ativa.

.PARAMETER Destinatario
    Um ou mais enderecos que recebem o relatorio, separados por virgula ou
    ponto-e-virgula. Ex.: "a@x.com,b@y.com". Pode ser caixa individual ou DL.

.PRE-REQUISITOS
    Modulos (runtime 7.2): Microsoft.Graph.Authentication, Microsoft.Graph.Applications
    Permissoes de APLICACAO do SP (Graph), com admin consent:
        Application.Read.All, Directory.Read.All, AuditLog.Read.All, Mail.Send
    Licenca Microsoft Entra ID P1 ou P2 (necessaria para o relatorio de sign-in).
    NAO precisa mais de workspace Log Analytics, RBAC nem Diagnostic Settings.

.NOTES
    Autor:   Equipe de Identidade
    Versao:  2.3  (sign-in via Graph report; sem Log Analytics)
    Runtime: PowerShell 7.2 (Azure Automation sandbox)
#>

param(
    [int]    $DiasSemUso        = 30,

    # Vazio => resolve via Automation Variable 'AppGov-AuthMode'; senao 'Secret'.
    [string] $AuthMode          = "",

    [string] $TenantId          = "",
    [string] $ClientId          = "",

    # --- AuthMode = Secret ---
    [string] $ClientSecret      = "",
    [string] $SecretVariableName = "AppGov-ClientSecret",

    # --- AuthMode = Certificate ---
    [string] $CertificateName       = "AppGov-Cert",
    [string] $CertificateThumbprint = "",

    # --- Comum ---
    # WorkspaceId: legado (nao usado nesta versao; sign-in vem do Graph report).
    [string] $WorkspaceId       = "",
    [string] $Remetente         = "email-remetente",
    [string] $Destinatario      = "email-desinatário,separadoporvirgula"
)

$ErrorActionPreference = "Stop"
$hoje      = Get-Date
$dataCorte = $hoje.AddDays(-$DiasSemUso)

# ============================================================
# 0. Resolver configuracao (parametro tem prioridade; senao Automation Variable)
# ============================================================
function Resolve-Config {
    param([string] $Value, [string] $VariableName)
    if ($Value -and $Value -notmatch '^<.*>$') { return $Value }
    try {
        $v = Get-AutomationVariable -Name $VariableName
        if ([string]::IsNullOrWhiteSpace($v)) { throw "vazia" }
        return $v
    }
    catch {
        throw "Configuracao ausente: informe o parametro ou crie a Automation Variable '$VariableName'."
    }
}

$TenantId    = Resolve-Config -Value $TenantId -VariableName "AppGov-TenantId"
$ClientId    = Resolve-Config -Value $ClientId -VariableName "AppGov-ClientId"

# Resolver AuthMode: parametro explicito > Automation Variable 'AppGov-AuthMode' > 'Secret'
if ([string]::IsNullOrWhiteSpace($AuthMode)) {
    try   { $AuthMode = Get-AutomationVariable -Name "AppGov-AuthMode" }
    catch { $AuthMode = "Secret" }
}
if ([string]::IsNullOrWhiteSpace($AuthMode)) { $AuthMode = "Secret" }
if ($AuthMode -notin @('Secret','Certificate')) {
    throw "AuthMode invalido: '$AuthMode'. Use 'Secret' ou 'Certificate'."
}

$script:Cert = $null
$tokenUri    = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

if ($AuthMode -eq 'Secret') {
    if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
        try   { $ClientSecret = Get-AutomationVariable -Name $SecretVariableName }
        catch { throw "ClientSecret nao informado e Automation Variable encriptada '$SecretVariableName' nao encontrada." }
    }
    if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
        throw "ClientSecret vazio. Verifique a Automation Variable '$SecretVariableName'."
    }
}
else {
    # Certificate: tenta Automation Certificate asset; fallback para store local por thumbprint
    try {
        $script:Cert = Get-AutomationCertificate -Name $CertificateName -ErrorAction Stop
    }
    catch {
        if ($CertificateThumbprint) {
            foreach ($loc in @("Cert:\CurrentUser\My","Cert:\LocalMachine\My")) {
                $c = Get-ChildItem $loc -ErrorAction SilentlyContinue |
                     Where-Object { $_.Thumbprint -eq $CertificateThumbprint } | Select-Object -First 1
                if ($c) { $script:Cert = $c; break }
            }
        }
    }
    if (-not $script:Cert) {
        throw "Certificado nao encontrado (asset '$CertificateName' nem store por thumbprint '$CertificateThumbprint')."
    }
    if (-not $script:Cert.HasPrivateKey) {
        throw "O certificado '$CertificateName' nao possui chave privada; nao e possivel assinar a assertion."
    }
}

Write-Output "Configuracao resolvida. AuthMode: $AuthMode | Tenant: $TenantId | ClientId: $ClientId"

# ============================================================
# 1a. Helper: client assertion JWT (RS256) assinada pelo certificado
# ============================================================
function ConvertTo-Base64Url {
    param([byte[]] $Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function New-ClientAssertion {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2] $Cert)

    $now = [DateTimeOffset]::UtcNow
    $exp = $now.AddMinutes(10)

    $x5t    = ConvertTo-Base64Url -Bytes $Cert.GetCertHash()   # SHA-1 thumbprint
    $header = @{ alg = "RS256"; typ = "JWT"; x5t = $x5t } | ConvertTo-Json -Compress
    $claims = @{
        aud = $tokenUri
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().ToString()
        nbf = $now.ToUnixTimeSeconds()
        exp = $exp.ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress

    $headerB64 = ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($header))
    $claimsB64 = ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($claims))
    $unsigned  = "$headerB64.$claimsB64"

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Cert)
    if (-not $rsa) { throw "Nao foi possivel obter a chave privada RSA do certificado." }

    $sigBytes = $rsa.SignData(
        [Text.Encoding]::UTF8.GetBytes($unsigned),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $sigB64 = ConvertTo-Base64Url -Bytes $sigBytes

    return "$unsigned.$sigB64"
}

# ============================================================
# 1b. Helper: obter token de aplicacao (secret ou assertion)
# ============================================================
function Get-EntraToken {
    param([Parameter(Mandatory)][string] $Resource)   # ex.: https://graph.microsoft.com

    if ($AuthMode -eq 'Certificate') {
        $body = @{
            grant_type            = "client_credentials"
            client_id             = $ClientId
            client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
            client_assertion      = (New-ClientAssertion -Cert $script:Cert)
            scope                 = "$Resource/.default"
        }
    }
    else {
        $body = @{
            grant_type    = "client_credentials"
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "$Resource/.default"
        }
    }

    $resp = Invoke-RestMethod -Method POST -Uri $tokenUri `
        -ContentType "application/x-www-form-urlencoded" -Body $body
    return $resp.access_token
}

# ============================================================
# 2. Conectar ao Microsoft Graph (Service Principal / app-only)
# ============================================================
if ($AuthMode -eq 'Certificate') {
    Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -Certificate $script:Cert -NoWelcome
}
else {
    $secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $spCredential = [System.Management.Automation.PSCredential]::new($ClientId, $secureSecret)
    Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $spCredential -NoWelcome
}
Write-Output "Conectado ao Microsoft Graph como Service Principal (app-only)."

# ============================================================
# 3. Ultimo login por app via Graph (servicePrincipalSignInActivities, beta)
#    Substitui o Log Analytics: mesma autenticacao (Graph), sem cross-tenant.
#    Requer AuditLog.Read.All (aplicacao) + Entra ID P1/P2.
#    Para cada app pega a data mais recente entre os tipos de sign-in.
# ============================================================
$signInPorAppId = @{}
try {
    $tokenRep = Get-EntraToken -Resource "https://graph.microsoft.com"
    $uri = 'https://graph.microsoft.com/beta/reports/servicePrincipalSignInActivities'

    $paginas = 0
    $totalItens = 0
    do {
        $resp = Invoke-RestMethod -Method GET -Uri $uri `
            -Headers @{ Authorization = "Bearer $tokenRep" }

        $totalItens += @($resp.value).Count
        foreach ($item in $resp.value) {
            $appId = $item.appId
            if (-not $appId) { continue }

            $datas = @(
                $item.lastSignInActivity.lastSignInDateTime
                $item.applicationAuthenticationClientSignInActivity.lastSignInDateTime
                $item.delegatedClientSignInActivity.lastSignInDateTime
            ) | Where-Object { $_ } | ForEach-Object { [datetime]$_ }

            if ($datas) {
                $maisRecente = $datas | Sort-Object -Descending | Select-Object -First 1
                $atual = $signInPorAppId["$appId"]
                if (-not $atual -or $maisRecente -gt $atual) {
                    $signInPorAppId["$appId"] = $maisRecente
                }
            }
        }

        $uri = $resp.'@odata.nextLink'
        $paginas++
    } while ($uri -and $paginas -lt 50)

    Write-Output "Sign-in (Graph report): $totalItens itens no relatorio; ultimo login mapeado para $($signInPorAppId.Count) apps."
}
catch {
    Write-Warning "Falha ao consultar servicePrincipalSignInActivities: $($_.Exception.Message)"
    Write-Warning "Details: $($_.ErrorDetails.Message)"
}

# ============================================================
# 4. Inventario completo do tenant via Graph
# ============================================================
$apps = Get-MgApplication -All -Property "Id,AppId,DisplayName,CreatedDateTime,PasswordCredentials,KeyCredentials"
Write-Output "Inventario: $($apps.Count) app registrations."

# ============================================================
# 5. Classificacao por inatividade e status de credenciais
# ============================================================
$resultado = foreach ($app in $apps) {
    $ultimoLogin = $signInPorAppId["$($app.AppId)"]

    if ($null -eq $ultimoLogin) {
        $status = "Nunca logou"
        $dias   = $null
    }
    elseif ($ultimoLogin -lt $dataCorte) {
        $status = "Inativo (>$DiasSemUso d)"
        $dias   = [int]($hoje - $ultimoLogin).TotalDays
    }
    else {
        $status = "Ativo"
        $dias   = [int]($hoje - $ultimoLogin).TotalDays
    }

    $creds = @()
    $creds += $app.PasswordCredentials | ForEach-Object { $_.EndDateTime }
    $creds += $app.KeyCredentials      | ForEach-Object { $_.EndDateTime }

    if (-not $creds)                                              { $cred = "Sem credenciais" }
    elseif ($creds | Where-Object { $_ -lt $hoje })               { $cred = "Expirado" }
    elseif ($creds | Where-Object { $_ -lt $hoje.AddDays(30) })   { $cred = "Expirando em breve" }
    else                                                          { $cred = "Atual" }

    [pscustomobject]@{
        Nome        = $app.DisplayName
        AppId       = $app.AppId
        UltimoLogin = if ($ultimoLogin) { $ultimoLogin.ToString("yyyy-MM-dd HH:mm") } else { "Nunca" }
        DiasSemUso  = if ($null -ne $dias) { $dias } else { "-" }
        Credencial  = $cred
        Status      = $status
    }
}

$candidatos = $resultado |
    Where-Object { $_.Status -ne "Ativo" } |
    Sort-Object @{ Expression = { if ($_.DiasSemUso -eq "-") { 99999 } else { [int]$_.DiasSemUso } }; Descending = $true }

Write-Output "Inativos ou nunca logados: $($candidatos.Count) de $($apps.Count) apps."

if (-not $candidatos) {
    Write-Output "Nenhum app inativo. Email nao enviado."
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    return
}

# ============================================================
# 6. Email HTML
# ============================================================
$linhas = foreach ($c in $candidatos) {
    $corCred = switch ($c.Credencial) {
        "Expirado"           { "#d13438" }
        "Expirando em breve" { "#c19c00" }
        "Atual"              { "#107c10" }
        default              { "#666" }
    }
    "<tr><td>$($c.Nome)</td><td style='font-family:monospace;font-size:12px'>$($c.AppId)</td><td>$($c.UltimoLogin)</td><td style='text-align:center'>$($c.DiasSemUso)</td><td style='color:$corCred;font-weight:600'>$($c.Credencial)</td><td style='font-weight:600'>$($c.Status)</td></tr>"
}

$html = @"
<html><body style='font-family:Segoe UI,Arial,sans-serif;color:#252525'>
<h2 style='color:#0078d4'>Sotreq - Relatorio de Aplicativos Inativos - Microsoft Entra ID</h2>
<p>Identificados <b>$($candidatos.Count)</b> aplicativos inativos ou nunca logados
(janela de <b>$DiasSemUso dias</b>).</p>
<p>Veja a tabela abaixo e o CSV anexo com a lista completa.</p>
<table border='1' cellspacing='0' cellpadding='8' style='border-collapse:collapse;font-size:14px'>
<thead style='background:#f3f2f1'><tr><th>Nome</th><th>App ID</th><th>Ultimo Login</th><th>Dias Sem Uso</th><th>Credencial</th><th>Status</th></tr></thead>
<tbody>$($linhas -join "`n")</tbody></table>
<p style='font-size:12px;color:#888;margin-top:20px'>
Gerado em $($hoje.ToString('yyyy-MM-dd HH:mm')) via Azure Automation (Service Principal / $AuthMode).<br>
Acao recomendada: validar com proprietarios, desativar (quarentena) e remover apos confirmacao.
</p>
</body></html>
"@

# ============================================================
# 7. CSV em memoria (so candidatos)
# ============================================================
$csvLinhas  = @("Nome;AppId;UltimoLogin;DiasSemUso;Credencial;Status")
$csvLinhas += $candidatos | ForEach-Object {
    $nome = ($_.Nome -replace '"','""')
    "`"$nome`";$($_.AppId);$($_.UltimoLogin);$($_.DiasSemUso);$($_.Credencial);$($_.Status)"
}
$csvConteudo = $csvLinhas -join "`r`n"

$bom       = [char]0xFEFF
$csvBytes  = [System.Text.Encoding]::UTF8.GetBytes("$bom$csvConteudo")
$csvBase64 = [Convert]::ToBase64String($csvBytes)
$csvNome   = "apps-inativos-$(Get-Date -Format 'yyyyMMdd').csv"

Write-Output "CSV gerado: $($candidatos.Count) linhas, $($csvBytes.Length) bytes."

# ============================================================
# 8. Montar mensagem com anexo
#    Destinatario aceita varios enderecos separados por virgula ou ponto-e-virgula.
#    Cada endereco vira um item em toRecipients (senao o Graph tenta resolver a
#    string inteira como um unico endereco -> ErrorInvalidRecipients).
# ============================================================
$listaDestinatarios = $Destinatario -split '[;,]' |
    ForEach-Object { $_.Trim() } |
    Where-Object   { $_ }

if (-not $listaDestinatarios) {
    throw "Nenhum destinatario valido em -Destinatario."
}

$toRecipients = @(
    foreach ($addr in $listaDestinatarios) {
        @{ emailAddress = @{ address = $addr } }
    }
)

Write-Output "Destinatarios ($($listaDestinatarios.Count)): $($listaDestinatarios -join ', ')"

$mensagem = @{
    message = @{
        subject      = "[Entra ID] $($candidatos.Count) aplicativos inativos (>= $DiasSemUso dias)"
        body         = @{ contentType = "HTML"; content = $html }
        toRecipients = $toRecipients
        attachments  = @(
            @{
                "@odata.type" = "#microsoft.graph.fileAttachment"
                name          = $csvNome
                contentType   = "text/csv"
                contentBytes  = $csvBase64
            }
        )
    }
    saveToSentItems = $true
}

# ============================================================
# 9. Envio via REST com token fresco do Service Principal
# ============================================================
try {
    $tokenGraph = Get-EntraToken -Resource "https://graph.microsoft.com"

    $jsonBody  = $mensagem | ConvertTo-Json -Depth 10 -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
    Write-Output "DEBUG body length: $($jsonBody.Length) chars"

    Invoke-RestMethod -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/users/$Remetente/sendMail" `
        -Headers @{ Authorization = "Bearer $tokenGraph"; "Content-Type" = "application/json; charset=utf-8" } `
        -Body $bodyBytes

    Write-Output "Email enviado para $($listaDestinatarios.Count) destinatario(s) com anexo $csvNome."
}
catch {
    Write-Warning "Falha ao enviar email: $($_.Exception.Message)"
    Write-Warning "Details: $($_.ErrorDetails.Message)"
    throw
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
