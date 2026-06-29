# Troubleshooting — Casos de erro estendidos

Catálogo dos erros encontrados durante a implantação real, com diagnóstico e solução.

---

## Erros de query KQL

### `Query is invalid. ParserFailure (Code:InvalidQuery)`

**Causa:** a query foi rodada no **Azure Resource Graph Explorer**, que só conhece recursos do ARM. Tabelas como `AuditLogs`, `SigninLogs`, `AADServicePrincipalSignInLogs` pertencem ao **Log Analytics**.

**Solução:** rode no Log Analytics workspace → **Logs**.

---

### `No results found from the specified time range`

**Possíveis causas:**

1. **Tabelas ainda não existem:** as tabelas do Entra ID nascem no Log Analytics **no primeiro evento ingerido** após habilitar a Diagnostic Setting. Antes disso, retornam vazio ou "table not found".

   **Diagnóstico:**
   ```kql
   AADServicePrincipalSignInLogs | count
   ```
   Se der erro de tabela ou `0`, ainda não houve eventos. Force um sign-in e aguarde 5-30 min.

2. **Janela do portal menor que `lookback`:** o Time range do portal limita TODAS as tabelas. Se você define `lookback = 90d` mas o Time range está em "Last 24h", a query nunca encontra dados de 90 dias atrás.

   **Solução:** ajuste o Time range para "Last 90 days" (ou maior).

3. **Lógica do `join` com `AuditLogs`:** versões iniciais da query usavam `AuditLogs` como tabela base. Como o `AuditLogs` só registra a **criação** do app, apps criados há mais de 90 dias caem fora da janela e o join zera tudo.

   **Solução:** use a query corrigida que parte dos próprios sign-in logs como base, não do AuditLogs.

---

## Erros de módulos PowerShell

### `The term 'Connect-MgGraph' is not recognized`

**Causa:** módulo `Microsoft.Graph.Authentication` não está disponível no Runbook.

**Soluções, em ordem:**

1. Verificar se o módulo foi importado **no runtime correto** (precisa bater com o do Runbook, ex.: 7.2).
2. Verificar se o ProvisioningState está em `Succeeded`:
   ```powershell
   Get-AzAutomationModule -ResourceGroupName $rg -AutomationAccountName $aa `
       -Name "Microsoft.Graph.Authentication" -RuntimeVersion "7.2"
   ```
3. Se a galeria do portal travar com "Loading failed", use o script [`02-import-modules.ps1`](02-import-modules.ps1).

---

### Galeria do portal: `Loading failed. Please refresh in few moments`

**Causa:** erro transitório do componente de browse da PowerShell Gallery no portal Azure.

**Soluções:**
1. Aguarde 30-60 s e recarregue a página (F5).
2. Tente em janela anônima ou outro navegador.
3. Use o script de importação via Cloud Shell (`New-AzAutomationModule`).

---

## Erros de autenticação / token (Service Principal)

### `AADSTS7000215: Invalid client secret provided`

**Causa:** o secret está incorreto, expirou, ou foi colado com espaços/quebras. (Só se aplica ao `AuthMode=Secret`.)

**Diagnóstico / solução:**

1. Confira a validade do secret em **App registration → Certificates & secrets**.
2. Se expirado, gere um novo com `01-grant-permissions.ps1` (ou `Add-MgApplicationPassword`).
3. Regrave a Automation Variable encriptada com `03-configurar-automation-sp.ps1`.
4. Garanta que está usando o **valor** (Secret Value), não o **Secret ID**.

---

### `AADSTS700027` / `Client assertion contains an invalid signature` (modo certificado)

**Causa:** a chave pública usada para verificar a assertion não confere com a chave privada que assinou — cert não registrado no app, registrado em outro app, ou expirado.

**Diagnóstico / solução:**

1. Confira que o certificado está em **App registration → Certificates & secrets → Certificates** e dentro da validade.
2. Verifique o thumbprint:
   ```powershell
   $app = Get-MgApplication -Filter "displayName eq 'AppGov-AppsInativos'"
   $app.KeyCredentials | Select-Object DisplayName, @{n='Thumbprint';e={[Convert]::ToHexString($_.CustomKeyIdentifier)}}, EndDateTime
   ```
3. Se faltar ou estiver expirado, reexecute `01b-criar-certificado.ps1` e depois `03b-configurar-automation-cert.ps1`.

---

### `Certificado nao encontrado (asset '...' nem store por thumbprint '...')`

**Causa:** o runbook está em `AuthMode=Certificate` mas o Automation Certificate asset `AppGov-Cert` não existe (ou o `.pfx` não foi subido).

**Solução:** rode `03b-configurar-automation-cert.ps1` para subir o `.pfx`. Fora do Azure Automation (execução local), passe `-CertificateThumbprint` apontando para um cert instalado no store.

---

### `O certificado '...' nao possui chave privada`

**Causa:** o asset foi criado a partir de um `.cer` (só chave pública) em vez do `.pfx` (com chave privada).

**Solução:** suba o `.pfx` exportado pelo `01b` (não o `.cer`). O `New-AzAutomationCertificate` precisa do arquivo com chave privada e da senha.

---

### `AADSTS700016: Application not found in the directory`

**Causa:** `ClientId` ou `TenantId` incorretos (app de outro tenant, ou GUID trocado).

**Solução:** confira as variáveis `AppGov-ClientId` e `AppGov-TenantId` contra o resumo impresso pelo `01-grant-permissions.ps1`.

---

### `Configuracao ausente: informe o parametro ou crie a Automation Variable 'AppGov-...'`

**Causa:** o Runbook foi executado com parâmetros placeholder, mas as Automation Variables do passo 6 não existem.

**Solução:** rode `03-configurar-automation-sp.ps1` para criar `AppGov-TenantId`, `AppGov-ClientId`, `AppGov-WorkspaceId` e `AppGov-ClientSecret` (encriptada). Ou passe os valores diretamente como parâmetros no Test pane.

---

### `Connect-MgGraph: invalid_client` ou token sem permissão de aplicação

**Causa típica:** a permissão de aplicação não recebeu admin consent. No modelo de SP, o consent é dado pela atribuição de AppRole (`New-MgServicePrincipalAppRoleAssignment`).

**Diagnóstico:**
```powershell
# Liste os AppRoles de aplicacao concedidos ao SP
$sp = Get-MgServicePrincipal -Filter "appId eq '<CLIENT_ID>'"
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id |
    Select-Object PrincipalDisplayName, ResourceDisplayName, AppRoleId
```
Se a lista vier vazia ou faltar alguma permissão, reexecute o bloco 4 do `01-grant-permissions.ps1`.

**Propagação:** após conceder, aguarde 15-30 min para o token refletir os novos AppRoles.

---

## Erros de envio de email

### `sendMail → 400 BadRequest: Empty Payload. JSON content expected`

**Causa típica:** o body chegou vazio (`null`) no Graph. Acontece quando:

1. A variável `$mensagem` está nula — você rodou só o bloco de envio sem os blocos anteriores que constroem o objeto.
2. O `Invoke-RestMethod` está enviando body vazio por um problema de serialização.

**Diagnóstico:**
```powershell
$jsonBody  = $mensagem | ConvertTo-Json -Depth 10 -Compress
Write-Output "DEBUG body length: $($jsonBody.Length) chars"
Write-Output "DEBUG body preview: $($jsonBody.Substring(0, [Math]::Min(200, $jsonBody.Length)))"
```

Se `length: 4 bytes` e `preview: null`, a variável está nula.

**Soluções:**

1. Sempre rode o **script completo**, não só o bloco do `sendMail`.
2. Serialize o body explicitamente em bytes UTF-8:
   ```powershell
   $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
   Invoke-RestMethod -Method POST ... -Body $bodyBytes
   ```

---

### `sendMail → MailboxNotEnabledForRESTAPI`

**Causa:** a mailbox do `$Remetente` não existe no Exchange Online (usuário sem licença Exchange).

**Diagnóstico:**
```powershell
$user = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/users/$Remetente?`$select=mail,assignedLicenses"
$user.mail              # vazio = sem mailbox
$user.assignedLicenses  # vazio = sem licença
```

**Soluções:**

1. Atribuir licença Exchange (E1/E3/E5/Business Standard) ao usuário.
2. Usar outra caixa do tenant que já tenha licença.

---

### Email cai no spam (Hotmail / Gmail)

**Causa:** domínio do remetente sem `SPF`, `DKIM`, `DMARC` configurados corretamente. Provedores externos marcam como suspeito.

**Solução (DNS do domínio):**

```
SPF:   v=spf1 include:spf.protection.outlook.com -all
DKIM:  habilitar via Exchange admin center
DMARC: v=DMARC1; p=quarantine; rua=mailto:dmarc@empresa.com
```

Em domínios de lab/teste, é comum cair no spam — não é problema do script.

---

## Erros de role / RBAC

### Log Analytics: `Forbidden` ou `Insufficient privileges`

**Causa:** o Service Principal não tem `Log Analytics Reader` no workspace.

**Solução:**
```powershell
$sp = Get-MgServicePrincipal -Filter "appId eq '<CLIENT_ID>'"
$ws = Get-AzOperationalInsightsWorkspace | Where-Object { $_.Name -eq "lwa-appresgistration" }
New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Log Analytics Reader" -Scope $ws.ResourceId
```

Aguarde 2-3 min para propagar.

---

### `Get-AzOperationalInsightsWorkspace: Resource group name cannot be null`

**Causa:** o cmdlet exige `-ResourceGroupName`.

**Solução (sem saber o RG):**
```powershell
$ws = Get-AzOperationalInsightsWorkspace | Where-Object { $_.Name -eq "NOME_DO_WORKSPACE" }
```
Esse listing não exige RG e retorna todos os workspaces da subscription.

---

## Erros de classificação (lógica)

### Apps que logaram aparecem como "Nunca logou"

**Causa 1: `servicePrincipalSignInActivities` em vez de Log Analytics.**
O relatório agregado do Graph tem latência de horas a dias. Sign-ins recentes não aparecem.

**Solução:** use o Log Analytics (abordagem híbrida do Runbook final).

**Causa 2: `AppId` na resposta REST sendo lido pelo índice errado.**

**Diagnóstico:**
```powershell
Write-Output "DEBUG colunas: $($laResp.tables[0].columns.name -join ', ')"
Write-Output "DEBUG primeira linha: $($laResp.tables[0].rows[0] -join ' | ')"
```

Confira a ordem das colunas. O Runbook final usa `[array]::IndexOf($cols, "AppId")` para evitar suposições sobre ordem.

---

## Checklist rápido de validação

Antes de abrir issue, confirme:

- [ ] Módulos `Microsoft.Graph.Authentication` e `Microsoft.Graph.Applications` em **runtime 7.2** e estado **Succeeded**.
- [ ] App Registration + Service Principal `AppGov-AppsInativos` criados (script `01-grant-permissions.ps1`).
- [ ] AppRoles `Application.Read.All`, `Directory.Read.All`, `AuditLog.Read.All`, `Mail.Send` atribuídos ao **SP** (`Get-MgServicePrincipalAppRoleAssignment`).
- [ ] Role `Log Analytics Reader` atribuída ao **Service Principal** no scope do workspace.
- [ ] Automation Variables `AppGov-TenantId`, `AppGov-ClientId`, `AppGov-WorkspaceId`, `AppGov-AuthMode` criadas.
- [ ] **Trilha A (Secret):** `AppGov-ClientSecret` **encriptada** e secret válido (não expirado).
- [ ] **Trilha B (Cert):** Automation Certificate `AppGov-Cert` (do `.pfx`, com chave privada) + cert registrado no app e dentro da validade.
- [ ] `AppGov-AuthMode` coerente com a trilha (`Secret` ou `Certificate`).
- [ ] Diagnostic Setting do Entra ID enviando `SignInLogs` + `ServicePrincipalSignInLogs` ao workspace correto.
- [ ] Mailbox `$Remetente` com licença Exchange ativa (campo `mail` preenchido em `Get-MgUser`).
- [ ] Pelo menos 1 sign-in gerado após a Diagnostic Setting (force com [`99-teste-app-login.ps1`](99-teste-app-login.ps1)).
- [ ] `WorkspaceId` é o **Customer ID** (`.CustomerId.Guid`), não o Resource ID.
- [ ] Aguardou 15-30 min após conceder os AppRoles / registrar a credencial para propagação.
