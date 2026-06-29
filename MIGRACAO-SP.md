# Migração: Managed Identity → Service Principal

Este documento resume o que mudou ao migrar a automação de **Managed Identity** para **Service Principal** (App Registration + client credentials) e a ordem de implantação para um novo tenant/ambiente.

## Por que migrar

| Motivo | Detalhe |
|---|---|
| Portabilidade | O mesmo runbook roda em Azure Automation, GitHub Actions ou PowerShell local |
| Independência do host | Não depende da Managed Identity de um recurso Azure específico |
| Padronização | Mesmo fluxo `client_credentials` para Graph e Log Analytics |

Trade-off assumido: passa a ser responsabilidade da equipe **gerenciar o ciclo de vida do secret** (rotação). Mitigado guardando o secret em Automation Variable encriptada (e, em produção, usando certificado).

## O que mudou no código

| Item | Antes (Managed Identity) | Depois (Service Principal) |
|---|---|---|
| Conexão Graph | `Connect-MgGraph -Identity` | `Connect-MgGraph -ClientSecretCredential` |
| Token Log Analytics | `IDENTITY_ENDPOINT` + `X-IDENTITY-HEADER` | `client_credentials` (`/oauth2/v2.0/token`) |
| Token sendMail | `IDENTITY_ENDPOINT` + `X-IDENTITY-HEADER` | `client_credentials` (token fresco) |
| Origem das credenciais | Identity do Automation Account | Automation Variables (`AppGov-*`), secret encriptado |
| Concessão de permissões | AppRoles na MI ObjectId | AppRoles no SP ObjectId (`01-grant-permissions.ps1`) |
| RBAC do workspace | `Log Analytics Reader` na MI | `Log Analytics Reader` no SP |

## Arquivos novos / alterados

| Arquivo | Status | Descrição |
|---|---|---|
| `RB_AppsInativos.ps1` | **Alterado (v2.1)** | Auth via SP com `AuthMode` Secret **ou** Certificate |
| `01-grant-permissions.ps1` | **Alterado** | Cria App Reg + SP, concede AppRoles; secret opcional (`$gerarSecret`) |
| `01b-criar-certificado.ps1` | **Novo** | [Trilha B] Gera cert self-signed e registra no App Registration |
| `03-configurar-automation-sp.ps1` | **Novo** | [Trilha A] Grava config + secret encriptado (`AppGov-AuthMode=Secret`) |
| `03b-configurar-automation-cert.ps1` | **Novo** | [Trilha B] Sobe o `.pfx` + grava config (`AppGov-AuthMode=Certificate`) |
| `MIGRACAO-SP.md` | **Novo** | Este guia |
| `.gitignore` | **Novo** | Protege secrets/certs de serem versionados |
| `02-import-modules.ps1` | Inalterado | Módulos Graph continuam os mesmos |
| `99-teste-app-login.ps1` | Inalterado | Geração de sign-ins de teste |
| `README.md` / `arquitetura.md` / `troubleshooting.md` | **Alterados** | Documentação das duas alternativas |

## Duas alternativas de autenticação

Após a migração, o repositório oferece **duas trilhas** para o mesmo Service Principal (detalhes no README):

- **Trilha A — Client Secret** (`AuthMode=Secret`): `01` (com secret) → `03`. Mais simples; ideal para começar.
- **Trilha B — Certificado** (`AuthMode=Certificate`): `01` (sem secret) → `01b` → `03b`. Recomendada em produção.

Trocar de A para B depois é simples: rode `01b` + `03b` (o `03b` ajusta `AppGov-AuthMode` para `Certificate`).

## Ordem de implantação (novo ambiente)

**Comum:**
1. **Diagnostic Setting** do Entra → Log Analytics (`SignInLogs`, `ServicePrincipalSignInLogs`, `AuditLogs`).
2. **Workspace Log Analytics** com retenção ≥ janela; anote o Customer ID.
3. **`01-grant-permissions.ps1`** → cria App Reg + SP, concede AppRoles + RBAC. (Trilha A: `$gerarSecret=$true`; Trilha B: `$gerarSecret=$false`.)
4. **Automation Account** + módulos Graph (runtime 7.2) via portal ou `02-import-modules.ps1`.

**Trilha A (Secret):**
5A. **`03-configurar-automation-sp.ps1`** → grava `AppGov-*` e `AppGov-ClientSecret` (encriptada).

**Trilha B (Certificado):**
5B. **`01b-criar-certificado.ps1`** → gera o cert e registra no app.
6B. **`03b-configurar-automation-cert.ps1`** → sobe o `.pfx` e grava config (`AuthMode=Certificate`).

**Comum (final):**
7. **Importar `RB_AppsInativos.ps1`** como Runbook PowerShell 7.2 e **Publish**.
8. **Test pane** → validar saída e recebimento do e-mail.
9. **Schedule** para execução recorrente.

## Rollback

Para voltar à Managed Identity, restaure a versão anterior dos scripts pelo histórico do Git (`git checkout <commit> -- RB_AppsInativos.ps1 01-grant-permissions.ps1`) e reative a System Assigned Identity no Automation Account. As Automation Variables `AppGov-*` podem ser removidas.

## Limpeza pós-migração

- Revogue secrets antigos não utilizados.
- Se a Managed Identity não for mais usada por nenhum runbook, desabilite-a no Automation Account.
- Confirme que nenhum secret foi commitado (o `.gitignore` cobre os padrões comuns).
