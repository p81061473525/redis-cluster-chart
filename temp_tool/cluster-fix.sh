#!/bin/bash

# Redis Cluster 修復 + 驗證一體化腳本
# 用途：修復 restart 後的舊 IP 問題，並驗證所有節點映射一致
#
# 使用方式：
#   bash ./cluster-fix.sh [namespace] [num_pods] [pod_prefix]
#
# 範例：
#   bash ./cluster-fix.sh redis-i32                    # 使用預設 NUM_PODS=8, POD_PREFIX=redis-cluster
#   bash ./cluster-fix.sh redis-i32 6                  # NUM_PODS=6
#   bash ./cluster-fix.sh redis-i32 6 my-redis         # 自訂 POD_PREFIX
#   DEBUG=1 bash ./cluster-fix.sh redis-i32            # DEBUG 模式（只預覽，不執行）
#
# 預設值：
#   namespace: redis-i4
#   num_pods: 8
#   pod_prefix: redis-cluster
#   Redis password: 自動從 Pod env 獲取

set -e

# ===== 配置 =====
DEFAULT_NAMESPACE="redis-i4"
DEFAULT_POD_PREFIX="redis-cluster"
DEFAULT_NUM_PODS=8

# 從命令行參數讀取
NAMESPACE="${1:-$DEFAULT_NAMESPACE}"
NUM_PODS="${2:-$DEFAULT_NUM_PODS}"
POD_PREFIX="${3:-$DEFAULT_POD_PREFIX}"
DEBUG="${DEBUG:-0}"

# 驗證 namespace 和 pod 是否存在
if ! kubectl get namespace $NAMESPACE &>/dev/null; then
    echo -e "${RED}[!] Namespace '$NAMESPACE' 不存在${NC}"
    exit 1
fi

if ! kubectl get pod ${POD_PREFIX}-0 -n $NAMESPACE &>/dev/null; then
    echo -e "${RED}[!] Pod '${POD_PREFIX}-0' 在 namespace '$NAMESPACE' 不存在${NC}"
    exit 1
fi

# 從 Pod env 自動獲取 REDIS_PASSWORD
REDIS_PASSWORD=$(kubectl exec pod/${POD_PREFIX}-0 -n $NAMESPACE -- env 2>/dev/null | grep "^REDIS_PASSWORD=" | cut -d= -f2)
if [ -z "$REDIS_PASSWORD" ]; then
    echo -e "${RED}[!] 無法從 Pod env 獲取 REDIS_PASSWORD${NC}"
    echo -e "${YELLOW}    請確保 Pod 有設定 REDIS_PASSWORD 環境變數${NC}"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║     Redis Cluster 修復 + 驗證一體化工具                   ║${NC}"
if [ "$DEBUG" = "1" ]; then
    echo -e "${YELLOW}║     🐛 DEBUG 模式 (不執行實際命令)                       ║${NC}"
fi
echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}[*] 配置信息${NC}"
echo "    Namespace: $NAMESPACE"
echo "    Pod Prefix: $POD_PREFIX"
echo "    Pod 數量: $NUM_PODS"
echo "    Redis Password: (從 Pod env 自動獲取)"
echo ""

# ===== PART 1: 修復 =====
echo -e "${YELLOW}[=== PART 1: 修復舊 IP ===]${NC}"
echo ""

echo -e "${YELLOW}[*] 獲取所有 Pod 的實際 IP${NC}"
declare -a POD_IPS
for ((i=0; i<NUM_PODS; i++)); do
    POD_NAME="${POD_PREFIX}-${i}"
    IP=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.podIP}' 2>/dev/null)
    if [ -z "$IP" ]; then
        echo -e "${RED}[!] 無法取得 $POD_NAME 的 IP${NC}"
        exit 1
    fi
    POD_IPS[$i]=$IP
    echo "    $POD_NAME: $IP"
done

echo ""
echo -e "${YELLOW}[*] 對每個 Pod 執行修復${NC}"
echo ""

for ((i=0; i<NUM_PODS; i++)); do
    POD_NAME="${POD_PREFIX}-${i}"
    echo -e "${BLUE}--- 修復 $POD_NAME ---${NC}"
    
    TEMP_NODES=$(mktemp)
    kubectl exec pod/$POD_NAME -n $NAMESPACE -- redis-cli -a $REDIS_PASSWORD cluster nodes > $TEMP_NODES 2>/dev/null || {
        echo -e "${RED}[!] 無法連接到 $POD_NAME${NC}"
        rm -f $TEMP_NODES
        continue
    }
    
    FORGOT_COUNT=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        NODE_ID=$(echo $line | awk '{print $1}')
        NODE_ADDR=$(echo $line | awk '{print $2}')
        NODE_IP=$(echo $NODE_ADDR | cut -d: -f1)
        NODE_FLAGS=$(echo $line | awk '{print $3}')
        
        if [[ "$NODE_FLAGS" =~ "myself" ]]; then
            continue
        fi
        
        IP_VALID=0
        for ((j=0; j<NUM_PODS; j++)); do
            if [[ "$NODE_IP" == "${POD_IPS[$j]}" ]]; then
                IP_VALID=1
                break
            fi
        done
        
        if [ $IP_VALID -eq 0 ]; then
            echo "    [!] FORGET 舊節點: $NODE_ID (舊 IP: $NODE_IP)"
            if [ "$DEBUG" = "1" ]; then
                echo "        [DEBUG] 命令: redis-cli -a *** cluster forget $NODE_ID"
            else
                kubectl exec pod/$POD_NAME -n $NAMESPACE -- redis-cli -a $REDIS_PASSWORD cluster forget $NODE_ID > /dev/null 2>&1
            fi
            ((FORGOT_COUNT++))
        fi
    done < $TEMP_NODES
    
    rm -f $TEMP_NODES
    
    echo "    [*] 執行 CLUSTER MEET..."
    for ((j=0; j<NUM_PODS; j++)); do
        if [ "$DEBUG" = "1" ]; then
            echo "        [DEBUG] 命令: redis-cli -a *** cluster meet ${POD_IPS[$j]} 6379"
        else
            kubectl exec pod/$POD_NAME -n $NAMESPACE -- redis-cli -a $REDIS_PASSWORD cluster meet ${POD_IPS[$j]} 6379 > /dev/null 2>&1
        fi
    done
    
    echo -e "    ${GREEN}[✓] 完成（FORGET $FORGOT_COUNT 個舊節點）${NC}"
done

echo ""

# ===== 等待cluster穩定 =====
if [ "$DEBUG" = "1" ]; then
    echo -e "${YELLOW}[*] DEBUG 模式：跳過等待，直接進入驗證${NC}"
else
    echo -e "${YELLOW}[*] 等待 cluster 穩定（檢查所有節點連接狀態）...${NC}"
    MAX_WAIT=900  # 最多等 15 分鐘
    WAIT_INTERVAL=5
    ELAPSED=0

    while [ $ELAPSED -lt $MAX_WAIT ]; do
        TEMP_CHECK=$(mktemp)
        kubectl exec pod/${POD_PREFIX}-0 -n $NAMESPACE -- redis-cli -a $REDIS_PASSWORD cluster nodes > $TEMP_CHECK 2>/dev/null || {
            rm -f $TEMP_CHECK
            sleep $WAIT_INTERVAL
            ((ELAPSED+=WAIT_INTERVAL))
            continue
        }
        
        # 檢查是否所有節點都是 connected 狀態
        TOTAL_NODES=$(grep -c "connected" "$TEMP_CHECK" 2>/dev/null || echo 0)
        FAILED_NODES=$(grep -E "fail|handshake" "$TEMP_CHECK" 2>/dev/null | wc -l)
        
        rm -f $TEMP_CHECK
        
        if [ $TOTAL_NODES -eq $NUM_PODS ] && [ $FAILED_NODES -eq 0 ]; then
            echo -e "    ${GREEN}[✓] 所有 $NUM_PODS 個節點已連接 (耗時 ${ELAPSED}秒)${NC}"
            break
        fi
        
        echo "    [.] 等待中... (已連接: $TOTAL_NODES/$NUM_PODS, 故障: $FAILED_NODES) [${ELAPSED}秒]"
        sleep $WAIT_INTERVAL
        ((ELAPSED+=WAIT_INTERVAL))
    done

    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo -e "${RED}[!] 等待超時 ($MAX_WAIT 秒)${NC}"
        echo -e "${YELLOW}    請手動檢查: kubectl exec pod/${POD_PREFIX}-0 -- redis-cli -a $REDIS_PASSWORD cluster nodes${NC}"
    fi
fi

echo ""

# ===== PART 2: 驗證 =====
echo -e "${YELLOW}[=== PART 2: 驗證節點映射 ===]${NC}"
echo ""

echo -e "${BLUE}[*] 從 pod-0 建立標準 Node ID -> IP 映射${NC}"

TEMP_STANDARD=$(mktemp)
kubectl exec pod/${POD_PREFIX}-0 -n $NAMESPACE -- redis-cli -a $REDIS_PASSWORD cluster nodes > $TEMP_STANDARD 2>/dev/null

TEMP_STANDARD_MAP=$(mktemp)
while IFS= read -r line; do
    [ -z "$line" ] && continue
    
    NODE_ID=$(echo $line | awk '{print $1}')
    NODE_ADDR=$(echo $line | awk '{print $2}')
    NODE_IP=$(echo $NODE_ADDR | cut -d: -f1)
    
    echo "$NODE_ID:$NODE_IP" >> $TEMP_STANDARD_MAP
done < $TEMP_STANDARD

STANDARD_COUNT=$(wc -l < $TEMP_STANDARD_MAP)
echo "    標準映射包含 $STANDARD_COUNT 個節點"

rm -f $TEMP_STANDARD
echo ""

echo -e "${BLUE}[*] 驗證每個 Pod 的節點映射${NC}"
echo ""

FAILED=0

for ((i=0; i<NUM_PODS; i++)); do
    POD_NAME="${POD_PREFIX}-${i}"
    
    TEMP_POD=$(mktemp)
    kubectl exec pod/$POD_NAME -n $NAMESPACE -- redis-cli -a $REDIS_PASSWORD cluster nodes > $TEMP_POD 2>/dev/null || {
        echo -e "${RED}[✗] $POD_NAME: 無法連接${NC}"
        FAILED=1
        rm -f $TEMP_POD
        continue
    }
    
    echo -n "    $POD_NAME: "
    
    MATCH=1
    TEMP_POD_MAP=$(mktemp)
    
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        NODE_ID=$(echo $line | awk '{print $1}')
        NODE_ADDR=$(echo $line | awk '{print $2}')
        NODE_IP=$(echo $NODE_ADDR | cut -d: -f1)
        
        echo "$NODE_ID:$NODE_IP" >> $TEMP_POD_MAP
    done < $TEMP_POD
    
    while IFS= read -r standard_line; do
        STANDARD_NODE_ID=$(echo $standard_line | cut -d: -f1)
        STANDARD_NODE_IP=$(echo $standard_line | cut -d: -f2)
        
        POD_NODE_IP=$(grep "^$STANDARD_NODE_ID:" $TEMP_POD_MAP | cut -d: -f2 || echo "")
        
        if [ -z "$POD_NODE_IP" ]; then
            echo -e "${RED}[✗] 缺少節點 $STANDARD_NODE_ID${NC}"
            MATCH=0
            FAILED=1
        elif [ "$STANDARD_NODE_IP" != "$POD_NODE_IP" ]; then
            echo -e "${RED}[✗] Node ID $STANDARD_NODE_ID IP 不符${NC}"
            echo "         標準: $STANDARD_NODE_IP, $POD_NAME: $POD_NODE_IP"
            MATCH=0
            FAILED=1
        fi
    done < $TEMP_STANDARD_MAP
    
    if [ $MATCH -eq 1 ]; then
        echo -e "${GREEN}[✓] 完全一致${NC}"
    fi
    
    rm -f $TEMP_POD $TEMP_POD_MAP
done

rm -f $TEMP_STANDARD_MAP

echo ""
echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"

if [ $FAILED -eq 0 ]; then
    echo -e "${YELLOW}║${NC} ${GREEN}[✓] 所有 Pod 的節點映射完全一致！${NC} ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${YELLOW}║${NC} ${RED}[✗] 發現不一致，請檢查${NC} ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi
