<#
.SYNOPSIS
    Gera sign-ins de teste (client credentials flow) em App Registrations
    para popular o Log Analytics. Util para validar a Diagnostic Setting
    e o pipeline de detecao de apps inativos.

.PRE-REQUISITOS
    Cada app na lista precisa ter um Client Secret valido criado em
    Certificates & secrets. Cole o valor (visivel apenas no momento da criacao).

.AVISO DE SEGURANCA
    Apos os testes, REVOGUE os secrets usados aqui em
    App Registrations -> Certificates & secrets -> Delete.
    Nao versione este arquivo com secrets reais (use .gitignore).
#>

$tenantId = "<TENANT_ID>"

# Lista de apps a testar
$apps = @(
    @{
        Nome     = "app_teste_01"
        ClientId = "<APP_CLIENT_ID>"
        Secret   = "<CLIENT_SECRET_VALUE>"
    }
    # Adicione mais apps abaixo no mesmo formato
)

$repeticoes = 3   # quantos sign-ins gerar por app

foreach ($app in $apps) {
    Write-Host "`n=== Testando: $($app.Nome) ===" -ForegroundColor Cyan

    $body = @{
        grant_type    = "client_credentials"
        client_id     = $app.ClientId
        client_secret = $app.Secret
        scope         = "https://graph.microsoft.com/.default"
    }

    for ($i = 1; $i -le $repeticoes; $i++) {
        try {
            $resp = Invoke-RestMethod -Method POST `
                -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
                -Body $body -ErrorAction Stop

            $token = $resp.access_token.Substring(0, 40)
            Write-Host "  [$i/$repeticoes] OK - token: $token..." -ForegroundColor Green
        }
        catch {
            # Mesmo falhando, o sign-in fica registrado nos logs (ResultType != 0)
            Write-Host "  [$i/$repeticoes] Falha (sign-in registrado mesmo assim): $($_.Exception.Message)" -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 2
    }
}

Write-Host "`nConcluido. Aguarde 5-30 min e verifique no Log Analytics:" -ForegroundColor Cyan
Write-Host "  AADServicePrincipalSignInLogs | where TimeGenerated > ago(1h)" -ForegroundColor Cyan
