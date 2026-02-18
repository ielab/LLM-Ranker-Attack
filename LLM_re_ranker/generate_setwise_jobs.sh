#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration
# =========================
MODELS=(
  "Qwen/Qwen3-32B"
  "Qwen/Qwen3-30B-A3B"
  "google/gemma-3-27b-it"
)

DATASETS=(
  "msmarco-passage/trec-dl-2019"
  "msmarco-passage/trec-dl-2020"
)

ATTACKS=(none so sd) # Options: none (no attack), so (DOH), sd (DCH)
POSITIONS=(back front) # Options: back, front

declare -A RUN_PATHS=(
  ["msmarco-passage/trec-dl-2019"]="run.msmarco-v1-passage.bm25-default.dl19.txt"
  ["msmarco-passage/trec-dl-2020"]="run.msmarco-v1-passage.bm25-default.dl20.txt"
)

# =========================
# Experiment Parameters
# =========================
HITS="${HITS:-100}"
Q_LEN="${Q_LEN:-32}"
P_LEN="${P_LEN:-128}"
NUM_CHILD="${NUM_CHILD:-3}"
K="${K:-10}"

mkdir -p logs outputs

sanitize() {
  local s="${1//\//__}"  # Replace / with __
  s="${s// /_}"
  s="${s//-/_}"
  echo "$s"
}

generate_run_script() {
  local model="$1"
  local dataset="$2"
  local attack="$3"
  local position="$4"

  local model_short="${model##*/}"
  local model_tag
  model_tag="$(sanitize "$model_short")"
  local dataset_tag
  dataset_tag="$(sanitize "$dataset")"

  local script_tag="${model_tag}_${dataset_tag}_${attack}_${position}"
  local script_file="run_${script_tag}.sh"

  local RUN_PATH="${RUN_PATHS[$dataset]}"

  cat > "${script_file}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "Starting re-ranker experiment"
echo "============================================================"

MODEL_NAME="MODEL_PLACEHOLDER"
MODEL_TAG="MODEL_TAG_PLACEHOLDER"
DATASET="DATASET_PLACEHOLDER"
ATTACK_TYPE="ATTACK_PLACEHOLDER"
ATTACK_POS="POSITION_PLACEHOLDER"

RUN_PATH="RUN_PATH_PLACEHOLDER"
HITS=HITS_PLACEHOLDER
Q_LEN=Q_LEN_PLACEHOLDER
P_LEN=P_LEN_PLACEHOLDER
NUM_CHILD=NUM_CHILD_PLACEHOLDER
K=K_PLACEHOLDER

DATASET_SHORT=$(echo "${DATASET}" | cut -d'/' -f2-)

# Map IR dataset name to pyserini eval collection name
case "${DATASET}" in
  "msmarco-passage/trec-dl-2019")
    EVAL_COLLECTION="dl19-passage"
    ;;
  "msmarco-passage/trec-dl-2020")
    EVAL_COLLECTION="dl20-passage"
    ;;
  *)
    EVAL_COLLECTION="${DATASET_SHORT}"
    ;;
esac

echo ""
echo "############################################################"
echo "MODEL: ${MODEL_NAME}"
echo "DATASET: ${DATASET}"
echo "EVAL_COLLECTION: ${EVAL_COLLECTION}"
echo "ATTACK: ${ATTACK_TYPE}"
echo "POSITION: ${ATTACK_POS}"
echo "############################################################"
echo ""

# Determine output path
if [ "${ATTACK_TYPE}" = "none" ]; then
  SAVE_PATH="outputs/run.setwise.heapsort.${MODEL_TAG}.${DATASET_SHORT}.baseline.txt"
else
  SAVE_PATH="outputs/run.setwise.heapsort.${MODEL_TAG}.${DATASET_SHORT}.${ATTACK_TYPE}.${ATTACK_POS}.txt"
fi

mkdir -p "$(dirname "${SAVE_PATH}")"

echo ""
echo "------------------------------------------------------------"
echo "Output: ${SAVE_PATH}"
echo "------------------------------------------------------------"

python3 run_attack.py \
  run --model_name_or_path "${MODEL_NAME}" \
      --tokenizer_name_or_path "${MODEL_NAME}" \
      --run_path "${RUN_PATH}" \
      --save_path "${SAVE_PATH}" \
      --ir_dataset_name "${DATASET}" \
      --hits "${HITS}" \
      --query_length "${Q_LEN}" \
      --passage_length "${P_LEN}" \
      --scoring generation \
      --device cuda \
      --attack_type "${ATTACK_TYPE}" \
      --attack_position "${ATTACK_POS}" \
  setwise --num_child "${NUM_CHILD}" \
          --method heapsort \
          --k "${K}"

echo ">>> Evaluating NDCG@10"
python -m pyserini.eval.trec_eval -c -l 2 -m ndcg_cut.10 ${EVAL_COLLECTION} "${SAVE_PATH}"

echo ""
echo "============================================================"
echo "Completed: ${MODEL_TAG} | ${DATASET} | ${ATTACK_TYPE} | ${ATTACK_POS}"
echo "============================================================"
EOF

  # Replace placeholders
  sed -i "s|MODEL_PLACEHOLDER|${model}|g" "${script_file}"
  sed -i "s|MODEL_TAG_PLACEHOLDER|${model_tag}|g" "${script_file}"
  sed -i "s|DATASET_PLACEHOLDER|${dataset}|g" "${script_file}"
  sed -i "s|ATTACK_PLACEHOLDER|${attack}|g" "${script_file}"
  sed -i "s|POSITION_PLACEHOLDER|${position}|g" "${script_file}"
  sed -i "s|RUN_PATH_PLACEHOLDER|${RUN_PATH}|g" "${script_file}"
  sed -i "s|HITS_PLACEHOLDER|${HITS}|g" "${script_file}"
  sed -i "s|Q_LEN_PLACEHOLDER|${Q_LEN}|g" "${script_file}"
  sed -i "s|P_LEN_PLACEHOLDER|${P_LEN}|g" "${script_file}"
  sed -i "s|NUM_CHILD_PLACEHOLDER|${NUM_CHILD}|g" "${script_file}"
  sed -i "s|K_PLACEHOLDER|${K}|g" "${script_file}"

  chmod +x "${script_file}"
  echo "${script_file}"
}

# Generate scripts
count=0

for model in "${MODELS[@]}"; do
  for dataset in "${DATASETS[@]}"; do
    for attack in "${ATTACKS[@]}"; do
      # For "none" attack, only run once (position doesn't matter)
      if [ "${attack}" = "none" ]; then
        positions_to_run=("back")
      else
        positions_to_run=("${POSITIONS[@]}")
      fi
      
      for position in "${positions_to_run[@]}"; do
        script_file="$(generate_run_script "$model" "$dataset" "$attack" "$position")"
        count=$((count + 1))
        echo "Generated: ${script_file}"
      done
    done
  done
done

echo ""
echo "============================================================"
echo "Total scripts generated: ${count}"
echo "============================================================"
echo ""
echo "To run an experiment, execute any generated script, e.g.:"
echo "  bash run_Qwen3-32B_trec-dl-2019_none_back.sh"
echo ""
