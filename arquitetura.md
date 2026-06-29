# Arquitetura — Detecção de Apps Inativos no Entra ID

Este documento descreve as decisões de design e os trade-offs por trás da implementação.

## Problema

App Registrations no Entra ID acumulam ao longo do tempo. Apps esquecidas com credenciais expiradas representam:

- **Vetor de ataque:** secrets vazados podem ser explorados; quanto mais apps ativas, maior a superfície.
- **Ruído operacional:** alertas de credenciais expirando em apps que ninguém usa.
- **Risco de auditoria:** controles de governança (ISO 27001, SOC 2) exigem revisão periódica de identidades.

A demanda é detectar candidatos a remoção **automaticamente** e notificar o time de identidade.

## Alternativas consideradas

### A) KQL puro no Log Analytics

**Como funciona:** query KQL sobre `AADServicePrincipalSignInLogs` lista apps sem sign-ins na janela.

**Por que rejeitamos:** o Log Analytics só conhece apps que **logaram desde que a Diagnostic Setting foi habilitada**. Apps abandonados há meses (justamente os candidatos óbvios) ficam invisíveis. Além disso, a retenção do workspace limita a janela máxima de análise.

### B) Graph puro com `servicePrincipalSignInActivities`

**Como funciona:** endpoint `/reports/servicePrincipalSignInActivities` traz o último sign-in agregado por app.

**Por que rejeitamos:** o relatório é **eventualmente consistente** e tem atraso de horas a dias. Sign-ins recentes não aparecem, gerando falsos positivos ("Nunca logou" para apps que acabaram de logar).

### C) Híbrido (escolhido)

**Como funciona:**
1. **Inventário** via `Get-MgApplication` — completo, em tempo real.
2. **Último sign-in** via Log Analytics — dado fresco em minutos.
3. **Cruzamento** por `AppId` na execução.

**Vantagens:**
- Vê apps que nunca logaram (do inventário).
- Dado de sign-in fresco (do LA).
- Resiliente a falhas: se o LA estiver fora, o Graph ainda lista o inventário (apenas perde a precisão temporal).

## Fluxo de execução do Runbook

```
┌─────────────────────────────────────────────────────────┐
│ 0. Resolve-Config                                       │
│    TenantId/ClientId/WorkspaceId/Secret via parametro   │
│    ou Automation Variable (secret encriptado)           │
└────────────────────────┬────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────┐
│ 1. Connect-MgGraph (app-only)                           │
│    Secret: -ClientSecretCredential                      │
│    Cert:   -ClientId -Certificate                       │
└────────────────────────┬────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────┐
│ 2. Token Log Analytics via client_credentials           │
│    Secret: client_secret=...                            │
│    Cert:   client_assertion=<JWT RS256>                 │
│    scope = https://api.loganalytics.io/.default         │
└────────────────────────┬────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────┐
│ 3. Query KQL via REST                                   │
│    POST /v1/workspaces/{id}/query                       │
│    union AADServicePrincipalSignInLogs + SigninLogs     │
│    → hash @{AppId = UltimoLogin}                        │
└────────────────────────┬────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────┐
│ 4. Get-MgApplication -All                               │
│    Inventário completo + credenciais                    │
└────────────────────────┬────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────┐
│ 5. Classificação                                        │
│    Para cada app, cruza com hash de sign-ins:           │
│      - $null         → "Nunca logou"                    │
│      - < dataCorte   → "Inativo (>N d)"                 │
│      - >= dataCorte  → "Ativo"                          │
└────────────────────────┬────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────┐
│ 6. Filtro + ordenação                                   │
│    Status != "Ativo" → candidatos                       │
└────────────────────────┬────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────┐
│ 7. Geração de HTML + CSV (BOM UTF-8, separador ;)       │
└────────────────────────┬────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────┐
│ 8. Token Graph fresco (client_credentials) + sendMail   │
│    (token fresco evita 403 por scope ausente em cache)  │
└─────────────────────────────────────────────────────────┘
```

## Por que Service Principal em vez de Managed Identity?

A versão original autenticava com a **Managed Identity** do Automation Account, obtendo tokens via as variáveis `IDENTITY_ENDPOINT` / `IDENTITY_HEADER` injetadas no sandbox. Funciona bem, mas amarra a automação ao recurso Azure que hospeda a identity.

O **Service Principal** (App Registration + client credentials) é **portátil**: o mesmo runbook autentica de qualquer lugar — Azure Automation, GitHub Actions, container, PowerShell local — bastando fornecer `TenantId`, `ClientId` e `ClientSecret` (ou certificado).

| Aspecto | Managed Identity | Service Principal |
|---|---|---|
| Portabilidade | Só no recurso que a hospeda | Qualquer host |
| Gestão de segredo | Nenhuma (o Azure cuida) | Rotação do secret/cert é responsabilidade sua |
| Obtenção de token | `IDENTITY_ENDPOINT` (só no sandbox) | `client_credentials` em qualquer ambiente |
| Onde guardar credencial | N/A | Automation Variable encriptada / Key Vault |

O trade-off é claro: ganha-se portabilidade, assume-se a gestão do ciclo de vida do segredo. Para mitigar, o secret nunca fica em código — vai para uma **Automation Variable encriptada** (e, idealmente, um certificado em produção).

## Por que `client_credentials` via REST para os tokens?

Tanto o token do Log Analytics quanto o do `sendMail` são obtidos diretamente no endpoint de token do Entra:

```
POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
grant_type=client_credentials
client_id={appId}
client_secret={secret}
scope={recurso}/.default
```

Uma única função (`Get-EntraToken -Resource`) serve a qualquer recurso (Graph, Log Analytics), desacoplando a obtenção de token do cache do `Connect-MgGraph`.

## Duas alternativas de credencial: secret vs certificado

O Service Principal pode provar identidade de duas formas. **Apenas a prova muda** — todo o pipeline (KQL, inventário, classificação, envio) é idêntico.

| Aspecto | Client Secret (`AuthMode=Secret`) | Certificado (`AuthMode=Certificate`) |
|---|---|---|
| O que vai no corpo do token | `client_secret=<valor>` | `client_assertion=<JWT>` + `client_assertion_type=...jwt-bearer` |
| Connect-MgGraph | `-ClientSecretCredential` | `-ClientId -Certificate` |
| Armazenamento | Automation Variable encriptada | Automation Certificate asset (.pfx) |
| Segurança | Segredo encriptado em repouso | Sem segredo em texto; só a assinatura trafega |
| Indicação | Labs, POCs, início rápido | Produção, compliance |

### Como funciona o client assertion (modo certificado)

No fluxo `client_credentials` com certificado, o SP não envia um segredo — envia um **JWT assinado** pela chave privada, que o Azure AD valida contra a **chave pública** registrada no App Registration (`keyCredentials`).

Estrutura do JWT (`New-ClientAssertion`):

```
header  = { alg: "RS256", typ: "JWT", x5t: <base64url(SHA1 do cert)> }
payload = { aud: <token endpoint>, iss: <clientId>, sub: <clientId>,
            jti: <guid>, nbf: <agora>, exp: <agora+10min> }
assinatura = RS256( base64url(header) + "." + base64url(payload), chavePrivada )
client_assertion = base64url(header).base64url(payload).base64url(assinatura)
```

- `x5t` permite ao Azure AD identificar **qual** chave pública usar para verificar.
- A chave privada **nunca** sai do runbook; só a assinatura vai na requisição.
- A assinatura usa `System.Security.Cryptography` (RSA + SHA256), sem dependência do módulo Az — o runbook permanece autossuficiente.

### Ciclo de vida do certificado

```
01b: gera par RSA 2048 + cert self-signed
        │
        ▼  chave publica
App Registration.keyCredentials  ◄── Azure AD valida a assertion contra esta chave
        │
        ▼  chave privada (.pfx)
03b: Automation Certificate asset  ◄── runbook le via Get-AutomationCertificate
```

Em produção, a renovação substitui o cert no app (`keyCredentials`) e o asset no Automation Account. Mantenha validade ≤12 meses e monitore o vencimento.

## Por que pegar token Graph fresco antes do `sendMail`?

O `Connect-MgGraph` cacheia o token da conexão. Se `Mail.Send` foi concedida (ou propagou) **depois** do primeiro `Connect`, o token em cache pode não ter o scope, e o Graph retorna `403 Forbidden / ErrorAccessDenied`.

A solução é pegar o token **diretamente** via `client_credentials` no momento do envio. Esse token é emitido fresco e reflete todas as permissões atuais do Service Principal.

## Por que serializar o body em bytes UTF-8?

`Invoke-RestMethod` com hashtable `-Body` em runtimes PowerShell 7.x pode enviar payload vazio em algumas combinações de header. O Graph então responde:

```
{"error":{"code":"BadRequest","message":"Empty Payload. JSON content expected."}}
```

Serializar explicitamente para `[byte[]]` em UTF-8 garante que o body chegue como conteúdo binário válido. É a recomendação para chamadas POST com JSON ao Graph quando há anexos.

## Por que CSV com BOM UTF-8 e separador `;`?

- **BOM UTF-8 (`0xFEFF`):** Excel reconhece o encoding e exibe acentos corretamente. Sem BOM, nomes como "Configuração" viram "ConfiguraÃ§Ã£o".
- **Separador `;`:** versões PT-BR do Excel usam `;` como delimitador padrão. Com `,`, o Excel coloca tudo numa coluna só e o usuário precisa usar "Texto para Colunas".

## Estratégia de quarentena (recomendado para produção)

O Runbook **apenas detecta**. A exclusão deve ser separada para evitar quebras irreversíveis:

```
Detecção (Runbook semanal)
        │
        ▼
Notificação por email aos proprietários
        │
        ▼
Quarentena (Disabled) por 30 dias
        │
        ▼
Validação: ninguém reclamou?
        │
        ▼
Remoção definitiva
```

Apps em quarentena podem ser revertidos imediatamente se quebrar algo. Apps excluídos exigem recriação + reconfiguração de tudo que dependia deles.

## Métricas para monitorar

Em maturidade alta, monitore via Application Insights / Workbook do Sentinel:

- **Total de apps no tenant** ao longo do tempo (tendência: deve estabilizar ou diminuir após implantação).
- **Apps com credencial expirada** (deve tender a zero).
- **Apps inativos >90d** (KPI principal de higiene).
- **Tempo entre detecção e remoção** (eficiência do processo).
