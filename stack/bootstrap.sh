#!/usr/bin/env bash
# Stack global de IA para Claude Code: rtk + caveman (só skill) + claude-mem (local).
# Uso: ./bootstrap.sh [--check] [--dry-run]
set -euo pipefail

RTK_VERSION="v0.51.0"
CAVEMAN_REF="v3.1.0"
CLAUDE_MEM_VERSION="13.28.0"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
RTK_BIN_DIR="${RTK_INSTALL_DIR:-$HOME/.local/bin}"
CLAUDE_MEM_DIR="${CLAUDE_MEM_DATA_DIR:-$HOME/.claude-mem}"

MODE=install
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) echo "argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done

export PATH="$RTK_BIN_DIR:$PATH"
# Sem isso o `rtk init` pode travar esperando resposta de telemetria num pseudo-TTY.
export RTK_TELEMETRY_DISABLED=1
export CLAUDE_MEM_ONLINE_OPTIN=false

info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[aviso]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31m[falha]\033[0m %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1; }

run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

rtk_version() { rtk --version 2>/dev/null | awk '{print $2}'; }

claude_mem_telemetry_off() {
  [ -f "$CLAUDE_MEM_DIR/telemetry.json" ] && grep -Eq '"enabled" *: *false' "$CLAUDE_MEM_DIR/telemetry.json"
}

plugin_installed() {
  if need claude; then
    claude plugin list 2>/dev/null | grep -qi "$1"
  else
    [ -d "$CLAUDE_DIR/plugins/marketplaces/$2" ]
  fi
}

install_rtk() {
  local want="${RTK_VERSION#v}"
  if need rtk && [ "$(rtk_version)" = "$want" ] && rtk gain >/dev/null 2>&1; then
    info "rtk $want já instalado"
  else
    info "instalando rtk $want em $RTK_BIN_DIR (binário verificado por SHA-256)"
    run sh -c "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/$RTK_VERSION/install.sh | RTK_VERSION=$RTK_VERSION RTK_INSTALL_DIR='$RTK_BIN_DIR' sh"
  fi
  run rtk telemetry disable
  # --hook-only: reescreve comandos sem injetar RTK.md no CLAUDE.md global (zero token de contexto).
  run rtk init -g --hook-only --auto-patch </dev/null
}

install_caveman() {
  if ! need claude; then
    warn "CLI 'claude' fora do PATH; caveman pulado. Instale com: npm i -g @anthropic-ai/claude-code"
    return 0
  fi
  info "instalando caveman $CAVEMAN_REF (só plugin/skill: sem proxy, sem MCP shrink, sem hooks avulsos)"
  run npx -y "github:JuliusBrussee/caveman#$CAVEMAN_REF" -- --only claude --minimal --non-interactive
}

install_claude_mem() {
  if plugin_installed claude-mem thedotmack; then
    info "claude-mem já instalado"
  else
    info "instalando claude-mem $CLAUDE_MEM_VERSION (provider=claude, sem nuvem cmem, memória nativa mantida)"
    # stdin fora do TTY força o caminho não interativo, que mantém a auto-memória nativa ligada.
    run npx -y "claude-mem@$CLAUDE_MEM_VERSION" install --ide claude-code --provider claude </dev/null
  fi
  if ! claude_mem_telemetry_off; then
    run npx -y "claude-mem@$CLAUDE_MEM_VERSION" telemetry disable </dev/null
  fi
}

check_all() {
  local ok=0

  if need rtk && rtk gain >/dev/null 2>&1; then
    info "ok: rtk $(rtk_version)"
  else
    fail "rtk ausente, ou é o 'Rust Type Kit' (projeto homônimo errado)"; ok=1
  fi

  if [ -f "$SETTINGS" ] && grep -Eq 'rtk.* hook claude' "$SETTINGS"; then
    info "ok: hook do rtk registrado em $SETTINGS"
  else
    fail "hook 'rtk hook claude' ausente em $SETTINGS"; ok=1
  fi

  if plugin_installed caveman caveman; then
    info "ok: plugin caveman"
  else
    fail "plugin caveman não instalado"; ok=1
  fi

  if plugin_installed claude-mem thedotmack; then
    info "ok: plugin claude-mem"
  else
    fail "plugin claude-mem não instalado"; ok=1
  fi

  if [ -f "$SETTINGS" ] && grep -Eq 'ANTHROPIC_BASE_URL|_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL' "$SETTINGS"; then
    fail "settings.json redireciona a API (provável 'caveman enable'). Desfaça com: caveman disable --all"; ok=1
  else
    info "ok: chamadas de API vão direto para a Anthropic (sem proxy)"
  fi
  if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    warn "ANTHROPIC_BASE_URL definido no shell: $ANTHROPIC_BASE_URL"
  fi

  if [ -f "$SETTINGS" ] && grep -Eq '"CLAUDE_CODE_DISABLE_AUTO_MEMORY" *: *"1"' "$SETTINGS"; then
    fail "memória nativa do Claude Code desligada. Remova CLAUDE_CODE_DISABLE_AUTO_MEMORY do bloco env de $SETTINGS"; ok=1
  else
    info "ok: memória nativa do Claude Code ligada"
  fi

  if claude_mem_telemetry_off; then
    info "ok: telemetria do claude-mem desligada"
  else
    fail "telemetria do claude-mem não está desligada. Rode: npx claude-mem telemetry disable"; ok=1
  fi

  return $ok
}

if [ "$MODE" = check ]; then
  check_all
  exit $?
fi

need curl || { fail "curl é obrigatório"; exit 1; }
need npx || { fail "Node.js >= 20 é obrigatório (npx não encontrado)"; exit 1; }

install_rtk
install_caveman
install_claude_mem

if [ "$DRY_RUN" = 1 ]; then
  info "dry-run concluído; nada foi alterado"
  exit 0
fi

info "verificando..."
if check_all; then
  info "stack pronto. Reinicie o Claude Code para carregar os hooks."
else
  fail "instalação terminou com pendências (acima)"
  exit 1
fi
