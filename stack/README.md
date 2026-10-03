# Stack global de IA (rtk + caveman + claude-mem)

Um instalador único, idempotente e com versões fixadas, que deixa o Claude Code de qualquer máquina com:

| Camada | Ferramenta | O que faz | Hook no Claude Code |
|---|---|---|---|
| Entrada (saída de comandos) | **rtk** `v0.51.0` | Reescreve `git`, `npm`, `docker`, `pytest`… para versões compactas — 60–90% menos tokens | `PreToolUse` → `rtk hook claude` |
| Saída (respostas do agente) | **caveman** `v3.1.0` | Skill de resposta enxuta, sem perder termos técnicos, código e erros | `SessionStart`, `UserPromptSubmit` |
| Memória entre sessões | **claude-mem** `13.28.0` | Resume o que aconteceu e injeta nas sessões seguintes (SQLite + Chroma local) | hooks do plugin |

Vale para **todos os projetos** da máquina (escopo global em `~/.claude`), não para um repositório específico.

## Por que composição e não fusão de código

As três resolvem problemas diferentes e já se encaixam pelos hooks do Claude Code — não disputam o mesmo evento. Fundir o código (Rust + Go + TypeScript) num binário só criaria um fork difícil de manter contra um upstream que publica várias versões por semana, sem ganho de capacidade. Por isso esta pasta não toca em nada do código do rtk: o fork continua sincronizável com `rtk-ai/rtk` sem conflito.

## O que fica deliberadamente desligado

| O quê | Por quê |
|---|---|
| Proxy do caveman (`caveman enable`, `caveman-shrink`) | Reescreve `ANTHROPIC_BASE_URL` e passa as chamadas da API por um intermediário. A compressão de saída de comando já é do rtk. |
| Hooks avulsos e regras por repositório do caveman | `--minimal` instala só o plugin; nada é escrito dentro dos seus projetos. |
| Observer em nuvem do claude-mem (cmem) | `--provider claude` usa o seu próprio plano para gerar os resumos; os dados ficam em `~/.claude-mem`. |
| Desligar a memória nativa do Claude Code | O claude-mem oferece isso; aqui a memória nativa (`MEMORY.md`) continua ligada. |
| Telemetria do claude-mem (ligada por padrão) e do rtk | Desligadas explicitamente. |
| `RTK.md` no `CLAUDE.md` global | `--hook-only`: o rtk reescreve os comandos sem gastar tokens de contexto. |

## Uso

Pré-requisitos: Node.js ≥ 20, CLI do Claude Code no `PATH` (`npm i -g @anthropic-ai/claude-code` — necessário para instalar o plugin do caveman), `curl` (macOS/Linux).

### macOS / Linux

```bash
./stack/bootstrap.sh --dry-run   # mostra o que faria, sem alterar nada
./stack/bootstrap.sh             # instala e verifica
./stack/bootstrap.sh --check     # só verifica (exit 1 se houver pendência)
```

### Windows (PowerShell 5.1+)

```powershell
.\stack\bootstrap.ps1 -DryRun
.\stack\bootstrap.ps1
.\stack\bootstrap.ps1 -Check
```

O rtk é baixado direto da release do GitHub com verificação SHA-256 (o `winget` ainda não tem a `v0.51.0`) e instalado em `%USERPROFILE%\.local\bin`, que entra no `PATH` do usuário.

### Automático a cada logon (Windows)

```powershell
.\stack\bootstrap.ps1 -RegisterLogonTask
```

Copia o script para `%LOCALAPPDATA%\ia-stack\` e registra a tarefa `IA-Stack-Bootstrap`, que roda oculta a cada logon. Cada etapa pula o que já está certo, então numa máquina pronta a execução é rápida; numa máquina nova ou com o `settings.json` resetado, ela reinstala sozinha. Log em `%LOCALAPPDATA%\ia-stack\bootstrap.log`. Se o Windows recusar o registro por permissão, rode esse comando uma vez num PowerShell como administrador.

### Máquina nova

O único passo manual é trazer o script para a máquina. Depois disso, `-RegisterLogonTask` (Windows) ou o próprio `bootstrap.sh` cuidam do resto:

```powershell
git clone -b feature/stack-global-ia https://github.com/criandonegocioia/rtk.git $env:USERPROFILE\ia-stack-src
& $env:USERPROFILE\ia-stack-src\stack\bootstrap.ps1
& $env:USERPROFILE\ia-stack-src\stack\bootstrap.ps1 -RegisterLogonTask
```

## O que o `--check` verifica

- `rtk` instalado **e** é o Rust Token Killer (há um projeto homônimo, o Rust Type Kit, que não serve).
- `rtk hook claude` registrado no `settings.json`.
- Plugins `caveman` e `claude-mem` instalados.
- Nenhum `ANTHROPIC_BASE_URL` / `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL` no `settings.json` (sinal de proxy ativo).
- `CLAUDE_CODE_DISABLE_AUTO_MEMORY` **não** está ligado.
- Telemetria do claude-mem desligada.

Ele aponta o problema e o comando que corrige, mas não remove nada sozinho: um `ANTHROPIC_BASE_URL` pode ter sido colocado de propósito por outro motivo.

## Atualizar versões

Altere as três variáveis no topo de `bootstrap.sh` e `bootstrap.ps1` (`RTK_VERSION`, `CAVEMAN_REF`, `CLAUDE_MEM_VERSION`), rode `--dry-run` e depois a instalação numa máquina de teste antes de fazer merge.

Limitação conhecida: o instalador do caveman fica fixado em `v3.1.0`, mas o `claude plugin marketplace add` que ele executa sempre puxa o plugin da branch principal do caveman.

## Desinstalar

```bash
rtk init -g --uninstall
npx -y github:JuliusBrussee/caveman -- --uninstall
npx claude-mem uninstall
```

No Windows, remova também a tarefa: `Unregister-ScheduledTask -TaskName IA-Stack-Bootstrap -Confirm:$false`.

## Manter o fork em dia com o rtk original

```bash
git remote add upstream https://github.com/rtk-ai/rtk.git
git fetch upstream
git rebase upstream/develop
```

Como só a pasta `stack/` é nossa, o rebase não gera conflito.
