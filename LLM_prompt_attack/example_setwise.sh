#!/usr/bin/env bash
# Minimal example for running setwise ranking attack

set -euo pipefail

# Configuration - Modify these as needed
MODEL_NAME="Qwen/Qwen3-1.7B"
MODEL_SHORT="Qwen3-1.7B"
DATASET="msmarco-passage/trec-dl-2019"
ATTACK_TYPE="so"  # Options: so (DOH), sd (DCH)
ATTACK_POSITION="back"  # Options: back, front

# Parameters
NUM_SAMPLES=1024  # use 4096 for full experiments
SET_SIZE=4
N_JOBS=4
PORT=8000

# vLLM Server Parameters
GPU_MEMORY_UTILIZATION=0.85
MAX_MODEL_LEN=32768
MAX_NUM_SEQS=8
SERVER_WAIT_TIMEOUT=900

BASE_URL="http://localhost:${PORT}/v1"
SERVER_PID=""
SERVER_LOG="logs/vllm_server_${PORT}.log"

mkdir -p logs outputs

cleanup() {
  echo "[Cleanup] Stopping vLLM server..."
  if [ -n "${SERVER_PID}" ]; then
    kill ${SERVER_PID} 2>/dev/null || true
    wait ${SERVER_PID} 2>/dev/null || true
  fi
  pkill -f "vllm.entrypoints" 2>/dev/null || true
  echo "[Cleanup] Done."
}
trap cleanup EXIT INT TERM

start_vllm_server() {
  echo "[Server] Starting vLLM on port ${PORT}"
  python -m vllm.entrypoints.openai.api_server \
    --model "${MODEL_NAME}" \
    --port ${PORT} \
    --gpu-memory-utilization ${GPU_MEMORY_UTILIZATION} \
    --max-model-len ${MAX_MODEL_LEN} \
    --max-num-seqs ${MAX_NUM_SEQS} \
    --dtype bfloat16 \
    --trust-remote-code \
    --served-model-name "${MODEL_SHORT}" \
    > "${SERVER_LOG}" 2>&1 &

  SERVER_PID=$!
  local waited=0
  while [ ${waited} -lt ${SERVER_WAIT_TIMEOUT} ]; do
    if ! kill -0 ${SERVER_PID} 2>/dev/null; then
      echo "[Server] Process died unexpectedly"
      tail -200 "${SERVER_LOG}" || true
      exit 1
    fi
    if curl -sf --max-time 5 "${BASE_URL}/models" >/dev/null 2>&1; then
      echo "[Server] Ready after ${waited}s"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "[Server] Startup timeout"
  tail -200 "${SERVER_LOG}" || true
  exit 1
}

echo "============================================================"
echo "Starting Setwise Ranking Attack Example"
echo "Model: ${MODEL_NAME}"
echo "Dataset: ${DATASET}"
echo "Attack: ${ATTACK_TYPE} at position ${ATTACK_POSITION}"
echo "============================================================"

start_vllm_server

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="outputs/${DATASET}/${MODEL_SHORT}/setwise"
mkdir -p "${OUT_DIR}"

OUT_FILE="${OUT_DIR}/result_${MODEL_SHORT}_setwise_${ATTACK_TYPE}_${ATTACK_POSITION}_${TIMESTAMP}.jsonl"
DETAIL_FILE="${OUT_DIR}/detail_${MODEL_SHORT}_setwise_${ATTACK_TYPE}_${ATTACK_POSITION}_${TIMESTAMP}.json"

echo ""
echo "Running experiment..."
echo "Output: ${OUT_FILE}"

python setwise_ranking_attack_openai.py \
  --model_name "${MODEL_SHORT}" \
  --base_url "${BASE_URL}" \
  --attack_type "${ATTACK_TYPE}" \
  --attack_position "${ATTACK_POSITION}" \
  --dataset_name "${DATASET}" \
  --n_jobs ${N_JOBS} \
  --result_json_path "${OUT_FILE}" \
  --tokenizer_model "${MODEL_NAME}" \
  --detailed_results "${DETAIL_FILE}" \
  --num_sets ${NUM_SAMPLES} \
  --set_size ${SET_SIZE}

echo ""
echo "============================================================"
echo "Experiment completed!"
echo "Results saved to: ${OUT_FILE}"
echo "============================================================"
