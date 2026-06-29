<#
.SYNOPSIS
    Sobe o certificado (.pfx) para o Azure Automation Account e grava a configuracao
    do Service Principal como Automation Variables, deixando o runbook pronto para
    rodar em AuthMode = Certificate (sem nenhum secret).

.DESCRIPTION
    Cria/atualiza:
        - Automation Certificate 'AppGov-Cert' (a partir do .pfx do 01b)
        - Automation Variables: AppGov-TenantId, AppGov-ClientId,
          AppGov-WorkspaceId e AppGov-AuthMode = "Certificate"
    O runbook le AppGov-AuthMode e usa o certificado automaticamente.

.PRE-REQUISITOS
    Modulos Az.Accounts e Az.Automation, e Connect-AzAccount na subscription certa.
    O .pfx gerado pelo 01b-criar-certificado.ps1 e a senha definida la.

.AVISO DE SEGURANCA
    Apos o upload, apague o .pfx local. A unica copia persistida fica no
    Automation Account (asset de certificado).
#>

# ============================================================
# Preencha com os valores do 01-grant-permissions.ps1 / 01b
# ============================================================
$resourceGroup       = "<RESOURCE_GROUP_DO_AUTOMATION_ACCOUNT>"
$automationAccount   = "<NOME_DO_AUTOMATION_ACCOUNT>"

$tenantId            = "<TENANT_ID>"
$clientId            = "<CLIENT_ID_DO_SERVICE_PRINCIPAL>"
$workspaceCustomerId = "<WORKSPACE_CUSTOMER_ID>"

$certName            = "AppGov-Cert"
$pfxPath             = "./AppGov-Cert.pfx"

# ============================================================
# Helper idempotente: cria ou atualiza uma Automation Variable
# ============================================================
function Set-AutoVar {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Value,
        [bool] $Encrypted = $false
    )
    $existe = Get-AzAutomationVariable -ResourceGroupName $resourceGroup `
        -AutomationAccountName $automationAccount -Name $Name -ErrorAction SilentlyContinue
    if ($existe) {
        Set-AzAutomationVariable -ResourceGroupName $resourceGroup `
            -AutomationAccountName $automationAccount -Name $Name `
            -Value $Value -Encrypted $Encrypted | Out-Null
        Write-Host "Atualizada: $Name" -ForegroundColor Yellow
    }
    else {
        New-AzAutomationVariable -ResourceGroupName $resourceGroup `
            -AutomationAccountName $automationAccount -Name $Name `
            -Value $Value -Encrypted $Encrypted | Out-Null
        Write-Host "Criada: $Name" -ForegroundColor Green
    }
}

# ============================================================
# 1. Subir o certificado para o Automation Account
# ============================================================
if (-not (Test-Path $pfxPath)) { throw "PFX nao encontrado em '$pfxPath'. Rode 01b-criar-certificado.ps1 antes." }
$pfxPassword = Read-Host -AsSecureString "Senha do .pfx (definida no 01b)"

$certExiste = Get-AzAutomationCertificate -ResourceGroupName $resourceGroup `
    -AutomationAccountName $automationAccount -Name $certName -ErrorAction SilentlyContinue
if ($certExiste) {
    Set-AzAutomationCertificate -ResourceGroupName $resourceGroup `
        -AutomationAccountName $automationAccount -Name $certName `
        -Path $pfxPath -Password $pfxPassword -Exportable $true | Out-Null
    Write-Host "Certificado atualizado: $certName" -ForegroundColor Yellow
}
else {
    New-AzAutomationCertificate -ResourceGroupName $resourceGroup `
        -AutomationAccountName $automationAccount -Name $certName `
        -Path $pfxPath -Password $pfxPassword -Exportable | Out-Null
    Write-Host "Certificado criado: $certName" -ForegroundColor Green
}

# ============================================================
# 2. Gravar as variaveis de configuracao
# ============================================================
Set-AutoVar -Name "AppGov-TenantId"    -Value $tenantId            -Encrypted $false
Set-AutoVar -Name "AppGov-ClientId"    -Value $clientId            -Encrypted $false
Set-AutoVar -Name "AppGov-WorkspaceId" -Value $workspaceCustomerId -Encrypted $false
Set-AutoVar -Name "AppGov-AuthMode"    -Value "Certificate"        -Encrypted $false

Write-Host "`nConfiguracao (certificado) gravada no Automation Account '$automationAccount'." -ForegroundColor Cyan
Write-Host "O runbook usara o certificado '$certName' automaticamente (AppGov-AuthMode=Certificate)." -ForegroundColor Cyan
Write-Host "APAGUE o arquivo local '$pfxPath' agora." -ForegroundColor Red
