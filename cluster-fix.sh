#!/bin/bash

# Redis Cluster 修復 + 驗證一體化腳本
# 用途：修復 restart 後的舊 IP 問題，並驗證所有節點映射一致
#
# 使用方式：
#   bash ./cluster-fix.sh [namespace] [pod_prefix]
#
# 範例：
#   bash ./cluster-fix.sh default               # 使用預設 pod_prefix=redis-cluster
#   bash ./cluster-fix.sh redis-i32 my-redis    # 自訂 pod_prefix
#   DEBUG=1 bash ./cluster-fix.sh default       # 只預覽，不執行修復
#
# 預設值：
#   namespace: redis-i4 (pattern: redis-i{1..100})
#   pod_prefix: redis-cluster
#   num_pods: 自動偵測

set -e

# ===== 配置 =====
DEFAULT_NAMESPACE="redis-i4"
DEFAULT_POD_PREFIX="redis-cluster"

# 從命令行參數讀取
NAMESPACE="${1:-$DEFAULT_NAMESPACE}"
POD_PREFIX="${2:-$DEFAULT_POD_PREFIX}"
DEBUG="${DEBUG:-0}"

# 動態獲取 NUM_PODS（計算有多少個 $POD_PREFIX-* 的 Pod）
NUM_PODS=$(kubectl get pod -n $NAMESPACE -o name 2>/dev/null | grep "pod/${POD_PREFIX}-[0-9]" | wc -l)
if [ $NUM_PODS -eq 0 ]; then
    echo -e "${RED}[!] 找不到符合 '${POD_PREFIX}-*' 的 Pod 在 namespace '$NAMESPACE'${NC}"
    exit 1
fi

# 從 Pod env 自動獲取 REDIS_PASSWORD
REDIS_PASSWORD=$(kubectl exec pod/${POD_PREFIX}-0 -n $NAMESPACE -- env 2>/dev/null | grep "^REDIS_PASSWORD=" | cut -d= -f2)
if [ -z "$REDIS_PASSWORD" ]; then
    echo -e "${RED}[!] 無法獲取 Redis 密碼${NC}"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║     Redis Cluster 修復 + 驗證一體化工具                   ║${NC}"
echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}[*] 配置信息${NC}"
echo "    Namespace: $NAMESPACE"
echo "    Pod Prefix: $POD_PREFIX"
echo "    Pod 數量: $NUM_PODS"
echo ""

# ===== 驗證函數 =====
verify_cluster() {
    local PHASE=$1  # "BEFORE" 或 "AFTER"
    
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
    echo "    標準映射包含 $STANDARD_COUNT 個節點信息"
    echo ""
    
    echo -e "${BLUE}[*] 驗證每個 Pod 的節點映射${NC}"
    echo ""
    
    local FAILED=0
    local INCONSISTENT_PODS=()
    
    for ((i=0; i<NUM_PODS; i++)); do
        POD_NAME="${POD_PREFIX}-${i}"
        
        TEMP_POD=$(mktemp)
        kubectl exec pod/$POD_NAME -n $NAMESPACE -- redis-cli -a $REDIS_PASSWORD cluster nodes > $TEMP_POD 2>/dev/null || {
            echo -e "    ${RED}[✗] $POD_NAME: 無法連接${NC}"
            FAILED=1
            rm -f $TEMP_POD
            continue
        }
        
        echo -n "    $POD_NAME: "
        
        local MATCH=1
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
        else
            INCONSISTENT_PODS+=($POD_NAME)
        fi
        
        rm -f $TEMP_POD $TEMP_POD_MAP
    done
    
    rm -f $TEMP_STANDARD $TEMP_STANDARD_MAP
    
    echo ""
    if [ $FAILED -eq 0 ] && [ ${#INCONSISTENT_PODS[@]} -eq 0 ]; then
        echo -e "${GREEN}[✓] [$PHASE] 所有 Pod 的節點映射完全一致！${NC}"
        return 0
    else
        if [ ${#INCONSISTENT_PODS[@]} -gt 0 ]; then
            echo -e "${RED}[✗] [$PHASE] 發現 ${#INCONSISTENT_PODS[@]} 個 Pod 不一致${NC}"
            echo "    不一致的 Pod: ${INCONSISTENT_PODS[*]}"
        fi
        return 1
    fi
}

# ===== PART 1: 前置掃描 =====
echo -e "${YELLOW}[=== PART 0: 掃描問題（BEFORE）===]${NC}"
echo ""
verify_cluster "BEFORE" || BEFORE_RESULT=1
BEFORE_RESULT=${BEFORE_RESULT:-0}

if [ $BEFORE_RESULT -eq 0 ]; then
    echo ""
    echo -e "${GREEN}[✓] Cluster 已經是健康狀態，無需修復！${NC}"
    exit 0
fi

# ===== 自動進行修復 =====
echo ""
echo -e "${YELLOW}[!] 檢測到問題，開始執行修復...${NC}"
echo ""

# ===== PART 1: 修復 =====
echo -e "${YELLOW}[=== PART 1: 執行修復 ===]${NC}"
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
    if [ "$DEBUG" = "1" ]; then
        for ((j=0; j<NUM_PODS; j++)); do
            echo "        [DEBUG] MEET ${POD_IPS[$j]}:6379"
        done
    else
        for ((j=0; j<NUM_PODS; j++)); do
            kubectl exec pod/$POD_NAME -n $NAMESPACE -- redis-cli -a $REDIS_PASSWORD cluster meet ${POD_IPS[$j]} 6379 > /dev/null 2>&1
        done
    fi
    
    if [ $FORGOT_COUNT -gt 0 ]; then
        echo -e "    ${GREEN}[✓] FORGET $FORGOT_COUNT 個舊節點 + MEET 所有 $NUM_PODS 個新節點${NC}"
    else
        echo -e "    ${GREEN}[✓] MEET 所有 $NUM_PODS 個新節點${NC}"
    fi
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

# ===== PART 2: 後置驗證 =====
echo -e "${YELLOW}[=== PART 2: 驗證修復結果（AFTER）===]${NC}"
echo ""
verify_cluster "AFTER"
AFTER_RESULT=$?

echo ""
echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"

if [ $AFTER_RESULT -eq 0 ]; then
    echo -e "${YELLOW}║${NC} ${GREEN}[✓] 修復成功！所有 Pod 已同步${NC} ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    
    # ===== 詳細檢查結果 =====
    echo ""
    echo -e "${YELLOW}[=== 詳細檢查結果 ===]${NC}"
    echo ""
    echo -e "${BLUE}[*] 各 Pod 的 cluster nodes 信息（按 IP 排序）${NC}"
    echo ""
    
    for ((i=0; i<NUM_PODS; i++)); do
        POD_NAME="${POD_PREFIX}-${i}"
        
        echo -e "${BLUE}--- $POD_NAME ---${NC}"
        kubectl exec pod/$POD_NAME -n $NAMESPACE -- redis-cli -a $REDIS_PASSWORD cluster nodes 2>/dev/null | sort -t: -k1.16,1
        echo ""
    done
    
    echo ""
    exit 0
else
    echo -e "${YELLOW}║${NC} ${RED}[✗] 修復後仍有問題，請檢查${NC} ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi
