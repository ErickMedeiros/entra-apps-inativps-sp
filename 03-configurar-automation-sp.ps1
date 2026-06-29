<#
.SYNOPSIS
    Grava a configuracao do Service Principal no Azure Automation Account como
    Automation Variables, deixando o runbook RB_AppsInativos.ps1 pronto para rodar
    sem nenhuma credencial em codigo.

.DESCRIPTION
    Cria/atualiza 4 Automation Variables:
        - AppGov-TenantId      (texto)
        - AppGov-ClientId      (texto)
        - AppGov-WorkspaceId   (texto)
        - AppGov-ClientSecret  (ENCRIPTADA)
    O runbook le esses valores via Get-AutomationVariable quando os parametros
    sao deixados como placeholder.

.PRE-REQUISITOS
    Modulos Az.Accounts e Az.Automation, e Connect-AzAccount na subscription certa.
    Use os valores impressos pelo script 01-grant-permissions.ps1.

.AVISO DE SEGURANCA
    Nao versione este arquivo com o secret preenchido. Preencha, execute e limpe
    a variavel local. A unica copia persistida fica encriptada no Automation Account.
#>

# ============================================================
# Preencha com os valores do 01-grant-permissions.ps1
# ============================================================
$resourceGroup       = "<RESOURCE_GROUP_DO_AUTOMATION_ACCOUNT>"
$automationAccount   = "<NOME_DO_AUTOMATION_ACCOUNT>"

$tenantId            = "<TENANT_ID>"
$clientId            = "<CLIENT_ID_DO_SERVICE_PRINCIPAL>"
$workspaceCustomerId = "<WORKSPACE_CUSTOMER_ID>"
$clientSecret        = "<CLIENT_SECRET_VALUE>"

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
        Write-Host "Atualizada: $Name (encrypted=$Encrypted)" -ForegroundColor Yellow
    }
    else {
        New-AzAutomationVariable -ResourceGroupName $resourceGroup `
            -AutomationAccountName $automationAccount -Name $Name `
            -Value $Value -Encrypted $Encrypted | Out-Null
        Write-Host "Criada: $Name (encrypted=$Encrypted)" -ForegroundColor Green
    }
}

# ============================================================
# Gravar as variaveis
# ============================================================
Set-AutoVar -Name "AppGov-TenantId"     -Value $tenantId            -Encrypted $false
Set-AutoVar -Name "AppGov-ClientId"     -Value $clientId            -Encrypted $false
Set-AutoVar -Name "AppGov-WorkspaceId"  -Value $workspaceCustomerId -Encrypted $false
Set-AutoVar -Name "AppGov-AuthMode"     -Value "Secret"             -Encrypted $false
Set-AutoVar -Name "AppGov-ClientSecret" -Value $clientSecret        -Encrypted $true

# ============================================================
# Limpar o secret da memoria desta sessao
# ============================================================
$clientSecret = $null
Remove-Variable clientSecret -ErrorAction SilentlyContinue

Write-Host "`nConfiguracao gravada no Automation Account '$automationAccount'." -ForegroundColor Cyan
Write-Host "O runbook agora le tudo via Get-AutomationVariable. Teste no Test pane." -ForegroundColor Cyan
