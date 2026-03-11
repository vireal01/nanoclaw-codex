#!/usr/bin/env bash
set -euo pipefail

# Bootstrap NanoClaw on a remote Linux server using an outer Docker container
# that controls the host Docker daemon via /var/run/docker.sock.
#
# Run from the repository root:
#   bash ./bootstrap-remote-docker.sh
#
# What it does:
# - installs Docker on the host if missing
# - creates a placeholder .env if missing
# - generates helper files under .nanoclaw-remote/
# - builds the outer NanoClaw host container image
# - starts or replaces the running NanoClaw host container

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$PROJECT_ROOT/.nanoclaw-remote"
LOG_DIR="$DEPLOY_DIR/logs"
DOCKERFILE_REMOTE="$DEPLOY_DIR/Dockerfile.remote"
ENTRYPOINT_REMOTE="$DEPLOY_DIR/entrypoint.sh"
ENV_FILE="$PROJECT_ROOT/.env"

CONTAINER_NAME="${NANOCLAW_REMOTE_CONTAINER_NAME:-nanoclaw-remote}"
IMAGE_NAME="${NANOCLAW_REMOTE_IMAGE_NAME:-nanoclaw-remote-host:latest}"

CODEX_HOME_DIR="$DEPLOY_DIR/codex-home"
CLAUDE_HOME_DIR="$DEPLOY_DIR/claude-home"
NPM_CACHE_DIR="$DEPLOY_DIR/npm-cache"
NODE_MODULES_DIR="$DEPLOY_DIR/node_modules"

CREATED_ENV_TEMPLATE="false"
DOCKER_CMD=(docker)

log() {
  printf '[bootstrap-remote] %s\n' "$*"
}

die() {
  printf '[bootstrap-remote] ERROR: %s\n' "$*" >&2
  exit 1
}

require_repo_root() {
  [ -f "$PROJECT_ROOT/package.json" ] || die "Run this script from the NanoClaw repository root."
  [ -d "$PROJECT_ROOT/container" ] || die "Repository layout looks wrong: missing ./container"
}

detect_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    return
  fi

  die "This script needs root or sudo to install/start Docker."
}

ensure_linux() {
  case "$(uname -s)" in
    Linux) ;;
    *)
      die "This bootstrap script targets Linux servers."
      ;;
  esac
}

ensure_curl() {
  if command -v curl >/dev/null 2>&1; then
    return
  fi

  log "curl not found; installing it"

  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update
    $SUDO apt-get install -y curl ca-certificates
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y curl ca-certificates
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y curl ca-certificates
    return
  fi

  die "curl is required, and no supported package manager was found to install it."
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed"
  else
    log "Docker not found; installing via the official convenience script"
    ensure_curl
    curl -fsSL https://get.docker.com | $SUDO sh
  fi

  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now docker || true
  elif command -v service >/dev/null 2>&1; then
    $SUDO service docker start || true
  fi

  configure_docker_command
  "${DOCKER_CMD[@]}" info >/dev/null 2>&1 || die "Docker is installed but not reachable. Check that the daemon is running."
}

configure_docker_command() {
  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
    return
  fi

  if [ -n "${SUDO:-}" ] && $SUDO docker info >/dev/null 2>&1; then
    DOCKER_CMD=($SUDO docker)
    return
  fi

  die "Docker is installed but neither 'docker' nor 'sudo docker' is usable by this shell."
}

prepare_directories() {
  mkdir -p "$DEPLOY_DIR" "$LOG_DIR"
  mkdir -p "$CODEX_HOME_DIR" "$CLAUDE_HOME_DIR" "$NPM_CACHE_DIR" "$NODE_MODULES_DIR"
}

create_env_template_if_needed() {
  if [ -f "$ENV_FILE" ]; then
    log ".env already exists; leaving it untouched"
    return
  fi

  cat > "$ENV_FILE" <<'EOF'
# NanoClaw runtime
AGENT_PROVIDER=codex
ASSISTANT_NAME=Andy
ASSISTANT_HAS_OWN_NUMBER=false
CONTAINER_IMAGE=nanoclaw-agent:latest

# Codex / OpenAI
OPENAI_API_KEY=
OPENAI_BASE_URL=

# Claude / Anthropic
ANTHROPIC_API_KEY=
CLAUDE_CODE_OAUTH_TOKEN=
ANTHROPIC_AUTH_TOKEN=
ANTHROPIC_BASE_URL=

# Optional channel credentials
TELEGRAM_BOT_TOKEN=
SLACK_BOT_TOKEN=
SLACK_APP_TOKEN=
DISCORD_BOT_TOKEN=
EOF

  CREATED_ENV_TEMPLATE="true"
  log "Created .env template with placeholders: $ENV_FILE"
}

write_entrypoint() {
  cat > "$ENTRYPOINT_REMOTE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd /app

echo "[remote-entrypoint] installing dependencies"
npm ci

echo "[remote-entrypoint] building app"
npm run build

echo "[remote-entrypoint] building agent container image"
npm run setup -- --step container --runtime docker

echo "[remote-entrypoint] starting NanoClaw"
exec npm start
EOF

  chmod +x "$ENTRYPOINT_REMOTE"
}

write_dockerfile() {
  cat > "$DOCKERFILE_REMOTE" <<'EOF'
FROM node:22-bookworm

RUN apt-get update && apt-get install -y \
    bash \
    ca-certificates \
    curl \
    docker.io \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @openai/codex @anthropic-ai/claude-code

WORKDIR /app

COPY .nanoclaw-remote/entrypoint.sh /bootstrap/entrypoint.sh
RUN chmod +x /bootstrap/entrypoint.sh

CMD ["/bootstrap/entrypoint.sh"]
EOF
}

build_outer_image() {
  log "Building outer image: $IMAGE_NAME"
  "${DOCKER_CMD[@]}" build -f "$DOCKERFILE_REMOTE" -t "$IMAGE_NAME" "$PROJECT_ROOT"
}

stop_existing_container() {
  if "${DOCKER_CMD[@]}" ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    log "Removing existing container: $CONTAINER_NAME"
    "${DOCKER_CMD[@]}" rm -f "$CONTAINER_NAME" >/dev/null
  fi
}

start_outer_container() {
  local -a run_args
  run_args=(
    run -d
    --name "$CONTAINER_NAME"
    --restart unless-stopped
    --workdir /app
    -e CODEX_HOME=/root/.codex
    -v "$PROJECT_ROOT:/app"
    -v "$NODE_MODULES_DIR:/app/node_modules"
    -v "$NPM_CACHE_DIR:/root/.npm"
    -v "$CODEX_HOME_DIR:/root/.codex"
    -v "$CLAUDE_HOME_DIR:/root/.claude"
    -v /var/run/docker.sock:/var/run/docker.sock
  )

  if [ -f "$ENV_FILE" ]; then
    run_args+=(--env-file "$ENV_FILE")
  fi

  run_args+=("$IMAGE_NAME")

  log "Starting outer container: $CONTAINER_NAME"
  "${DOCKER_CMD[@]}" "${run_args[@]}" >/dev/null
}

show_next_steps() {
  echo
  log "NanoClaw bootstrap finished."
  echo
  echo "Container name: $CONTAINER_NAME"
  echo "Outer image:     $IMAGE_NAME"
  echo "Project root:    $PROJECT_ROOT"
  echo
  echo "Useful commands:"
  echo "  docker logs -f $CONTAINER_NAME"
  echo "  docker exec -it $CONTAINER_NAME bash"
  echo "  docker exec -it $CONTAINER_NAME codex"
  echo

  if [ "$CREATED_ENV_TEMPLATE" = "true" ]; then
    echo "A placeholder .env was created. Fill in the values you need, then restart the container:"
    echo "  ${EDITOR:-nano} $ENV_FILE"
    echo "  docker restart $CONTAINER_NAME"
    echo
  fi

  if grep -Eq '^AGENT_PROVIDER=codex$' "$ENV_FILE" 2>/dev/null; then
    if ! grep -Eq '^OPENAI_API_KEY=.+$' "$ENV_FILE" 2>/dev/null; then
      echo "Codex mode is enabled and OPENAI_API_KEY is empty."
      echo "You can either set OPENAI_API_KEY in .env or log in interactively:"
      echo "  docker exec -it $CONTAINER_NAME bash"
      echo "  codex login"
      echo
    fi
  fi

  if grep -Eq '^AGENT_PROVIDER=claude$' "$ENV_FILE" 2>/dev/null; then
    echo "Claude mode is enabled."
    echo "Make sure .env contains ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN before first real use."
    echo
  fi
}

main() {
  require_repo_root
  ensure_linux
  detect_sudo
  install_docker_if_needed
  prepare_directories
  create_env_template_if_needed
  write_entrypoint
  write_dockerfile
  build_outer_image
  stop_existing_container
  start_outer_container
  show_next_steps
}

main "$@"
