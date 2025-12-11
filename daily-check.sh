#!/bin/bash
# Pi-hole + Unbound + Redis Health Check
# Universal script - auto-detects configuration
# Works across different deployments and IP changes

echo "════════════════════════════════════════════════════════════════"
echo "Pi-hole Health Check - $(date)"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Auto-detect configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

# Get container name prefix from docker-compose.yml or use default
if [ -f "$COMPOSE_FILE" ]; then
    CONTAINER_PREFIX=$(grep "container_name:" "$COMPOSE_FILE" | head -1 | sed 's/.*container_name: *\([^-]*\)-.*/\1/')
else
    CONTAINER_PREFIX="gdb"
fi

# Auto-detect Pi-hole container IP
PIHOLE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER_PREFIX}-pihole" 2>/dev/null)

# Fallback to host machine IP if container IP not found
if [ -z "$PIHOLE_IP" ]; then
    PIHOLE_IP=$(hostname -I | awk '{print $1}')
    echo "ℹ️  Using host IP: $PIHOLE_IP"
else
    echo "ℹ️  Using Pi-hole container IP: $PIHOLE_IP"
fi

echo ""

# Test 1: Containers running
echo "📊 Container Status:"
docker ps --filter "name=${CONTAINER_PREFIX}-" --format "table {{.Names}}\t{{.Status}}" | grep -E "${CONTAINER_PREFIX}-|NAME"
RUNNING=$(docker ps --filter "name=${CONTAINER_PREFIX}-" --format "{{.Names}}" | wc -l)
EXPECTED=3
echo "Running: $RUNNING/$EXPECTED"
echo ""

# Test 2: DNS working
echo "🔍 DNS Resolution:"
if nslookup google.com "$PIHOLE_IP" >/dev/null 2>&1; then
    echo "✅ Working"
else
    echo "❌ FAILED"
fi
echo ""

# Test 3: Ad blocking
echo "🚫 Ad Blocking:"
BLOCKED=$(nslookup doubleclick.net "$PIHOLE_IP" 2>/dev/null | grep -c "0.0.0.0")
if [ "$BLOCKED" -gt 0 ]; then
    echo "✅ Working"
else
    echo "❌ FAILED"
fi
echo ""

# Test 4: Cache performance
echo "⚡ Cache Test:"
echo "First query (cache miss):"
time nslookup test-$(date +%s).example.com "$PIHOLE_IP" >/dev/null 2>&1
echo ""
echo "Second query (cached):"
time nslookup google.com "$PIHOLE_IP" >/dev/null 2>&1
echo ""

# Test 5: Errors (filtered for false positives)
echo "📋 Error Check (last hour):"
ERRORS=$(docker logs --since 1h "${CONTAINER_PREFIX}-pihole" 2>&1 | grep -i "error\|critical" | grep -v "recovered.*frames from WAL" | wc -l)
if [ "$ERRORS" -eq 0 ]; then
    echo "✅ No errors"
else
    echo "⚠️  Found $ERRORS potential error(s)"
    echo "   To investigate: docker logs --since 1h ${CONTAINER_PREFIX}-pihole | grep -i error"
fi
echo ""

# Test 6: Docker volumes health
echo "💾 Volume Status:"
VOLUMES=$(docker volume ls --filter "name=${CONTAINER_PREFIX}" --format "{{.Name}}" | wc -l)
echo "Volumes found: $VOLUMES"
echo ""

echo "════════════════════════════════════════════════════════════════"
echo "Summary: $([ "$RUNNING" -eq "$EXPECTED" ] && [ "$BLOCKED" -gt 0 ] && echo '✅ HEALTHY' || echo '⚠️  NEEDS ATTENTION')"
echo "════════════════════════════════════════════════════════════════"
