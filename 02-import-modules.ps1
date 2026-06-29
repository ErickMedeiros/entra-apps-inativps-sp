<#
.SYNOPSIS
    Importa os modulos Microsoft.Graph necessarios para o Runbook
    RB_AppsInativos.ps1, no runtime PowerShell 7.2 do Azure Automation.

.NOTAS
    Use este script quando a galeria do portal estiver instavel
    ("Loading failed. Please refresh in few moments").
    Importa Authentication primeiro e aguarda 'Succeeded' antes do Applications,
    porque ha dependencia.
#>

$rg = "<RESOURCE_GROUP_DO_AUTOMATION_ACCOUNT>"
$aa = "<NOME_DO_AUTOMATION_ACCOUNT>"

function Wait-Module([string]$nome) {
    Write-Host "Aguardando '$nome' ficar Succeeded..." -ForegroundColor Yellow
    do {
        Start-Sleep -Seconds 30
        $state = (Get-AzAutomationModule -ResourceGroupName $rg `
            -AutomationAccountName $aa -Name $nome -RuntimeVersion "7.2").ProvisioningState
        Write-Host "  $nome -> $state"
    } while ($state -in @("Creating","Importing","RunningImportModuleRunbook"))

    if ($state -ne "Succeeded") { throw "Importacao de '$nome' falhou. Estado: $state" }
}

# 1. Authentication (base)
Write-Host "Importando Microsoft.Graph.Authentication..." -ForegroundColor Cyan
New-AzAutomationModule -ResourceGroupName $rg -AutomationAccountName $aa `
    -Name "Microsoft.Graph.Authentication" `
    -ContentLinkUri "https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication" `
    -RuntimeVersion "7.2" | Out-Null
Wait-Module "Microsoft.Graph.Authentication"

# 2. Applications (depende do Authentication)
Write-Host "Importando Microsoft.Graph.Applications..." -ForegroundColor Cyan
New-AzAutomationModule -ResourceGroupName $rg -AutomationAccountName $aa `
    -Name "Microsoft.Graph.Applications" `
    -ContentLinkUri "https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Applications" `
    -RuntimeVersion "7.2" | Out-Null
Wait-Module "Microsoft.Graph.Applications"

Write-Host "`nModulos importados com sucesso no runtime 7.2." -ForegroundColor Green
