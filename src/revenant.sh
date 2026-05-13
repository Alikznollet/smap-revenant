#!/bin/bash

# DEFAULT VALUES

# true  -> Overwrite reference files with current results.
# false -> Compare current results against reference and report errors.
UPDATE_REFS=false
CORES=4
DATA_DIR="$PWD/smap_data"
REF_DIR="$PWD/reference_data"

# These are standardized flags but can be overwritten with --smap-args
SMAP_FLAGS="-f 5 -c 30 -e dosage -i diploid -z 2"

# Parse arguments
# u: If passed reference data will be updated.
while getopts "uc:h" opt; do
    case $opt in 
        u)  UPDATE_REFS=true ;;
        c)  CORES="$OPTARG" ;;
        h) 
            echo "Usage: revenant [-u]"
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
    esac
done

# Setup the paths. Also make sure they exist.
BENCHMARK_DIR="$PWD/benchmark"
LOG_DIR="$BENCHMARK_DIR/logs"
mkdir -p "$BENCHMARK_DIR"
mkdir -p "$LOG_DIR"

# Set up the output and log files.
TIMESTAMP=$(date +%Y%m%d_%H%M)
MASTER_CSV="$BENCHMARK_DIR/revenant_benchmark_${TIMESTAMP}.csv"
SMAP_LOG="$LOG_DIR/benchmark_benchmark_${TIMESTAMP}.log"

# Specific SMAP flags
# * NOTE: We don't include "--plot all" because this could take a while and we are
# * not optimizing that part of the project.
# * We use 4 cores for benchmarking.
SMAP_FLAGS="-f 5 -c 30 -e dosage -i diploid -z 2 -p $CORES"

# Defines what files to skip for the run.
SKIP_LIST=("testset2")

# Ensures no leftover files stay if you CTRL+C or when the script crashes.
cleanup() {
  echo "Cleaning up temporary files..."
  rm -rf "$HOME"/smap_bench_*
}
trap 'echo "Interrupted!"; cleanup; exit 1' INT TERM
trap cleanup EXIT

# Tracking variable to handle the CSV header
FIRST_RUN=true

# Check dependencies.
if ! command -v awk &> /dev/null; then
    echo "Awk not found. Installing gawk..."
    sudo dnf5 install -y gawk
fi
if ! [ -x "/usr/bin/time" ]; then
    echo "Installing GNU time..."
    sudo dnf5 install -y time
fi

echo "STARTING SMAP BENCHMARKS"

# Loop over all files in the smap data folder that could be test data.
for SOURCE_ZIP in "$HOME/smap_data"/*.tar.gz; do
    [ -e "$SOURCE_ZIP" ] || continue # Handle empty directory
    DATASET_ID=$(basename "$SOURCE_ZIP" .tar.gz)

    if [[ " ${SKIP_LIST[@]} " =~ " ${DATASET_ID} " ]]; then
        echo "SKIPPING $DATASET_ID: Marked as 'Heavy' (Run on HPC only)"
        continue
    fi
    
    echo "----------------------------------"
    echo "PROCESSING: $DATASET_ID"
    echo "----------------------------------"

    echo "Extracting Data..."

    # Extraction and discovery.
    SCRATCH_DIR=$(mktemp -d -p "$HOME" -t "smap_bench_XXXX")
    tar --warning=no-unknown-keyword -zxf "$SOURCE_ZIP" -C "$SCRATCH_DIR"

    echo "Extracting Finished!"

    # Sanitization.
    find "$SCRATCH_DIR" -name "._*" -delete
    find "$SCRATCH_DIR" -name ".DS_Store" -delete
    rm -rf "$SCRATCH_DIR/__MACOSX"

    # Set inputs up.
    BASE_DATA_DIR=$(find "$SCRATCH_DIR" -maxdepth 1 -type d -not -path "$SCRATCH_DIR" -not -name ".*" | head -n 1)
    GENOME=$(find "$BASE_DATA_DIR" -not -name ".*" \( -name "*.fasta" -o -name "*.fa" \) | head -n 1)
    BORDERS=$(find "$BASE_DATA_DIR" -not -name ".*" \( -name "*.gff" -o -name "*.bed" \) | head -n 1)
    BAM_DIR=$(find "$BASE_DATA_DIR" -not -name ".*" -type d -exec sh -c 'ls -1 "{}"/*.bam >/dev/null 2>&1' \; -print | head -n 1)
    FASTQ_DIR=$(find "$BASE_DATA_DIR" -not -name ".*" -type d -exec sh -c 'ls -1 "{}"/*.fq* >/dev/null 2>&1' \; -print | head -n 1)
    OUT_DIR="$SCRATCH_DIR/output"
    mkdir -p "$OUT_DIR"

    # Clear caches
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

    # Create Temp CSV and log for this run.
    TEMP_CSV="${SCRATCH_DIR}/run_results.csv"
    MEM_LOG="${SCRATCH_DIR}/ram_usage.log"

    # Write a header per file to the log file.
    echo -e "\n========================================" >> "$SMAP_LOG"
    echo "SMAP LOGS FOR: $DATASET_ID" >> "$SMAP_LOG"
    echo "========================================" >> "$SMAP_LOG"
    
    # Run HyperFine.
    hyperfine --warmup 0 --runs 1 --show-output \
      --prepare "sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'" \
      --command-name "$DATASET_ID" \
      --export-csv "$TEMP_CSV" \
      "/usr/bin/time -a -f '%M' -o $MEM_LOG smap haplotype-window \"$GENOME\" \"$BORDERS\" \"$BAM_DIR\" \"$FASTQ_DIR\" -o \"$OUT_DIR/$DATASET_ID\" $SMAP_FLAGS 2>> \"$SMAP_LOG\""

    # Calculate RAM values.
    AVG_RAM=$(awk '{ sum += $1; n++ } END { if (n > 0) printf "%.0f", sum / n; }' "$MEM_LOG")
    MAX_RAM=$(sort -rn "$MEM_LOG" | head -n 1)

    REF_DIR="$HOME/Projects/project-smap-Alikznollet-1/reference_data/$DATASET_ID"
    mkdir -p "$REF_DIR"

    # Either update references or verify existing ones.
    if [ "$UPDATE_REFS" = true ]; then
        echo "UPDATING REFERENCES for $DATASET_ID..."
        cp "$OUT_DIR"/*.tsv "$REF_DIR/"
    else
        echo "VERIFYING OUTPUTS for $DATASET_ID..."
        FAILED_VERIFICATION=false
        
        # Check every file currently in your reference folder
        for REF_FILE in "$REF_DIR"/*.tsv; do
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
                
                # Write the actual differences to your global log file
                echo -e "\n--- DIFF DETECTED IN $FILENAME ---" >> "$SMAP_LOG"
                diff -u <(grep -v "^#" "$REF_FILE" | sort) <(grep -v "^#" "$NEW_FILE" | sort) >> "$SMAP_LOG"
                
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
    rm -rf "$SCRATCH_DIR"
    echo "Finished Benchmark for $DATASET_ID."
    sleep 10s # Sleep for a sec so the OS can clear memory.
done

echo "Combined CSV results saved to: $MASTER_CSV"
