# Detecção de Aplicativos Inativos no Microsoft Entra ID

> Automação em Azure Automation Runbook que identifica **App Registrations** sem atividade de sign-in em um período configurável e envia relatório por e-mail (HTML + CSV anexo) para um grupo de administradores.
>
> **Autenticação via Service Principal** com **duas alternativas selecionáveis**: **client secret** ou **certificado**. O mesmo runbook atende às duas, controlado por `-AuthMode`.

[![PowerShell](https://img.shields.io/badge/PowerShell-7.2-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/en-us/powershell/)
[![Azure Automation](https://img.shields.io/badge/Azure-Automation-0078D4?logo=microsoftazure&logoColor=white)](https://learn.microsoft.com/en-us/azure/automation/)
[![Microsoft Graph](https://img.shields.io/badge/Microsoft-Graph-2F2F2F?logo=microsoft&logoColor=white)](https://learn.microsoft.com/en-us/graph/)

---

## 📋 Sumário

- [Objetivo](#-objetivo)
- [Arquitetura](#-arquitetura)
- [Autenticação: duas alternativas](#-autenticação-duas-alternativas)
- [Por que abordagem híbrida?](#-por-que-abordagem-híbrida-graph--log-analytics)
- [Pré-requisitos](#-pré-requisitos)
- [Guia de implantação](#-guia-de-implantação)
  - [Passos comuns (1 a 4)](#passos-comuns)
  - [Trilha A — Client Secret](#trilha-a--client-secret)
  - [Trilha B — Certificado](#trilha-b--certificado)
  - [Passos finais comuns (importar, testar, agendar)](#passos-finais-comuns)
- [Como o script funciona](#-como-o-script-funciona)
- [Resolução de problemas](#-resolução-de-problemas)
- [Boas práticas de produção](#-boas-práticas-de-produção)
- [Estrutura do repositório](#-estrutura-do-repositório)
- [Licença](#-licença)

---

## 🎯 Objetivo

Atender uma demanda comum de governança de identidade: **localizar e remover aplicativos esquecidos** no tenant Entra ID. App Registrations abandonadas com credenciais expiradas (ou sem uso) representam vetor de ataque e desperdício de inventário.

A automação responde a três perguntas a cada execução:

1. Quais apps **nunca tiveram sign-in** registrado?
2. Quais apps **não logam há mais de N dias** (configurável: 10/60/90)?
3. Qual o **estado da credencial** (secret/cert) de cada um — atual, expirando ou expirada?

O resultado é entregue por e-mail HTML formatado com tabela colorida e um CSV anexo para análise no Excel.

---

## 🏗️ Arquitetura

```
                     ┌──────────────────────┐
                     │  Microsoft Entra ID  │
                     │   (App Registrations)│
                     └──────────┬───────────┘
                                │
                  Sign-ins      │      Inventário
                  ┌─────────────┴─────────────┐
                  ▼                           ▼
        ┌─────────────────┐         ┌──────────────────┐
        │  Log Analytics  │         │ Microsoft Graph  │
        │  (dado fresco)  │         │ (Get-MgApp...)   │
        └────────┬────────┘         └────────┬─────────┘
                 │                           │
                 └─────────────┬─────────────┘
                               ▼
                  ┌─────────────────────────┐
                  │   Azure Automation      │
                  │   Runbook PowerShell 7.2│
                  │   Service Principal     │
                  │   (secret OU cert)      │
                  └────────────┬────────────┘
                               │
                               ▼
                  ┌─────────────────────────┐
                  │  sendMail (Graph)       │
                  │  HTML + CSV anexo       │
                  └────────────┬────────────┘
                               ▼
                       admins@empresa.com
```

**Fluxo de execução:**

1. Runbook autentica via **Service Principal**. A prova de identidade é um **client secret** ou um **client assertion (JWT) assinado por certificado**, conforme `-AuthMode`.
2. Consulta **Log Analytics** (REST, token do SP) para obter o último sign-in real de cada AppId.
3. Lista o **inventário completo** via `Get-MgApplication` (Graph app-only).
4. Cruza inventário com sign-ins e classifica: `Ativo` / `Inativo` / `Nunca logou`.
5. Avalia credenciais (secrets/certs): `Atual` / `Expirando em breve` / `Expirado` / `Sem credenciais`.
6. Gera HTML + CSV (base64) e envia via `sendMail` do Graph (token fresco do SP).

---

## 🔐 Autenticação: duas alternativas

O repositório suporta **dois caminhos de credencial** para o mesmo Service Principal. Ambos usam o fluxo `client_credentials` no endpoint `/oauth2/v2.0/token`; muda apenas **como o SP prova quem é**.

| Critério | **Client Secret** | **Certificado** |
|---|---|---|
| Prova de identidade | `client_secret` (string) | `client_assertion` (JWT assinado pela chave privada) |
| Segurança | Boa — segredo encriptado em repouso | **Melhor** — sem segredo em texto; chave privada não trafega |
| Onde guardar | Automation Variable encriptada | Automation Certificate asset (.pfx) |
| Complexidade de setup | Menor | Um passo a mais (gerar/registrar cert) |
| Rotação | Manual ou automatizada (novo secret) | Renovar/recriar o certificado |
| Quando usar | Labs, POCs, ambientes simples | **Produção**, requisitos de compliance |
| `-AuthMode` | `Secret` | `Certificate` |

> **Recomendação:** use **Certificado** em produção. O **Client Secret** é perfeitamente válido para começar e migrar depois — a troca é só mudar `AppGov-AuthMode` e rodar o `03b`.

O runbook decide o modo nesta ordem: parâmetro `-AuthMode` explícito → Automation Variable `AppGov-AuthMode` → padrão `Secret`. Os scripts `03` e `03b` gravam `AppGov-AuthMode` automaticamente, então a trilha escolhida "simplesmente funciona".

---

## 🤔 Por que abordagem híbrida (Graph + Log Analytics)?

Uma versão "puramente KQL" sobre `AADServicePrincipalSignInLogs` parece tentadora, mas tem uma limitação fatal: **a query KQL só enxerga apps que já logaram desde que a Diagnostic Setting foi habilitada**. Apps abandonados há meses (os mais óbvios candidatos a remoção) não aparecem.

Uma versão "puramente Graph" usando o relatório `servicePrincipalSignInActivities` também falha: esse endpoint é **agregado e eventualmente consistente**, com atraso de horas a dias. Não reflete a realidade imediata.

A abordagem híbrida combina o melhor dos dois:

| Fonte | Função | Vantagem |
|---|---|---|
| **Microsoft Graph** (`Get-MgApplication`) | Inventário completo | Vê todos os apps, incluindo os nunca usados |
| **Log Analytics** (`AADServicePrincipalSignInLogs`) | Último sign-in | Dado fresco em minutos, sem latência |

O cruzamento por `AppId` produz a classificação correta, mesmo no dia em que um app loga pela primeira vez.

---

## 📦 Pré-requisitos

| Item | Requisito |
|---|---|
| Licença Entra ID | **P1 ou P2** (para `signInActivity` e logs de sign-in de SP) |
| Subscription Azure | Com permissão para criar Automation Account e Log Analytics |
| Conta executora | **Privileged Role Administrator** (ou Global Admin) para criar o SP e conceder permissões + **Owner/User Access Administrator** na subscription para o RBAC no workspace |
| Mailbox de envio | Caixa Exchange Online com licença ativa (E1/E3/E5 ou Exchange Plan) |
| Domínio | Verificado no tenant (recomendado configurar SPF/DKIM/DMARC para entrega) |

---

## 🚀 Guia de implantação

A implantação tem **passos comuns** (1 a 4), depois você segue **uma das duas trilhas** (A ou B), e por fim os **passos finais comuns**.

### Passos comuns

#### 1. Diagnostic Setting do Entra ID

No portal: **Microsoft Entra ID → Monitoring → Diagnostic settings → Add diagnostic setting**. Marque:

- ✅ `AuditLogs`
- ✅ `SignInLogs`
- ✅ `ServicePrincipalSignInLogs`
- ✅ `MicrosoftServicePrincipalSignInLogs`

Destination: **Send to Log Analytics workspace**.

> Os logs só começam a fluir após o **Save**. As tabelas nascem no Log Analytics **no primeiro evento ingerido**.

#### 2. Workspace Log Analytics

Ajuste a **retenção** para cobrir sua janela de análise (≥ 90 dias para análise de 90 dias). Anote o **Workspace ID (Customer ID)**:

```powershell
$ws = Get-AzOperationalInsightsWorkspace | Where-Object { $_.Name -eq "SEU_WORKSPACE" }
$ws.CustomerId.Guid
```

#### 3. App Registration + Service Principal + permissões

Crie o Automation Account (**Create a resource → Automation**) — ele apenas hospeda o Runbook, **não** precisa de Managed Identity.

Rode [`01-grant-permissions.ps1`](01-grant-permissions.ps1) (Cloud Shell ou PowerShell local autenticado). Ele cria o App Registration + SP, concede os 4 AppRoles de aplicação (com admin consent) e o RBAC `Log Analytics Reader`.

- **Trilha A (Secret):** deixe `$gerarSecret = $true` (padrão). O script imprime o secret no resumo.
- **Trilha B (Certificado):** defina `$gerarSecret = $false`. Nenhum secret é gerado; o certificado virá no passo 01b.

**Anote o resumo impresso** (TenantId, ClientId, SP ObjectId, Workspace ID, e o secret se Trilha A).

**Tabela de permissões concedidas:**

| Permissão | Tipo | Para que serve |
|---|---|---|
| `Application.Read.All` | Graph (App) | Ler inventário de App Registrations |
| `AuditLog.Read.All` | Graph (App) | Ler logs de auditoria |
| `Directory.Read.All` | Graph (App) | Ler service principals |
| `Mail.Send` | Graph (App) | Enviar e-mail via Graph |
| `Log Analytics Reader` | RBAC (workspace) | Executar queries KQL no workspace |

#### 4. Módulos do PowerShell

O Runbook depende de dois módulos, **na ordem**, no runtime **7.2**:

1. `Microsoft.Graph.Authentication`
2. `Microsoft.Graph.Applications`

No portal: **Automation Account → Modules → Add a module → Browse from gallery**. Ou via Cloud Shell com [`02-import-modules.ps1`](02-import-modules.ps1) (mais confiável se a galeria der "Loading failed").

---

### Trilha A — Client Secret

Use quando quer o caminho mais simples (labs, POCs, primeira implantação).

1. Garanta que o passo 3 rodou com `$gerarSecret = $true` e que você anotou o **ClientSecret**.
2. Grave a configuração no Automation com [`03-configurar-automation-sp.ps1`](03-configurar-automation-sp.ps1):

```powershell
Set-AutoVar -Name "AppGov-TenantId"     -Value $tenantId            -Encrypted $false
Set-AutoVar -Name "AppGov-ClientId"     -Value $clientId            -Encrypted $false
Set-AutoVar -Name "AppGov-WorkspaceId"  -Value $workspaceCustomerId -Encrypted $false
Set-AutoVar -Name "AppGov-AuthMode"     -Value "Secret"             -Encrypted $false
Set-AutoVar -Name "AppGov-ClientSecret" -Value $clientSecret        -Encrypted $true   # ENCRIPTADA
```

| Automation Variable | Encriptada? | Conteúdo |
|---|---|---|
| `AppGov-TenantId` | Não | GUID do tenant |
| `AppGov-ClientId` | Não | AppId do Service Principal |
| `AppGov-WorkspaceId` | Não | Customer ID do workspace |
| `AppGov-AuthMode` | Não | `Secret` |
| `AppGov-ClientSecret` | **Sim** | Valor do client secret |

Pronto — siga para os [passos finais comuns](#passos-finais-comuns).

---

### Trilha B — Certificado

Use em produção. Sem segredo em texto; a chave privada nunca trafega.

1. Garanta que o passo 3 rodou com `$gerarSecret = $false`.
2. **Gere e registre o certificado** com [`01b-criar-certificado.ps1`](01b-criar-certificado.ps1), na **mesma sessão** do Graph (cria cert self-signed, registra a chave pública no App Registration e exporta o `.pfx`):

```powershell
# Resumo do que o 01b faz:
$cert = $req.CreateSelfSigned($notBefore, $notAfter)              # par RSA 2048 + cert
Update-MgApplication -ApplicationId $app.Id -KeyCredentials @($keyCredential)  # chave publica no app
$cert.Export([X509ContentType]::Pfx, $pfxPassword)               # .pfx com chave privada
```

3. **Suba o `.pfx` e grave a configuração** com [`03b-configurar-automation-cert.ps1`](03b-configurar-automation-cert.ps1):

```powershell
New-AzAutomationCertificate -ResourceGroupName $rg -AutomationAccountName $aa `
    -Name "AppGov-Cert" -Path "./AppGov-Cert.pfx" -Password $pfxPassword -Exportable

Set-AutoVar -Name "AppGov-TenantId"    -Value $tenantId            -Encrypted $false
Set-AutoVar -Name "AppGov-ClientId"    -Value $clientId            -Encrypted $false
Set-AutoVar -Name "AppGov-WorkspaceId" -Value $workspaceCustomerId -Encrypted $false
Set-AutoVar -Name "AppGov-AuthMode"    -Value "Certificate"        -Encrypted $false
```

| Asset / Variable | Tipo | Conteúdo |
|---|---|---|
| `AppGov-Cert` | Automation Certificate | `.pfx` (chave privada) |
| `AppGov-TenantId` | Variable | GUID do tenant |
| `AppGov-ClientId` | Variable | AppId do Service Principal |
| `AppGov-WorkspaceId` | Variable | Customer ID do workspace |
| `AppGov-AuthMode` | Variable | `Certificate` |

4. **Apague o `.pfx` local** após o upload. A única cópia persistida fica no Automation Account.

Siga para os [passos finais comuns](#passos-finais-comuns).

---

### Passos finais comuns

#### 5. Importar o Runbook

No Automation Account: **Runbooks → Create a runbook** — Name `RB_AppsInativos`, type PowerShell, runtime **7.2**. Cole [`RB_AppsInativos.ps1`](RB_AppsInativos.ps1) e **Publish**.

Com as Automation Variables criadas (Trilha A ou B), **não é preciso editar nada** — o runbook resolve tudo (inclusive o `AuthMode`) via `Get-AutomationVariable`. Os parâmetros existem para sobrescrever pontualmente:

```powershell
param(
    [int]    $DiasSemUso        = 90,
    [string] $AuthMode          = "",   # vazio => AppGov-AuthMode (Secret/Certificate)
    [string] $TenantId          = "<TENANT_ID>",
    [string] $ClientId          = "<CLIENT_ID_DO_SERVICE_PRINCIPAL>",
    [string] $ClientSecret      = "",                       # AuthMode=Secret
    [string] $SecretVariableName = "AppGov-ClientSecret",
    [string] $CertificateName   = "AppGov-Cert",            # AuthMode=Certificate
    [string] $CertificateThumbprint = "",                   # fallback fora do Automation
    [string] $WorkspaceId       = "<WORKSPACE_CUSTOMER_ID>",
    [string] $Remetente         = "automation@suaempresa.com",
    [string] $Destinatario      = "admins@suaempresa.com"
)
```

#### 6. Validação no Test Pane

**Test pane → Start.** Saída esperada (em ordem):

```
Configuracao resolvida. AuthMode: Secret | Tenant: ... | ClientId: ...
Conectado ao Microsoft Graph como Service Principal (app-only).
Log Analytics: ultimo login carregado para N apps.
Inventario: N app registrations.
Inativos ou nunca logados: X de Y apps.
CSV gerado: X linhas, N bytes.
DEBUG body length: NNNN chars
Email enviado para admins@suaempresa.com com anexo apps-inativos-YYYYMMDD.csv.
```

(`AuthMode: Certificate` se você seguiu a Trilha B.) Confira o inbox e a pasta de spam.

#### 7. Agendamento

**Schedules → Add a schedule** (ex.: semanal, segunda 08h) e **Link to schedule** no Runbook. O relatório passa a ser disparado automaticamente.

---

## 🧠 Como o script funciona

Cada bloco do `RB_AppsInativos.ps1` tem uma responsabilidade isolada:

| Bloco | O que faz |
|---|---|
| **0. Resolve-Config** | Resolve TenantId/ClientId/WorkspaceId/AuthMode/credencial via parâmetro ou Automation Variable |
| **1a. New-ClientAssertion** | (cert) Monta e assina um JWT RS256 com a chave privada do certificado |
| **1b. Get-EntraToken** | Pega token de aplicação via `client_credentials` — `client_secret` ou `client_assertion` |
| **2. Connect-MgGraph (SP)** | App-only com `-ClientSecretCredential` (secret) ou `-Certificate` (cert) |
| **3. Token + Query KQL** | Token do Log Analytics via SP; `union` → último login por AppId |
| **4. Inventário** | `Get-MgApplication -All` traz todos os App Registrations + credenciais |
| **5. Classificação** | Cruza inventário com hash de sign-ins; define Status e Credencial |
| **6. HTML** | Monta body HTML com tabela colorida |
| **7. CSV em memória** | Gera CSV com separador `;` e BOM UTF-8 (Excel PT-BR friendly) |
| **8. Mensagem + anexo** | Monta o objeto `message` com o CSV em base64 |
| **9. sendMail via REST** | Pega **token fresco** do SP e envia; `Disconnect-MgGraph` no `finally` |

### Particularidades técnicas

**Secret vs Certificate — o que realmente muda?**
Apenas a "prova de identidade" enviada ao endpoint de token. No modo Secret, vai `client_secret=<valor>`. No modo Certificate, vai `client_assertion=<JWT>` + `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`. O JWT é assinado em RS256 com a chave privada do certificado (`New-ClientAssertion`), e o header inclui `x5t` (hash SHA-1 do cert) para o Azure AD localizar a chave pública registrada no app. Todo o resto do pipeline é idêntico.

**Por que client assertion em vez do módulo Az?**
Assinar a assertion diretamente (via `System.Security.Cryptography`) mantém o runbook **autossuficiente** — uma única função de token serve Graph e Log Analytics, sem depender do `Connect-AzAccount`/`Get-AzAccessToken`.

**Por que token fresco antes do `sendMail`?**
Garante que o token reflita a permissão `Mail.Send` mesmo que ela tenha propagado após a primeira conexão, evitando `403 Forbidden` por scope ausente.

**Por que serializar o body em bytes UTF-8?**
O `Invoke-RestMethod` com hashtable às vezes envia o body vazio em runtimes 7.x. Serializar em bytes UTF-8 garante JSON válido no Graph.

---

## 🩺 Resolução de problemas

Veja o catálogo completo em [`troubleshooting.md`](troubleshooting.md). Resumo:

| Sintoma | Causa provável | Solução |
|---|---|---|
| `Connect-MgGraph is not recognized` | Módulos não importados / runtime errado | Passo 4: runtime 7.2 e status Available |
| `AADSTS7000215: Invalid client secret` | Secret errado/expirado (Trilha A) | Gere novo secret e regrave a variável (`03`) |
| `AADSTS700027` / assertion inválida | Cert não registrado ou expirado (Trilha B) | Reexecute `01b`; confira `keyCredentials` do app |
| `Certificado nao encontrado` | Asset `AppGov-Cert` ausente | Rode `03b` para subir o `.pfx` |
| `AADSTS700016: application not found` | ClientId/TenantId incorretos | Confira `AppGov-ClientId` / `AppGov-TenantId` |
| `Configuracao ausente: ... Automation Variable` | Variáveis não criadas | Rode `03` (secret) ou `03b` (cert) |
| `sendMail` → `Forbidden` | `Mail.Send` sem consent / não propagou | Aguarde 15-30 min; confira o AppRole do SP |
| `sendMail` → `MailboxNotEnabledForRESTAPI` | Remetente sem licença Exchange | Atribua licença ou use outra caixa |
| Log Analytics → `Forbidden` | SP sem `Log Analytics Reader` | Reaplique o RBAC ao SP ObjectId |

---

## 🛡️ Boas práticas de produção

**Prefira a Trilha B (certificado) em produção.** Elimina o segredo em texto e a chave privada nunca trafega — só a assinatura. Migrar da Trilha A para a B é simples: rode `01b` + `03b` e mude `AppGov-AuthMode` para `Certificate` (o `03b` já faz isso).

**Rotação:** defina validade ≤12 meses (secret ou cert), monitore o vencimento e automatize a renovação. Credencial vencida derruba a automação silenciosamente — crie um alerta.

**Restringir `Mail.Send`:** aplique uma [Application Access Policy](https://learn.microsoft.com/en-us/graph/auth-limit-mailbox-access) no Exchange Online para limitar o SP a enviar **apenas** pela mailbox `automation@empresa.com`.

**Quarentena antes de excluir:** detecte (este Runbook) → **desative** (`Update-MgServicePrincipal -AccountEnabled:$false`) por 30 dias → **exclua** se ninguém reclamar.

**Excluir apps de sistema da análise:** filtre apps de plataforma (Microsoft/Office) pelo `publisherDomain` ou por whitelist.

**Monitoramento do próprio Runbook:** alerta no Azure Monitor para falhas do job.

**Versionamento via Source Control:** integre o Automation Account com este repositório (**Source Control**).

---

## 📁 Estrutura do repositório

```
entra-apps-inativos-service-principal/
├── README.md                          # este arquivo (duas alternativas de auth)
├── arquitetura.md                     # detalhes de design (secret e certificado)
├── troubleshooting.md                 # casos de erro estendidos
├── MIGRACAO-SP.md                     # guia de migração Managed Identity → Service Principal
├── RB_AppsInativos.ps1                # Runbook (AuthMode: Secret | Certificate)
├── 01-grant-permissions.ps1           # Cria App Reg + SP, concede permissões (+secret opcional)
├── 01b-criar-certificado.ps1          # [Trilha B] Gera cert e registra no App Registration
├── 02-import-modules.ps1              # Importa módulos Graph (runtime 7.2)
├── 03-configurar-automation-sp.ps1    # [Trilha A] Grava config + secret encriptado
├── 03b-configurar-automation-cert.ps1 # [Trilha B] Sobe o .pfx + grava config (AuthMode=Certificate)
├── 99-teste-app-login.ps1             # Gera sign-ins de teste (popula logs)
└── .gitignore
```

---

## 📄 Licença

MIT — use, modifique e distribua livremente. Sem garantias.

---

## 🤝 Contribuindo

Pull requests são bem-vindos. Para mudanças significativas, abra uma issue primeiro.

**Áreas de melhoria conhecidas:**

- Filtro de apps de sistema (publisher Microsoft)
- Suporte a múltiplos destinatários e grupos do M365
- Tabela em Application Insights / Workbook do Sentinel
- Variant que **desativa automaticamente** apps com >180 dias inativos
