<#
.SYNOPSIS
    Provisiona o Service Principal do runbook RB_AppsInativos.ps1 e concede
    todas as permissoes necessarias.

.DESCRIPTION
    1. Cria (ou reutiliza) o App Registration + Service Principal.
    2. Gera um client secret (exibido UMA UNICA vez).
    3. Concede 4 permissoes de APLICACAO no Microsoft Graph (com admin consent):
        - Application.Read.All
        - Directory.Read.All
        - AuditLog.Read.All
        - Mail.Send
    4. Concede a role RBAC 'Log Analytics Reader' ao SP no workspace.

    Substitui o modelo anterior baseado em Managed Identity.
    A concessao via New-MgServicePrincipalAppRoleAssignment ja equivale ao
    admin consent da permissao de aplicacao (nao precisa de consentimento manual).

.NOTAS
    Execute UMA VEZ, no Azure Cloud Shell ou em PowerShell local autenticado.
    A conta executora precisa ser Privileged Role Administrator (ou Global Admin)
    para conceder permissoes de aplicacao, e Owner/User Access Administrator na
    subscription para a atribuicao RBAC no workspace.
    Permissoes recem-concedidas levam ~15-30 min para propagar.

    GUARDE O SECRET EXIBIDO: ele nao podera ser recuperado depois. Use o script
    03-configurar-automation-sp.ps1 para grava-lo de forma encriptada no
    Automation Account.
#>

# ============================================================
# Preencha estes valores antes de executar
# ============================================================
$appDisplayName  = "AppGov-AppsInativos"                 # Nome do App Registration a criar/reutilizar
$workspaceName   = "<NOME_DO_WORKSPACE_LOG_ANALYTICS>"
$gerarSecret     = $true                                 # $false se for usar SOMENTE certificado (script 01b)
$secretMeses     = 12                                    # Validade do client secret (meses)

# ============================================================
# 1. Conectar ao Graph com escopo de escrita de app/consent
# ============================================================
Connect-MgGraph -Scopes `
    "Application.ReadWrite.All", `
    "AppRoleAssignment.ReadWrite.All", `
    "Directory.Read.All"

$tenantId = (Get-MgContext).TenantId
Write-Host "Tenant: $tenantId" -ForegroundColor Cyan

# ============================================================
# 2. Criar (ou reutilizar) o App Registration + Service Principal
# ============================================================
$app = Get-MgApplication -Filter "displayName eq '$appDisplayName'" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $app) {
    $app = New-MgApplication -DisplayName $appDisplayName -SignInAudience "AzureADMyOrg"
    Write-Host "App Registration criado: $appDisplayName" -ForegroundColor Green
}
else {
    Write-Host "App Registration ja existe: $appDisplayName" -ForegroundColor Yellow
}

$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $sp) {
    $sp = New-MgServicePrincipal -AppId $app.AppId
    Write-Host "Service Principal criado. ObjectId: $($sp.Id)" -ForegroundColor Green
}
else {
    Write-Host "Service Principal ja existe. ObjectId: $($sp.Id)" -ForegroundColor Yellow
}

$spObjectId = $sp.Id

# ============================================================
# 3. Gerar client secret (opcional - pule se for usar certificado)
# ============================================================
$secret = $null
if ($gerarSecret) {
    $passwordCred = @{
        displayName = "rb-appsinativos-$(Get-Date -Format 'yyyyMMdd')"
        endDateTime = (Get-Date).AddMonths($secretMeses)
    }
    $secret = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential $passwordCred
    Write-Host "Client secret gerado (validade: $secretMeses meses)." -ForegroundColor Green
}
else {
    Write-Host "Geracao de secret pulada (gerarSecret=`$false). Use 01b-criar-certificado.ps1." -ForegroundColor Yellow
}

# ============================================================
# 4. Permissoes Graph (Application) + admin consent
# ============================================================
$graph = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$permissoes = "Application.Read.All","AuditLog.Read.All","Directory.Read.All","Mail.Send"

foreach ($p in $permissoes) {
    $role = $graph.AppRoles | Where-Object { $_.Value -eq $p -and $_.AllowedMemberTypes -contains "Application" }
    if (-not $role) {
        Write-Warning "Permissao '$p' nao encontrada nos AppRoles do Graph."
        continue
    }

    $existente = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $spObjectId |
        Where-Object { $_.AppRoleId -eq $role.Id -and $_.ResourceId -eq $graph.Id }
    if ($existente) {
        Write-Host "Ja concedido: $p" -ForegroundColor Yellow
        continue
    }

    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $spObjectId `
        -PrincipalId $spObjectId `
        -ResourceId $graph.Id `
        -AppRoleId $role.Id | Out-Null
    Write-Host "Concedido (com consent): $p" -ForegroundColor Green
}

# ============================================================
# 5. RBAC no workspace Log Analytics (precisa do modulo Az.* + Connect-AzAccount)
# ============================================================
$ws = Get-AzOperationalInsightsWorkspace | Where-Object { $_.Name -eq $workspaceName }
if (-not $ws) { throw "Workspace '$workspaceName' nao encontrado na subscription atual." }

$jaExiste = Get-AzRoleAssignment -ObjectId $spObjectId -Scope $ws.ResourceId -ErrorAction SilentlyContinue |
    Where-Object { $_.RoleDefinitionName -eq "Log Analytics Reader" }

if ($jaExiste) {
    Write-Host "RBAC ja concedido: Log Analytics Reader em $($ws.Name)" -ForegroundColor Yellow
}
else {
    New-AzRoleAssignment `
        -ObjectId $spObjectId `
        -RoleDefinitionName "Log Analytics Reader" `
        -Scope $ws.ResourceId | Out-Null
    Write-Host "RBAC concedido: Log Analytics Reader em $($ws.Name)" -ForegroundColor Green
}

# ============================================================
# 6. Resumo (ANOTE ESTES VALORES)
# ============================================================
Write-Host "`n================ RESUMO (ANOTE AGORA) ================" -ForegroundColor Cyan
Write-Host "TenantId         : $tenantId"
Write-Host "ClientId (AppId) : $($app.AppId)"
Write-Host "SP ObjectId      : $spObjectId"
if ($secret) {
    Write-Host "ClientSecret     : $($secret.SecretText)" -ForegroundColor Magenta
}
else {
    Write-Host "ClientSecret     : (nao gerado - usando certificado via 01b)" -ForegroundColor Yellow
}
Write-Host "Workspace ID     : $($ws.CustomerId.Guid)"
Write-Host "======================================================" -ForegroundColor Cyan
if ($secret) {
    Write-Host "O SECRET ACIMA NAO PODERA SER RECUPERADO DEPOIS." -ForegroundColor Red
    Write-Host "Grave-o de forma encriptada com 03-configurar-automation-sp.ps1." -ForegroundColor Red
}
else {
    Write-Host "Proximo passo: gere o certificado com 01b-criar-certificado.ps1." -ForegroundColor Cyan
}
Write-Host "`nAguarde 15-30 min para propagacao antes de testar o Runbook." -ForegroundColor Cyan
