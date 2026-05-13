#!/bin/bash

# DEFAULT VALUES

# true  -> Overwrite reference files with current results.
# false -> Compare current results against reference and report errors.
UPDATE_REFS=false
CORES=4
DATA_DIR="$PWD/smap_data"
REF_DIR="$PWD/reference_data"

# The default benchmark setup.
RUNS=5
WARMUP=1

# These are standardized flags but can be overwritten with --smap-args
SMAP_FLAGS="-f 5 -c 30 -e dosage -i diploid -z 2"

# Defines what files to skip for the run.
SKIP_LIST=()

# PARSING ARGUMENTS

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -u|--update)
            UPDATE_REFS=true
            shift 1
            ;;
        -c|--cores)
            CORES="$2"
            shift 2
            ;;
        -d|--data-dir)
            DATA_DIR="$2"
            shift 2
            ;;
        -r|--ref-dir)
            REF_DIR="$2"
            shift 2
            ;;
        -s|--skip)
            SKIP_LIST+=("$2")
            shift 2
            ;;
        --smap-args)
            # This overwrites the default algorithmic flags.
            SMAP_FLAGS="$2"
            shift 2
            ;;
        --runs)
            RUNS="$2"
            shift 2
            ;;
        --warmup)
            WARMUP="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: revenant [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -u, --update         Overwrite reference files with current results."
            echo "  -c, --cores <int>    Number of CPU cores to use (default: 4)."
            echo "  -d, --data-dir <dir> Path to input datasets tar.gz files (default: ./smap_data)."
            echo "  -r, --ref-dir <dir>  Path to reference data for verification (default: ./reference_data)."
            echo "  -s, --skip <name>    Name of a dataset to skip, this argument can be passed mutliple times."
            echo "  --runs <int>         The amount of runs to benchmark and take averages from (default: 5)."
            echo "  --warmup <int>       The amount of warmup runs to do before benchmarking begins (default: 1)."
            echo "  --smap-args <str>    Override core SMAP algorithmic flags."
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# DEPENDENCY CHECK

for cmd in awk hyperfine; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' is not installed or not in PATH." >&2
        echo "Install via your local package manager!" >&2
        exit 1
    fi
done

TIME_CMD=$(type -P gtime || type -P time)

# Check if we found a path, and if it supports GNU flags
if [ -z "$TIME_CMD" ] || ! "$TIME_CMD" -o /dev/null true &>/dev/null; then
    echo "Error: GNU 'time' utility not found or doesn't support required flags." >&2
    echo "Linux: Install 'time' (e.g., sudo dnf install time)" >&2
    echo "macOS: Install 'gnu-time' (e.g., brew install gnu-time)" >&2
    exit 1
fi

# CHECK VENV SETUP

VENV_ACTIVATE="$PWD/.venv/bin/activate"

# Check whether the venv exists
if [ ! -f "$VENV_ACTIVATE" ]; then
    echo "Error: Virtual environment activation script missing at $VENV_ACTIVATE" >&2
    echo "Is the venv initialized?"
    exit 1
fi

# Source the venv and if it fails immediately exit.
set +u
# shellcheck source=/dev/null
source "$VENV_ACTIVATE" || { echo "Failed to activate venv." >&2; exit 1; }
set -u

if [ -z "${VIRTUAL_ENV:-}" ]; then
    echo "Error: venv failed to engage properly." >&2
    exit 1
fi

echo "Venv successfully engaged: $VIRTUAL_ENV"

# Setup the benchmark and logs dir. Also make sure they exist.
BENCHMARK_DIR="$PWD/benchmark"
LOG_DIR="$BENCHMARK_DIR/logs"
mkdir -p "$BENCHMARK_DIR"
mkdir -p "$LOG_DIR"

# Set up the output and log files.
TIMESTAMP=$(date +%Y%m%d_%H%M)
MASTER_CSV="$BENCHMARK_DIR/revenant_benchmark_${TIMESTAMP}.csv"
SMAP_LOG="$LOG_DIR/benchmark_benchmark_${TIMESTAMP}.log"

# Log setup to ensure important metadata is included in LOG
exec > >(tee -a "$SMAP_LOG") 2>&1

# Ensures no leftover files stay if you CTRL+C or when the script crashes.
cleanup() {
  echo "Cleaning up temporary files..."
  rm -rf /tmp/smap_bench_*
}
trap 'echo "Interrupted!"; cleanup; exit 1' INT TERM
trap cleanup EXIT

# Force the RUNS and WARMUP variables if updating references.
if [ "$UPDATE_REFS" = true ]; then
    # If the user explicitly passed custom runs/warmups but is updating references,
    # silently clamp them to baseline defaults to prevent wasted compute.
    if [ "$RUNS" -ne 1 ] || [ "$WARMUP" -ne 0 ]; then
        echo "[Notice]: Update flag (-u) detected. Forcing runs=1 and warmup=0 to generate clean baselines."
    fi
    RUNS=1
    WARMUP=0
fi

# Check if the data is there.
if [ ! -d "$DATA_DIR" ]; then
    echo "Error: Directory does not exist: $DATA_DIR" >&2
    exit 1
fi

shopt -s nullglob
FILES=("$DATA_DIR"/*.tar.gz)
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
    echo "Error: No dataset archives (.tar.gz) found in: $DATA_DIR" >&2
    echo "Please check your --data-dir path or add files to the folder." >&2
    exit 1
fi

# Build the flags used by the command
FINAL_SMAP_FLAGS="$SMAP_FLAGS -p $CORES"
FIRST_RUN=true

echo "Configured Data dir: $DATA_DIR"
echo "Configured Ref dir: $REF_DIR"
echo "Benchmark config: Runs: $RUNS | Warmups: $WARMUP"
echo "Datasets to skip: ${SKIP_LIST[*]:-None}"
echo "Executing SMAP with: $FINAL_SMAP_FLAGS"

echo "STARTING SMAP BENCHMARKS"

# Loop over all files in the smap data folder that could be test data.
for SOURCE_ZIP in "${FILES[@]}"; do
    [ -e "$SOURCE_ZIP" ] || continue # Handle empty directory
    DATASET_ID=$(basename "$SOURCE_ZIP" .tar.gz)

    # Skip the dataset if the user asked for it.
    SKIP_DATASET=false
    for skip_item in "${SKIP_LIST[@]}"; do
        if [[ "$skip_item" == "$DATASET_ID" ]]; then
            SKIP_DATASET=true
            break
        fi
    done

    if [[ "$SKIP_DATASET" == true ]]; then
        echo "SKIPPING $DATASET_ID: Requested via command line."
        continue
    fi
    
    echo "----------------------------------"
    echo "PROCESSING: $DATASET_ID"
    echo "----------------------------------"

    echo "Extracting Data..."

    # Extraction
    SCRATCH_DIR=$(mktemp -d -t "smap_bench_XXXX")
    tar --warning=no-unknown-keyword \
        --exclude='__MACOSX' \
        --exclude='._*' \
        --exclude='.DS_Store' \
        -zxf "$SOURCE_ZIP" -C "$SCRATCH_DIR"

    echo "Extraction Finished!"

    # Discovery

    GENOME=$(find "$SCRATCH_DIR" -type f -not -name ".*" -not -name "._*" \( -name "*.fasta" -o -name "*.fa" \) | sort | head -n 1)

    # If we lack a genome then it's invalid
    if [ -z "$GENOME" ]; then
        echo "Error: no .fasta or .fa reference genome found for $DATASET_ID. Skipping..." >&2
        continue
    fi

    # Set inputs up.
    BASE_DATA_DIR=$(dirname "$GENOME")
    BORDERS=$(find "$BASE_DATA_DIR" -not -name ".*" \( -name "*.gff" -o -name "*.bed" \) | sort | head -n 1)

    FIRST_BAM=$(find "$BASE_DATA_DIR" -not -name ".*" -name "*.bam" | sort | head -n 1)
    FIRST_FASTQ=$(find "$BASE_DATA_DIR" -not -name ".*" \( -name "*.fq*" -o -name "*.fastq*" \) | sort | head -n 1)

    BAM_DIR=${FIRST_BAM:+$(dirname "$FIRST_BAM")}
    FASTQ_DIR=${FIRST_FASTQ:+$(dirname "$FIRST_FASTQ")}

    OUT_DIR="$SCRATCH_DIR/output"
    mkdir -p "$OUT_DIR"

    # Create Temp CSV and log for this run.
    TEMP_CSV="${SCRATCH_DIR}/run_results.csv"
    MEM_LOG="${SCRATCH_DIR}/ram_usage.log"
    
    # Run HyperFine.
    hyperfine --warmup "$WARMUP" --runs "$RUNS" \
      --prepare "sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'" \
      --command-name "$DATASET_ID" \
      --export-csv "$TEMP_CSV" \
      "$TIME_CMD -a -f '%M' -o $MEM_LOG smap haplotype-window \"$GENOME\" \"$BORDERS\" \"$BAM_DIR\" \"$FASTQ_DIR\" -o \"$OUT_DIR/$DATASET_ID\" $FINAL_SMAP_FLAGS >> \"$SMAP_LOG\" 2>&1"

    # Calculate RAM values.
    AVG_RAM=$(awk '{ sum += $1; n++ } END { if (n > 0) printf "%.0f", sum / n; }' "$MEM_LOG")
    MAX_RAM=$(sort -rn "$MEM_LOG" | head -n 1)

    CURRENT_REF_DIR="$REF_DIR/$DATASET_ID"
    mkdir -p "$CURRENT_REF_DIR"

    # Either update references or verify existing ones.
    if [ "$UPDATE_REFS" = true ]; then
        echo "UPDATING REFERENCES for $DATASET_ID..."
        cp "$OUT_DIR"/*.tsv "$CURRENT_REF_DIR/"
    else
        echo "VERIFYING OUTPUTS for $DATASET_ID..."
        FAILED_VERIFICATION=false
        
        # Check every file currently in your reference folder
        for REF_FILE in "$CURRENT_REF_DIR"/*.tsv; do
            [ -e "$REF_FILE" ] || continue
            FILENAME=$(basename "$REF_FILE")
            NEW_FILE="$OUT_DIR/$FILENAME"

            if [ ! -f "$NEW_FILE" ]; then
                echo "[MISSING]: $FILENAME was not generated!"
                FAILED_VERIFICATION=true
                continue
            fi

            # Using diff to check for content equality
            # Sort both files before comparing to ignore row order differences
            if diff -q <(grep -v "^#" "$REF_FILE" | sort) <(grep -v "^#" "$NEW_FILE" | sort) > /dev/null; then
                echo "[MATCH]: $FILENAME"
            else
                echo "[DIFF]: $FILENAME differs from reference! (Check log for details)"
                diff -u <(grep -v "^#" "$REF_FILE" | sort) <(grep -v "^#" "$NEW_FILE" | sort) >> "$SMAP_LOG" 2>&1
                FAILED_VERIFICATION=true
            fi
        done

        if [ "$FAILED_VERIFICATION" = true ]; then
            echo "REGRESSION DETECTED in $DATASET_ID results."
            exit 1 # If Diffs detected we stop the script instantly.
        fi
    fi

    # Append to master CSV.
    if [ "$FIRST_RUN" = true ]; then
        # Create the master file and write the header with RAM columns.
        HEADER=$(head -n 1 "$TEMP_CSV")
        echo "${HEADER},avg_ram_kb,max_ram_kb" > "$MASTER_CSV"
        FIRST_RUN=false
    fi

    # ALWAYS append the data row + RAM.
    DATA_ROW=$(tail -n 1 "$TEMP_CSV")
    echo "${DATA_ROW},${AVG_RAM},${MAX_RAM}" >> "$MASTER_CSV"

    # Cleanup dataset from scratch to save disk space.
    rm -rf "${SCRATCH_DIR:?}"
    echo "Finished Benchmark for $DATASET_ID."
    sleep 10s # Sleep for a sec so the OS can clear memory.
done

echo "Finished all Benchmarks!"
echo "CSV results saved to: $MASTER_CSV"
