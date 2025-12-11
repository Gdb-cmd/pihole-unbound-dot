#!/bin/bash
# Interactive Update Manager with Logging and Automatic Rollback
# Universal version with auto-detection for portability
# Works across different machines, users, and deployments

# Safer error handling - don't exit on every error
set -o pipefail

# ============================================================================
# PHASE 0: DEPENDENCY CHECKS & AUTO-DETECTION
# ============================================================================

echo "════════════════════════════════════════════════════════════════"
echo "🔍 Phase 0: Dependency Checks & Environment Detection"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Check required commands
echo "📋 Checking required commands..."
MISSING_COMMANDS=()
REQUIRED_COMMANDS="docker docker-compose grep awk nslookup date hostname tee sed basename"

for cmd in $REQUIRED_COMMANDS; do
    if ! command -v $cmd >/dev/null 2>&1; then
        MISSING_COMMANDS+=("$cmd")
        echo "  ❌ Missing: $cmd"
    else
        echo "  ✅ Found: $cmd"
    fi
done

# Check Docker daemon is running
echo ""
echo "🐋 Checking Docker daemon..."
if docker ps >/dev/null 2>&1; then
    echo "  ✅ Docker daemon is running"
else
    echo "  ❌ Docker daemon is not running or not accessible"
    MISSING_COMMANDS+=("docker-daemon")
fi

# Check Docker Compose version (need v1.29+ for health check dependencies)
echo ""
echo "📦 Checking Docker Compose version..."
COMPOSE_VERSION=$(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
if [ -n "$COMPOSE_VERSION" ]; then
    COMPOSE_MAJOR=$(echo "$COMPOSE_VERSION" | cut -d. -f1)
    COMPOSE_MINOR=$(echo "$COMPOSE_VERSION" | cut -d. -f2)
    
    if [ "$COMPOSE_MAJOR" -ge 2 ] || ([ "$COMPOSE_MAJOR" -eq 1 ] && [ "$COMPOSE_MINOR" -ge 29 ]); then
        echo "  ✅ Docker Compose v$COMPOSE_VERSION (meets requirement: v1.29+)"
    else
        echo "  ⚠️  Docker Compose v$COMPOSE_VERSION (recommended: v1.29+)"
        echo "     Script may work but health check dependencies might not be supported"
    fi
else
    echo "  ⚠️  Could not determine Docker Compose version"
fi

# Report missing commands
echo ""
if [ ${#MISSING_COMMANDS[@]} -gt 0 ]; then
    echo "❌ ERROR: Missing required commands!"
    echo ""
    echo "Missing commands: ${MISSING_COMMANDS[*]}"
    echo ""
    echo "Installation instructions:"
    echo "────────────────────────────────────────────────────────────────"
    
    for missing in "${MISSING_COMMANDS[@]}"; do
        case $missing in
            docker)
                echo "  Docker:"
                echo "    curl -fsSL https://get.docker.com -o get-docker.sh"
                echo "    sudo sh get-docker.sh"
                echo "    sudo usermod -aG docker \$USER"
                echo ""
                ;;
            docker-compose)
                echo "  Docker Compose:"
                echo "    sudo apt-get update"
                echo "    sudo apt-get install docker-compose-plugin"
                echo "    # Or for standalone:"
                echo "    sudo curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose"
                echo "    sudo chmod +x /usr/local/bin/docker-compose"
                echo ""
                ;;
            docker-daemon)
                echo "  Docker Daemon:"
                echo "    sudo systemctl start docker"
                echo "    sudo systemctl enable docker"
                echo ""
                ;;
            nslookup)
                echo "  nslookup:"
                echo "    sudo apt-get install dnsutils"
                echo ""
                ;;
            *)
                echo "  $missing:"
                echo "    sudo apt-get install $missing"
                echo ""
                ;;
        esac
    done
    
    exit 1
fi

echo "✅ All dependencies satisfied!"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🔍 Auto-detecting environment..."
echo "════════════════════════════════════════════════════════════════"
echo ""

# Auto-detect project directory (works from any location)
if [ -f "docker-compose.yml" ] && [ -f "Dockerfile" ]; then
    PROJECT_DIR="$(pwd)"
    echo "✅ Detected project directory: $PROJECT_DIR (current directory)"
elif [ -f ~/gdb-pihole-unbound/docker-compose.yml ]; then
    PROJECT_DIR=~/gdb-pihole-unbound
    echo "✅ Detected project directory: $PROJECT_DIR (default location)"
else
    echo "❌ ERROR: Cannot find project directory!"
    echo "   Please run this script from the project directory or ensure"
    echo "   ~/gdb-pihole-unbound exists with docker-compose.yml"
    exit 1
fi

# Change to project directory
cd "$PROJECT_DIR" || exit 1

# Auto-detect container names from docker-compose.yml
echo "🔍 Detecting container names from docker-compose.yml..."
PIHOLE_CONTAINER=$(grep "container_name:" docker-compose.yml | grep pihole | awk '{print $2}' | head -1)
REDIS_CONTAINER=$(grep "container_name:" docker-compose.yml | grep redis | awk '{print $2}' | head -1)
UNBOUND_CONTAINER=$(grep "container_name:" docker-compose.yml | grep unbound | awk '{print $2}' | head -1)

echo "  Pi-hole container: $PIHOLE_CONTAINER"
echo "  Redis container: $REDIS_CONTAINER"
echo "  Unbound container: $UNBOUND_CONTAINER"

# Auto-detect service names from docker-compose.yml (FIX 1: More robust)
echo "🔍 Detecting service names from docker-compose.yml..."
PIHOLE_SERVICE=$(awk '/^  [a-z]/ {service=$1} /container_name.*pihole/ {gsub(/:/, "", service); print service; exit}' docker-compose.yml)
REDIS_SERVICE=$(awk '/^  [a-z]/ {service=$1} /container_name.*redis/ {gsub(/:/, "", service); print service; exit}' docker-compose.yml)
UNBOUND_SERVICE=$(awk '/^  [a-z]/ {service=$1} /container_name.*unbound/ {gsub(/:/, "", service); print service; exit}' docker-compose.yml)

echo "  Pi-hole service: $PIHOLE_SERVICE"
echo "  Redis service: $REDIS_SERVICE"
echo "  Unbound service: $UNBOUND_SERVICE"

# Auto-detect device IP
DEVICE_IP=$(hostname -I | awk '{print $1}')
echo "✅ Detected device IP: $DEVICE_IP"

# Auto-detect volume prefix
PROJECT_NAME=$(basename "$PROJECT_DIR")
VOLUME_PREFIX="${PROJECT_NAME}_"
echo "✅ Detected volume prefix: $VOLUME_PREFIX"

# Verify volumes exist
VOLUME_COUNT=$(docker volume ls | grep -c "$VOLUME_PREFIX" || echo "0")
echo "✅ Detected $VOLUME_COUNT Docker volumes with prefix: $VOLUME_PREFIX"

# Verify all required components detected
if [ -z "$PIHOLE_CONTAINER" ] || [ -z "$REDIS_CONTAINER" ] || [ -z "$UNBOUND_CONTAINER" ]; then
    echo ""
    echo "❌ ERROR: Could not detect all containers from docker-compose.yml!"
    echo "   Pi-hole: ${PIHOLE_CONTAINER:-NOT FOUND}"
    echo "   Redis: ${REDIS_CONTAINER:-NOT FOUND}"
    echo "   Unbound: ${UNBOUND_CONTAINER:-NOT FOUND}"
    exit 1
fi

if [ -z "$PIHOLE_SERVICE" ] || [ -z "$REDIS_SERVICE" ] || [ -z "$UNBOUND_SERVICE" ]; then
    echo ""
    echo "❌ ERROR: Could not detect all service names from docker-compose.yml!"
    echo "   Pi-hole service: ${PIHOLE_SERVICE:-NOT FOUND}"
    echo "   Redis service: ${REDIS_SERVICE:-NOT FOUND}"
    echo "   Unbound service: ${UNBOUND_SERVICE:-NOT FOUND}"
    exit 1
fi

echo ""
echo "✅ Auto-detection complete!"
echo ""
echo "📋 Environment Summary:"
echo "────────────────────────────────────────────────────────────────"
echo "  Project: $PROJECT_DIR"
echo "  Device IP: $DEVICE_IP"
echo "  Containers: $PIHOLE_CONTAINER, $REDIS_CONTAINER, $UNBOUND_CONTAINER"
echo "  Services: $PIHOLE_SERVICE, $REDIS_SERVICE, $UNBOUND_SERVICE"
echo "  Volume Prefix: $VOLUME_PREFIX"
echo ""
read -p "Press Enter to continue with these settings..."
echo ""

# Setup directories
BACKUP_DIR=~/pihole-backups/$(date +%Y%m%d-%H%M)
LOG_DIR=~/pihole-backups/logs
LOG_FILE=$LOG_DIR/update-$(date +%Y%m%d-%H%M%S).log

# Create log directory
mkdir -p "$LOG_DIR"

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

log_info() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$LOG_FILE" >&2
}

log_warning() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $1" | tee -a "$LOG_FILE"
}

log_command() {
    local cmd="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [CMD] $cmd" >> "$LOG_FILE"
    eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
    local exit_code=${PIPESTATUS[0]}
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [EXIT] Command exited with code: $exit_code" >> "$LOG_FILE"
    return $exit_code
}

log_separator() {
    echo "================================================================" | tee -a "$LOG_FILE"
}

log_phase() {
    echo "" | tee -a "$LOG_FILE"
    log_separator
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [PHASE] $1" | tee -a "$LOG_FILE"
    log_separator
    echo "" | tee -a "$LOG_FILE"
}

# ============================================================================
# ROLLBACK FUNCTIONS
# ============================================================================

rollback_component() {
    local service_name="$1"
    
    log_error "Initiating rollback for $service_name..."
    
    # Stop the failed service
    log_command "docker-compose stop $service_name"
    
    # Remove the container
    log_command "docker-compose rm -f $service_name"
    
    # Recreate with previous image (Docker keeps old images)
    log_command "docker-compose up -d $service_name"
    
    # Wait for startup
    sleep 15
    
    log_info "Rollback complete for $service_name"
}

restore_from_backup() {
    if [ "$CREATE_BACKUP" != true ]; then
        log_error "No backup was created - cannot restore!"
        return 1
    fi
    
    log_warning "Restoring from backup: $BACKUP_DIR"
    
    # Restore docker-compose.yml
    if [ -f "$BACKUP_DIR/docker-compose-backup.yml" ]; then
        log_command "cp '$BACKUP_DIR/docker-compose-backup.yml' '$PROJECT_DIR/docker-compose.yml'"
    fi
    
    # Restore Pi-hole configuration
    if [ -f "$BACKUP_DIR/pihole.toml.backup" ]; then
        log_info "Restoring Pi-hole configuration..."
        cat "$BACKUP_DIR/pihole.toml.backup" | docker exec -i $PIHOLE_CONTAINER tee /etc/pihole/pihole.toml >/dev/null 2>&1
    fi
    
    # Restore volumes if needed
    if [ -f "$BACKUP_DIR/pihole-config.tar.gz" ]; then
        log_info "Restoring Pi-hole volumes..."
        docker run --rm \
            -v ${VOLUME_PREFIX}pihole-config:/target \
            -v "$BACKUP_DIR":/backup \
            alpine sh -c "cd /target && tar xzf /backup/pihole-config.tar.gz" >> "$LOG_FILE" 2>&1
    fi
    
    log_info "Backup restoration complete"
}

full_rollback() {
    log_phase "ROLLBACK: Attempting to restore system to previous state"
    
    cd "$PROJECT_DIR"
    
    # Stop all containers
    log_info "Stopping all containers..."
    log_command "docker-compose down"
    
    # Restore from backup if available
    if [ "$CREATE_BACKUP" = true ]; then
        restore_from_backup
    fi
    
    # Restart with old configuration
    log_info "Restarting services with previous configuration..."
    log_command "docker-compose up -d"
    
    sleep 30
    
    # Verify rollback
    log_info "Verifying rollback..."
    if nslookup google.com $DEVICE_IP >/dev/null 2>&1; then
        log_info "✅ Rollback successful - DNS is working"
        return 0
    else
        log_error "❌ Rollback verification failed - manual intervention required"
        return 1
    fi
}

# ============================================================================
# START SCRIPT
# ============================================================================

log_phase "Pi-hole Update Manager - $(date)"
log_info "Log file: $LOG_FILE"
log_info "Project directory: $PROJECT_DIR"
log_info "Device IP: $DEVICE_IP"
log_info "Volume prefix: $VOLUME_PREFIX"
log_info "Containers: $PIHOLE_CONTAINER, $REDIS_CONTAINER, $UNBOUND_CONTAINER"
log_info "Services: $PIHOLE_SERVICE, $REDIS_SERVICE, $UNBOUND_SERVICE"

echo "════════════════════════════════════════════════════════════════"
echo "Pi-hole Update Manager - $(date)"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "📋 Log file: $LOG_FILE"
echo ""

# ============================================================================
# PHASE 1: GATHER INFORMATION
# ============================================================================
log_phase "PHASE 1: Gathering system information"

echo "🔍 PHASE 1: Gathering system information..."
echo "────────────────────────────────────────────────────────────────"
echo ""

# Check if containers are running
if ! docker ps | grep -q "$PIHOLE_CONTAINER"; then
    log_error "Containers are not running!"
    echo "❌ ERROR: Containers are not running!"
    echo "   Start them with: cd $PROJECT_DIR && docker-compose up -d"
    exit 1
fi

# Current versions
echo "📊 Current Versions:"
PIHOLE_CORE=$(docker exec $PIHOLE_CONTAINER pihole -v 2>/dev/null | grep "Core version" | grep -oP 'v\K[0-9.]+' || echo "unknown")
PIHOLE_WEB=$(docker exec $PIHOLE_CONTAINER pihole -v 2>/dev/null | grep "Web version" | grep -oP 'v\K[0-9.]+' || echo "unknown")
PIHOLE_FTL=$(docker exec $PIHOLE_CONTAINER pihole -v 2>/dev/null | grep "FTL version" | grep -oP 'v\K[0-9.]+' || echo "unknown")
REDIS_VER=$(docker exec $REDIS_CONTAINER redis-server --version 2>/dev/null | grep -oP 'v=\K[0-9.]+' || echo "unknown")
UNBOUND_VER=$(docker exec $UNBOUND_CONTAINER unbound -V 2>/dev/null | head -1 | grep -oP 'Version \K[0-9.]+' || echo "unknown")

log_info "Current versions - Pi-hole: Core $PIHOLE_CORE, Web $PIHOLE_WEB, FTL $PIHOLE_FTL"
log_info "Current versions - Redis: $REDIS_VER, Unbound: $UNBOUND_VER"

echo "  Pi-hole: Core $PIHOLE_CORE, Web $PIHOLE_WEB, FTL $PIHOLE_FTL"
echo "  Redis: $REDIS_VER"
echo "  Unbound: $UNBOUND_VER"
echo ""

# Image ages
echo "📅 Local Image Ages:"
NOW=$(date +%s)

# Pi-hole age
PIHOLE_CREATED=$(docker images pihole/pihole:latest --format "{{.CreatedAt}}" 2>/dev/null || echo "unknown")
if [ "$PIHOLE_CREATED" != "unknown" ]; then
    PIHOLE_EPOCH=$(date -d "$PIHOLE_CREATED" +%s 2>/dev/null || echo "$NOW")
    PIHOLE_DAYS=$(( ($NOW - $PIHOLE_EPOCH) / 86400 ))
else
    PIHOLE_DAYS=0
fi

# Redis age
REDIS_CREATED=$(docker images redis:7-alpine --format "{{.CreatedAt}}" 2>/dev/null || echo "unknown")
if [ "$REDIS_CREATED" != "unknown" ]; then
    REDIS_EPOCH=$(date -d "$REDIS_CREATED" +%s 2>/dev/null || echo "$NOW")
    REDIS_DAYS=$(( ($NOW - $REDIS_EPOCH) / 86400 ))
else
    REDIS_DAYS=0
fi

# Alpine age
ALPINE_CREATED=$(docker images alpine:latest --format "{{.CreatedAt}}" 2>/dev/null || echo "unknown")
if [ "$ALPINE_CREATED" != "unknown" ]; then
    ALPINE_EPOCH=$(date -d "$ALPINE_CREATED" +%s 2>/dev/null || echo "$NOW")
    ALPINE_DAYS=$(( ($NOW - $ALPINE_EPOCH) / 86400 ))
else
    ALPINE_DAYS=0
fi

log_info "Image ages - Pi-hole: $PIHOLE_DAYS days, Redis: $REDIS_DAYS days, Alpine: $ALPINE_DAYS days"

echo "  Pi-hole image: $PIHOLE_DAYS days old"
echo "  Redis image: $REDIS_DAYS days old"
echo "  Alpine base: $ALPINE_DAYS days old"
echo ""

# Pre-flight DNS test
echo "🔍 Pre-flight DNS Test:"
if nslookup google.com $DEVICE_IP >/dev/null 2>&1; then
    log_info "Pre-flight DNS test: PASSED"
    echo "  ✅ DNS is working before update"
else
    log_warning "Pre-flight DNS test: FAILED"
    echo "  ⚠️  DNS issue detected - proceed with caution"
fi
echo ""

# ============================================================================
# PHASE 2: CHECK FOR AVAILABLE UPDATES
# ============================================================================
log_phase "PHASE 2: Checking for available updates"

echo "════════════════════════════════════════════════════════════════"
echo "🔍 PHASE 2: Checking for available updates..."
echo "────────────────────────────────────────────────────────────────"
echo ""

UPDATE_PIHOLE=false
UPDATE_REDIS=false
UPDATE_UNBOUND=false

# Check Pi-hole
echo "Checking Pi-hole (this may take a moment)..."
log_info "Checking Pi-hole for updates..."

PIHOLE_RUNNING_SHA=$(docker inspect $PIHOLE_CONTAINER --format='{{.Image}}' 2>/dev/null)
log_info "Pi-hole running SHA: $PIHOLE_RUNNING_SHA"

docker pull pihole/pihole:latest >/dev/null 2>&1
PIHOLE_LATEST_SHA=$(docker inspect pihole/pihole:latest --format='{{.Id}}' 2>/dev/null)
log_info "Pi-hole latest SHA: $PIHOLE_LATEST_SHA"

if [ "$PIHOLE_RUNNING_SHA" = "$PIHOLE_LATEST_SHA" ]; then
    log_info "Pi-hole is current"
    echo "  ✅ Pi-hole is current"
else
    UPDATE_PIHOLE=true
    log_info "Pi-hole update available"
    echo "  ⚠️  Update available for Pi-hole"
fi

# Check Redis
echo "Checking Redis..."
log_info "Checking Redis for updates..."

REDIS_RUNNING_SHA=$(docker inspect $REDIS_CONTAINER --format='{{.Image}}' 2>/dev/null)
log_info "Redis running SHA: $REDIS_RUNNING_SHA"

docker pull redis:7-alpine >/dev/null 2>&1
REDIS_LATEST_SHA=$(docker inspect redis:7-alpine --format='{{.Id}}' 2>/dev/null)
log_info "Redis latest SHA: $REDIS_LATEST_SHA"

if [ "$REDIS_RUNNING_SHA" = "$REDIS_LATEST_SHA" ]; then
    log_info "Redis is current"
    echo "  ✅ Redis is current"
else
    UPDATE_REDIS=true
    log_info "Redis update available"
    echo "  ⚠️  Update available for Redis"
fi

# Check Alpine (triggers Unbound rebuild)
echo "Checking Alpine (Unbound base)..."
log_info "Checking Alpine for updates..."

ALPINE_OLD_DIGEST=$(docker images alpine:latest --format "{{.Digest}}" 2>/dev/null)
log_info "Alpine old digest: $ALPINE_OLD_DIGEST"

docker pull alpine:latest >/dev/null 2>&1

ALPINE_NEW_DIGEST=$(docker images alpine:latest --format "{{.Digest}}" 2>/dev/null)
log_info "Alpine new digest: $ALPINE_NEW_DIGEST"

if [ "$ALPINE_OLD_DIGEST" != "$ALPINE_NEW_DIGEST" ] && \
   [ "$ALPINE_OLD_DIGEST" != "<none>" ] && \
   [ "$ALPINE_NEW_DIGEST" != "<none>" ] && \
   [ -n "$ALPINE_OLD_DIGEST" ] && \
   [ -n "$ALPINE_NEW_DIGEST" ]; then
    UPDATE_UNBOUND=true
    log_info "New Alpine base available - Unbound rebuild recommended"
    echo "  ⚠️  New Alpine base available - Unbound rebuild recommended"
elif [ "$ALPINE_DAYS" -gt 120 ]; then
    UPDATE_UNBOUND=true
    log_info "Alpine base is $ALPINE_DAYS days old - Unbound rebuild recommended"
    echo "  ⚠️  Alpine base is $ALPINE_DAYS days old - Unbound rebuild recommended"
else
    log_info "Alpine/Unbound is current"
    echo "  ✅ Alpine/Unbound is current"
fi

echo ""

# ============================================================================
# PHASE 3: APPLY DECISION MATRIX & PRESENT RECOMMENDATIONS
# ============================================================================
log_phase "PHASE 3: Analysis & Recommendations"

echo "════════════════════════════════════════════════════════════════"
echo "🎯 PHASE 3: Analysis & Recommendations"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Determine scenario
SCENARIO="NONE"
COMPONENTS_TO_UPDATE=""

if [ "$UPDATE_PIHOLE" = true ] && [ "$UPDATE_REDIS" = true ] && [ "$UPDATE_UNBOUND" = true ]; then
    SCENARIO="C"
    COMPONENTS_TO_UPDATE="Pi-hole, Redis, and Unbound"
elif [ "$UPDATE_PIHOLE" = true ] && [ "$UPDATE_REDIS" = true ]; then
    SCENARIO="C"
    COMPONENTS_TO_UPDATE="Pi-hole and Redis"
elif [ "$UPDATE_PIHOLE" = true ] && [ "$UPDATE_UNBOUND" = true ]; then
    SCENARIO="C"
    COMPONENTS_TO_UPDATE="Pi-hole and Unbound"
elif [ "$UPDATE_REDIS" = true ] && [ "$UPDATE_UNBOUND" = true ]; then
    SCENARIO="C"
    COMPONENTS_TO_UPDATE="Redis and Unbound"
elif [ "$UPDATE_PIHOLE" = true ]; then
    SCENARIO="PIHOLE"
    COMPONENTS_TO_UPDATE="Pi-hole only"
elif [ "$UPDATE_REDIS" = true ]; then
    SCENARIO="A"
    COMPONENTS_TO_UPDATE="Redis only"
elif [ "$UPDATE_UNBOUND" = true ]; then
    SCENARIO="B"
    COMPONENTS_TO_UPDATE="Unbound only"
fi

log_info "Determined scenario: $SCENARIO - Components: $COMPONENTS_TO_UPDATE"

if [ "$SCENARIO" = "NONE" ]; then
    log_info "All components are current - no updates needed"
    echo "✅ All components are current - no updates needed!"
    echo ""
    echo "Component Status:"
    echo "  • Pi-hole: v$PIHOLE_CORE (up to date)"
    echo "  • Redis: v$REDIS_VER (up to date)"
    echo "  • Unbound: v$UNBOUND_VER (up to date)"
    echo ""
    echo "Next steps:"
    echo "  • Run this script monthly to check for updates"
    echo "  • Monitor system health: $PROJECT_DIR/daily-check.sh"
    exit 0
fi

# Show findings
echo "📋 FINDINGS:"
echo "────────────────────────────────────────────────────────────────"
[ "$UPDATE_PIHOLE" = true ] && echo "  ⚠️  Pi-hole: Update available"
[ "$UPDATE_REDIS" = true ] && echo "  ⚠️  Redis: Update available"
[ "$UPDATE_UNBOUND" = true ] && echo "  ⚠️  Unbound: Rebuild recommended"
echo ""

# Show decision matrix recommendation
echo "💡 DECISION MATRIX ANALYSIS:"
echo "────────────────────────────────────────────────────────────────"

if [ "$UPDATE_PIHOLE" = true ]; then
    echo "  Pi-hole:"
    echo "    • Update Effort: LOW (just pull image)"
    echo "    • Risk Level: MEDIUM"
    echo "    • Recommendation: UPDATE (security patches + bug fixes)"
    echo ""
fi

if [ "$UPDATE_REDIS" = true ]; then
    echo "  Redis:"
    echo "    • Update Effort: LOW (just pull image)"
    echo "    • Risk Level: LOW (cache data regenerates)"
    echo "    • Recommendation: UPDATE (maintenance)"
    echo ""
fi

if [ "$UPDATE_UNBOUND" = true ]; then
    echo "  Unbound:"
    echo "    • Update Effort: MEDIUM (rebuild required)"
    echo "    • Risk Level: LOW (config preserved)"
    echo "    • Recommendation: REBUILD (security + Alpine updates)"
    echo ""
fi

# Show scenario
echo "🎬 SCENARIO: "
case $SCENARIO in
    "PIHOLE")
        echo "    Pi-hole Update Only"
        echo "    • Simple image pull and restart"
        echo "    • Duration: ~2 minutes"
        ;;
    "A")
        echo "    Scenario A: Redis Update"
        echo "    • Pull new Redis image"
        echo "    • Restart Redis container"
        echo "    • Duration: ~1 minute"
        ;;
    "B")
        echo "    Scenario B: Unbound Rebuild"
        echo "    • Pull new Alpine base"
        echo "    • Rebuild Unbound image"
        echo "    • Restart Unbound container"
        echo "    • Duration: ~3-5 minutes"
        ;;
    "C")
        echo "    Scenario C: Multiple Component Update"
        echo "    • Updates: $COMPONENTS_TO_UPDATE"
        echo "    • Will update in dependency order:"
        [ "$UPDATE_REDIS" = true ] && echo "      1. Redis (no dependencies)"
        [ "$UPDATE_UNBOUND" = true ] && echo "      2. Unbound (depends on Redis)"
        [ "$UPDATE_PIHOLE" = true ] && echo "      3. Pi-hole (depends on Unbound)"
        echo "    • Duration: ~5-10 minutes"
        ;;
esac
echo ""

# ============================================================================
# PHASE 4: USER DECISION
# ============================================================================
log_phase "PHASE 4: User Decision"

echo "════════════════════════════════════════════════════════════════"
echo "❓ PHASE 4: Your Decision"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "⚠️  IMPORTANT: This will update $COMPONENTS_TO_UPDATE"
echo ""
echo "What would you like to do?"
echo "  1) Proceed with update (recommended)"
echo "  2) Create backup first, then update"
echo "  3) Cancel (no changes)"
echo ""
read -p "Enter choice (1-3): " CHOICE

log_info "User selected option: $CHOICE"

case $CHOICE in
    1)
        echo ""
        echo "⚠️  Warning: Proceeding WITHOUT backup"
        echo "   Automatic rollback will NOT be available if update fails!"
        read -p "Are you absolutely sure? (yes/no): " CONFIRM
        log_info "User confirmation for no-backup: $CONFIRM"
        if [ "$CONFIRM" != "yes" ]; then
            log_info "Update cancelled by user"
            echo "❌ Update cancelled"
            exit 0
        fi
        CREATE_BACKUP=false
        ;;
    2)
        log_info "User chose to create backup before update"
        echo ""
        echo "✅ Will create backup before updating"
        echo "   Automatic rollback will be available if update fails"
        CREATE_BACKUP=true
        ;;
    3)
        log_info "Update cancelled by user"
        echo ""
        echo "❌ Update cancelled by user"
        exit 0
        ;;
    *)
        log_error "Invalid choice: $CHOICE"
        echo "❌ Invalid choice - update cancelled"
        exit 1
        ;;
esac

# ============================================================================
# PHASE 5: BACKUP (if requested)
# ============================================================================
if [ "$CREATE_BACKUP" = true ]; then
    log_phase "PHASE 5: Creating Backup"
    
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "💾 PHASE 5: Creating Backup"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    
    mkdir -p "$BACKUP_DIR"
    cd "$BACKUP_DIR"
    
    log_info "Backup directory: $BACKUP_DIR"
    
    echo "Backing up docker-compose.yml..."
    log_command "cp '$PROJECT_DIR/docker-compose.yml' './docker-compose-backup.yml'"
    
    echo "Backing up Pi-hole configuration..."
    docker exec $PIHOLE_CONTAINER cat /etc/pihole/pihole.toml > ./pihole.toml.backup 2>/dev/null || \
        docker exec $PIHOLE_CONTAINER cat /etc/pihole/setupVars.conf > ./setupVars.conf.backup 2>/dev/null
    log_info "Pi-hole configuration backed up"
    
    echo "Backing up Pi-hole volumes..."
    docker run --rm \
        -v ${VOLUME_PREFIX}pihole-config:/source \
        -v "$BACKUP_DIR":/backup \
        alpine tar czf /backup/pihole-config.tar.gz -C /source . >> "$LOG_FILE" 2>&1
    
    docker run --rm \
        -v ${VOLUME_PREFIX}pihole-dnsmasq:/source \
        -v "$BACKUP_DIR":/backup \
        alpine tar czf /backup/pihole-dnsmasq.tar.gz -C /source . >> "$LOG_FILE" 2>&1
    
    log_info "Pi-hole volumes backed up"
    
    echo ""
    echo "✅ Backup complete: $BACKUP_DIR"
    ls -lh "$BACKUP_DIR" | tee -a "$LOG_FILE"
    echo ""
    read -p "Press Enter to continue with update..."
fi

# ============================================================================
# PHASE 6: EXECUTE UPDATE
# ============================================================================
log_phase "PHASE 6: Executing Update"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🚀 PHASE 6: Executing Update"
echo "════════════════════════════════════════════════════════════════"
echo ""

cd "$PROJECT_DIR"

UPDATE_FAILED=false
FAILED_COMPONENT=""

# Scenario A: Redis only
if [ "$SCENARIO" = "A" ]; then
    log_info "Starting Scenario A: Redis update"
    echo "📦 Updating Redis..."
    
    if log_command "docker-compose up -d $REDIS_SERVICE"; then
        echo "⏳ Waiting for Redis to stabilize..."
        sleep 10
        
        # Monitor Redis startup
        REDIS_HEALTHY=false
        for i in {1..10}; do
            if docker exec $REDIS_CONTAINER redis-cli ping >/dev/null 2>&1; then
                log_info "Redis is responding after update"
                echo "  ✅ Redis is responding"
                REDIS_HEALTHY=true
                break
            fi
            echo "  ⏳ Waiting... ($i/10)"
            sleep 5
        done
        
        if [ "$REDIS_HEALTHY" = false ]; then
            log_error "Redis failed to respond after update"
            UPDATE_FAILED=true
            FAILED_COMPONENT="$REDIS_SERVICE"
        fi
    else
        log_error "Redis update command failed"
        UPDATE_FAILED=true
        FAILED_COMPONENT="$REDIS_SERVICE"
    fi
fi

# Scenario B: Unbound only
if [ "$SCENARIO" = "B" ] && [ "$UPDATE_FAILED" = false ]; then
    log_info "Starting Scenario B: Unbound rebuild"
    echo "🔨 Rebuilding Unbound..."
    
    if log_command "docker-compose build --no-cache $UNBOUND_SERVICE"; then
        echo "🔄 Restarting Unbound..."
        
        if log_command "docker-compose up -d $UNBOUND_SERVICE"; then
            echo "⏳ Waiting for Unbound to stabilize..."
            sleep 10
            
            # Monitor Unbound startup
            UNBOUND_HEALTHY=false
            for i in {1..10}; do
                if docker exec $UNBOUND_CONTAINER drill @127.0.0.1 cloudflare.com >/dev/null 2>&1; then
                    log_info "Unbound is responding after rebuild"
                    echo "  ✅ Unbound is responding"
                    UNBOUND_HEALTHY=true
                    break
                fi
                echo "  ⏳ Waiting... ($i/10)"
                sleep 5
            done
            
            if [ "$UNBOUND_HEALTHY" = false ]; then
                log_error "Unbound failed to respond after rebuild"
                UPDATE_FAILED=true
                FAILED_COMPONENT="$UNBOUND_SERVICE"
            fi
        else
            log_error "Unbound restart failed"
            UPDATE_FAILED=true
            FAILED_COMPONENT="$UNBOUND_SERVICE"
        fi
    else
        log_error "Unbound build failed"
        UPDATE_FAILED=true
        FAILED_COMPONENT="$UNBOUND_SERVICE"
    fi
fi

# Scenario C or PIHOLE: Multiple components or Pi-hole
if [ "$SCENARIO" = "C" ] || [ "$SCENARIO" = "PIHOLE" ]; then
    
    # Redis first (if needed)
    if [ "$UPDATE_REDIS" = true ] && [ "$UPDATE_FAILED" = false ]; then
        log_info "Step 1: Updating Redis"
        echo "📦 Step 1: Updating Redis..."
        
        if log_command "docker-compose up -d $REDIS_SERVICE"; then
            echo "⏳ Waiting for Redis..."
            sleep 10
            
            REDIS_HEALTHY=false
            for i in {1..10}; do
                if docker exec $REDIS_CONTAINER redis-cli ping >/dev/null 2>&1; then
                    log_info "Redis is responding"
                    echo "  ✅ Redis is responding"
                    REDIS_HEALTHY=true
                    break
                fi
                echo "  ⏳ Waiting... ($i/10)"
                sleep 5
            done
            
            if [ "$REDIS_HEALTHY" = false ]; then
                log_error "Redis failed to respond"
                UPDATE_FAILED=true
                FAILED_COMPONENT="$REDIS_SERVICE"
            fi
            
            docker-compose ps | grep $REDIS_CONTAINER | tee -a "$LOG_FILE"
            echo ""
        else
            log_error "Redis update failed"
            UPDATE_FAILED=true
            FAILED_COMPONENT="$REDIS_SERVICE"
        fi
    fi
    
    # Unbound second (if needed)
    if [ "$UPDATE_UNBOUND" = true ] && [ "$UPDATE_FAILED" = false ]; then
        log_info "Step 2: Rebuilding Unbound"
        echo "🔨 Step 2: Rebuilding Unbound..."
        
        if log_command "docker-compose build --no-cache $UNBOUND_SERVICE"; then
            if log_command "docker-compose up -d $UNBOUND_SERVICE"; then
                echo "⏳ Waiting for Unbound..."
                sleep 10
                
                UNBOUND_HEALTHY=false
                for i in {1..10}; do
                    if docker exec $UNBOUND_CONTAINER drill @127.0.0.1 cloudflare.com >/dev/null 2>&1; then
                        log_info "Unbound is responding"
                        echo "  ✅ Unbound is responding"
                        UNBOUND_HEALTHY=true
                        break
                    fi
                    echo "  ⏳ Waiting... ($i/10)"
                    sleep 5
                done
                
                if [ "$UNBOUND_HEALTHY" = false ]; then
                    log_error "Unbound failed to respond"
                    UPDATE_FAILED=true
                    FAILED_COMPONENT="$UNBOUND_SERVICE"
                fi
                
                docker-compose ps | grep $UNBOUND_CONTAINER | tee -a "$LOG_FILE"
                echo ""
            else
                log_error "Unbound restart failed"
                UPDATE_FAILED=true
                FAILED_COMPONENT="$UNBOUND_SERVICE"
            fi
        else
            log_error "Unbound build failed"
            UPDATE_FAILED=true
            FAILED_COMPONENT="$UNBOUND_SERVICE"
        fi
    fi
    
    # Pi-hole last (if needed)
    if [ "$UPDATE_PIHOLE" = true ] && [ "$UPDATE_FAILED" = false ]; then
        log_info "Step 3: Updating Pi-hole"
        echo "📦 Step 3: Updating Pi-hole..."
        
        if log_command "docker-compose up -d $PIHOLE_SERVICE"; then
            echo "⏳ Waiting for Pi-hole to fully start..."
            sleep 20
            
            PIHOLE_HEALTHY=false
            for i in {1..12}; do
                if docker exec $PIHOLE_CONTAINER pihole status >/dev/null 2>&1; then
                    log_info "Pi-hole is responding"
                    echo "  ✅ Pi-hole is responding"
                    PIHOLE_HEALTHY=true
                    break
                fi
                echo "  ⏳ Waiting... ($i/12)"
                sleep 5
            done
            
            if [ "$PIHOLE_HEALTHY" = false ]; then
                log_error "Pi-hole failed to respond"
                UPDATE_FAILED=true
                FAILED_COMPONENT="$PIHOLE_SERVICE"
            fi
            
            docker-compose ps | grep $PIHOLE_CONTAINER | tee -a "$LOG_FILE"
            echo ""
        else
            log_error "Pi-hole update failed"
            UPDATE_FAILED=true
            FAILED_COMPONENT="$PIHOLE_SERVICE"
        fi
    fi
fi

# ============================================================================
# PHASE 6.5: ERROR HANDLING & ROLLBACK
# ============================================================================
if [ "$UPDATE_FAILED" = true ]; then
    log_phase "PHASE 6.5: ERROR DETECTED - Initiating Rollback"
    
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "❌ UPDATE FAILED - $FAILED_COMPONENT"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    
    if [ "$CREATE_BACKUP" = true ]; then
        echo "🔄 Automatic rollback is available"
        echo "   Attempting to restore system to previous working state..."
        echo ""
        
        if full_rollback; then
            log_info "Rollback completed successfully"
            echo ""
            echo "✅ System has been rolled back to previous state"
            echo "   All components should be functional again"
            echo ""
            echo "📋 Troubleshooting:"
            echo "   • Check logs: $LOG_FILE"
            echo "   • Check container logs: docker logs $FAILED_COMPONENT"
            echo "   • Verify system: $PROJECT_DIR/daily-check.sh"
            echo ""
            exit 1
        else
            log_error "Rollback failed - manual intervention required"
            echo ""
            echo "❌ CRITICAL: Automatic rollback failed"
            echo ""
            echo "🚨 Manual recovery required:"
            echo "   1. Check logs: $LOG_FILE"
            echo "   2. Check containers: docker-compose ps"
            echo "   3. Try manual restart: docker-compose restart"
            echo "   4. Restore from backup: $BACKUP_DIR"
            echo ""
            exit 1
        fi
    else
        log_error "No backup available - cannot rollback automatically"
        echo "❌ No backup was created - automatic rollback not available"
        echo ""
        echo "🚨 Manual recovery steps:"
        echo "   1. Check logs: $LOG_FILE"
        echo "   2. Check container: docker logs $FAILED_COMPONENT"
        echo "   3. Try restart: docker-compose restart $FAILED_COMPONENT"
        echo "   4. Review error messages above"
        echo ""
        exit 1
    fi
fi

# ============================================================================
# PHASE 7: VERIFICATION
# ============================================================================
log_phase "PHASE 7: Post-Update Verification"

echo "════════════════════════════════════════════════════════════════"
echo "✅ PHASE 7: Verification"
echo "════════════════════════════════════════════════════════════════"
echo ""

echo "📊 Container Status:"
docker-compose ps | tee -a "$LOG_FILE"
echo ""

# Comprehensive system verification
VERIFICATION_FAILED=false

echo "🔍 Comprehensive System Verification..."
log_info "Starting comprehensive system verification"

# Test 1: All containers healthy (FIX 2: Safer counting method)
echo "  Testing: Container health..."
HEALTHY_COUNT=0
docker-compose ps | grep "$PIHOLE_CONTAINER" | grep -q "Up (healthy)" && ((HEALTHY_COUNT++)) || true
docker-compose ps | grep "$REDIS_CONTAINER" | grep -q "Up (healthy)" && ((HEALTHY_COUNT++)) || true
docker-compose ps | grep "$UNBOUND_CONTAINER" | grep -q "Up (healthy)" && ((HEALTHY_COUNT++)) || true

if [ "$HEALTHY_COUNT" -eq 3 ]; then
    log_info "Verification: All 3 containers healthy - PASS"
    echo "    ✅ All 3 containers healthy"
else
    log_error "Verification: Only $HEALTHY_COUNT/3 containers healthy - FAIL"
    echo "    ❌ Only $HEALTHY_COUNT/3 containers are healthy"
    VERIFICATION_FAILED=true
fi

# Test 2: DNS resolution
echo "  Testing: DNS resolution..."
if nslookup google.com $DEVICE_IP >/dev/null 2>&1; then
    log_info "Verification: DNS resolution - PASS"
    echo "    ✅ DNS resolution working"
else
    log_error "Verification: DNS resolution - FAIL"
    echo "    ❌ DNS resolution failed"
    VERIFICATION_FAILED=true
fi

# Test 3: Ad blocking
echo "  Testing: Ad blocking..."
if nslookup doubleclick.net $DEVICE_IP 2>/dev/null | grep -q "0.0.0.0"; then
    log_info "Verification: Ad blocking - PASS"
    echo "    ✅ Ad blocking working"
else
    log_error "Verification: Ad blocking - FAIL"
    echo "    ❌ Ad blocking not working"
    VERIFICATION_FAILED=true
fi

# Test 4: Cache performance
echo "  Testing: Cache performance..."
T1=$(bash -c 'time nslookup test-$(date +%s).example.com $DEVICE_IP >/dev/null 2>&1' 2>&1 | grep real | awk '{print $2}')
sleep 1
T2=$(bash -c 'time nslookup google.com $DEVICE_IP >/dev/null 2>&1' 2>&1 | grep real | awk '{print $2}')
log_info "Cache test: First query $T1, Second query $T2"
echo "    ⏱️  First: $T1, Second: $T2"

echo ""

if [ "$VERIFICATION_FAILED" = true ]; then
    log_phase "CRITICAL: Post-update verification failed - Initiating rollback"
    
    echo "════════════════════════════════════════════════════════════════"
    echo "❌ VERIFICATION FAILED"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "⚠️  System verification failed after update!"
    echo "   One or more critical tests did not pass."
    echo ""
    
    if [ "$CREATE_BACKUP" = true ]; then
        echo "🔄 Initiating automatic rollback..."
        echo ""
        
        if full_rollback; then
            log_info "Post-verification rollback completed successfully"
            echo "✅ System rolled back to previous working state"
            echo ""
            echo "📋 Next steps:"
            echo "   • Review logs: $LOG_FILE"
            echo "   • Investigate why verification failed"
            echo "   • Try update again later"
            echo ""
            exit 1
        else
            log_error "Post-verification rollback failed"
            echo "❌ Rollback failed - manual intervention required"
            echo ""
            echo "🚨 Critical recovery needed:"
            echo "   • Log file: $LOG_FILE"
            echo "   • Backup: $BACKUP_DIR"
            echo ""
            exit 1
        fi
    else
        log_error "Verification failed and no backup available"
        echo "❌ No backup available for rollback"
        echo ""
        echo "🚨 Manual recovery required:"
        echo "   • Check logs: $LOG_FILE"
        echo "   • Restart services: docker-compose restart"
        echo ""
        exit 1
    fi
fi

# If we got here, verification passed
log_info "All verification tests passed"

# Run daily health check if available
echo "Running health check..."
if [ -f "$PROJECT_DIR/daily-check.sh" ]; then
    "$PROJECT_DIR/daily-check.sh" | tee -a "$LOG_FILE"
else
    log_warning "daily-check.sh not found, skipping detailed health check"
    echo "⚠️  daily-check.sh not found, running basic checks..."
    echo ""
    echo "Container Status:"
    docker ps | grep -E "$PIHOLE_CONTAINER|$REDIS_CONTAINER|$UNBOUND_CONTAINER" --format "table {{.Names}}\t{{.Status}}"
    echo ""
fi

# ============================================================================
# PHASE 8: SUMMARY
# ============================================================================
log_phase "PHASE 8: Update Complete - Success"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🎉 UPDATE COMPLETE - SUCCESS"
echo "════════════════════════════════════════════════════════════════"
echo ""

log_info "Update completed successfully"
log_info "Updated components: $COMPONENTS_TO_UPDATE"

echo "Updated components: $COMPONENTS_TO_UPDATE"
[ "$CREATE_BACKUP" = true ] && echo "Backup location: $BACKUP_DIR"
echo "Log file: $LOG_FILE"
echo ""

echo "New versions:"
PIHOLE_NEW=$(docker exec $PIHOLE_CONTAINER pihole -v 2>/dev/null | grep "Core version" | grep -oP 'v\K[0-9.]+' || echo "unknown")
REDIS_NEW=$(docker exec $REDIS_CONTAINER redis-server --version 2>/dev/null | grep -oP 'v=\K[0-9.]+' || echo "unknown")
UNBOUND_NEW=$(docker exec $UNBOUND_CONTAINER unbound -V 2>/dev/null | head -1 | grep -oP 'Version \K[0-9.]+' || echo "unknown")

log_info "New versions - Pi-hole: v$PIHOLE_NEW, Redis: v$REDIS_NEW, Unbound: v$UNBOUND_NEW"

echo "  • Pi-hole: v$PIHOLE_NEW"
echo "  • Redis: v$REDIS_NEW"
echo "  • Unbound: v$UNBOUND_NEW"
echo ""

echo "Next steps:"
echo "  • Monitor system for 24-48 hours"
echo "  • Run daily health check: $PROJECT_DIR/daily-check.sh"
echo "  • Check web interface: http://$DEVICE_IP/admin"
echo "  • Review logs if needed: $LOG_FILE"
echo ""

log_info "Update process completed successfully"
