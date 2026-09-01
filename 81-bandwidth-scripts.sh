#!/usr/bin/env bash
# ==============================================================================
# Linux Hardware Bandwidth Benchmark & Aggregator
# Measures: System RAM (STREAM), PCIe Link/Throughput, and GPU VRAM Bandwidth
# ==============================================================================

set -uo pipefail

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Formatting helpers
BOLD='\033[1;37m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}======================================================${NC}"
echo -e "${BOLD}${CYAN}    System, PCIe & Memory Bandwidth Benchmark Report  ${NC}"
echo -e "${BOLD}${CYAN}======================================================${NC}\n"

# ------------------------------------------------------------------------------
# 1. System Memory (RAM) Bandwidth - Multi-Threaded STREAM
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[1/3] Benchmarking System RAM Bandwidth...${NC}"

RAM_TRIAD="N/A"
RAM_COPY="N/A"

if command -v gcc >/dev/null 2>&1; then
    cat << 'EOF' > "stream.c"
#include <stdio.h>
#include <stdlib.h>
#include <omp.h>
#include <sys/time.h>

#define STREAM_ARRAY_SIZE 40000000
#define NTIMES 5

static double a[STREAM_ARRAY_SIZE], b[STREAM_ARRAY_SIZE], c[STREAM_ARRAY_SIZE];

double mysecond() {
    struct timeval tp;
    gettimeofday(&tp, NULL);
    return ((double)tp.tv_sec + (double)tp.tv_usec * 1.e-6);
}

int main() {
    int j, k;
    double t, times[2][NTIMES];
    double bytes[2] = {
        2 * sizeof(double) * STREAM_ARRAY_SIZE, // Copy
        3 * sizeof(double) * STREAM_ARRAY_SIZE  // Triad
    };

    #pragma omp parallel for
    for (j=0; j<STREAM_ARRAY_SIZE; j++) {
        a[j] = 1.0; b[j] = 2.0; c[j] = 0.0;
    }

    for (k=0; k<NTIMES; k++) {
        t = mysecond();
        #pragma omp parallel for
        for (j=0; j<STREAM_ARRAY_SIZE; j++) c[j] = a[j];
        times[0][k] = mysecond() - t;

        t = mysecond();
        #pragma omp parallel for
        for (j=0; j<STREAM_ARRAY_SIZE; j++) a[j] = b[j] + 3.0 * c[j];
        times[1][k] = mysecond() - t;
    }

    double min_copy = 1e10, min_triad = 1e10;
    for (k=1; k<NTIMES; k++) {
        if (times[0][k] < min_copy) min_copy = times[0][k];
        if (times[1][k] < min_triad) min_triad = times[1][k];
    }

    printf("COPY:%.2f\n", (1.0E-09 * bytes[0]) / min_copy);
    printf("TRIAD:%.2f\n", (1.0E-09 * bytes[1]) / min_triad);
    return 0;
}
EOF

    export OMP_NUM_THREADS=$(nproc)
    gcc -O3 -fopenmp "stream.c" -o "stream" 2>/dev/null

    if [[ -f "./stream" ]]; then
        STREAM_OUT=$("/stream")
        RAM_COPY=$(echo "$STREAM_OUT" | grep "COPY" | cut -d':' -f2)
        RAM_TRIAD=$(echo "$STREAM_OUT" | grep "TRIAD" | cut -d':' -f2)
    fi
else
    echo -e "${RED}  - gcc not found. Skipping compilation.${NC}"
fi

# ------------------------------------------------------------------------------
# 2. PCIe Link & Host-to-Device Bandwidth
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[2/3] Inspecting PCIe Status & Bus Transfer...${NC}"

GPU_BUS_ID=$(lspci -D | grep -E "VGA compatible controller|3D controller" | head -n 1 | awk '{print $1}')
PCIE_LNK_CAP="N/A"
PCIE_LNK_STA="N/A"
PCIE_H2D="N/A"
PCIE_D2H="N/A"

if [[ -n "$GPU_BUS_ID" ]]; then
    PCIE_INFO=$(sudo lspci -s "$GPU_BUS_ID" -vvv 2>/dev/null || true)
    PCIE_LNK_CAP=$(echo "$PCIE_INFO" | grep "LnkCap:" | sed -E 's/.*Speed ([^,]+), Width ([^,]+).*/\1 \2/' | head -n 1)
    PCIE_LNK_STA=$(echo "$PCIE_INFO" | grep "LnkSta:" | sed -E 's/.*Speed ([^,]+).*Width ([^,]+).*/\1 \2/' | head -n 1)
fi

# ------------------------------------------------------------------------------
# 3. Video Memory (VRAM) & PCIe Throughput Benchmark
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[3/3] Benchmarking VRAM & Transfer Throughputs...${NC}"

VRAM_BANDWIDTH="N/A"

# Check for clpeak (Universal OpenCL: NVIDIA/AMD/Intel)
if command -v clpeak >/dev/null 2>&1; then
    CLPEAK_OUT=$(clpeak --global-bandwidth 2>/dev/null || true)
    VRAM_EXTRACT=$(echo "$CLPEAK_OUT" | grep -A 2 "Global memory bandwidth" | grep "Bandwidth" | awk '{print $NF}')
    if [[ -n "$VRAM_EXTRACT" ]]; then
        VRAM_BANDWIDTH="$VRAM_EXTRACT GB/s (clpeak)"
    fi
fi

# Check for NVIDIA CUDA bandwidthTest
if [[ -f "/usr/local/cuda/extras/demo_suite/bandwidthTest" ]]; then
    BWT_BIN="/usr/local/cuda/extras/demo_suite/bandwidthTest"
elif command -v bandwidthTest >/dev/null 2>&1; then
    BWT_BIN=$(command -v bandwidthTest)
else
    BWT_BIN=""
fi

if [[ -n "$BWT_BIN" ]]; then
    BWT_OUT=$("$BWT_BIN" --memory=pinned 2>/dev/null || true)

    H2D_VAL=$(echo "$BWT_OUT" | grep "Host to Device Bandwidth" -A 1 | tail -n 1 | awk '{print $NF}')
    D2H_VAL=$(echo "$BWT_OUT" | grep "Device to Host Bandwidth" -A 1 | tail -n 1 | awk '{print $NF}')
    D2D_VAL=$(echo "$BWT_OUT" | grep "Device to Device Bandwidth" -A 1 | tail -n 1 | awk '{print $NF}')

    [[ -n "$H2D_VAL" ]] && PCIE_H2D="$(( ${H2D_VAL%.*} / 1000 )) GB/s ($H2D_VAL MB/s)"
    [[ -n "$D2H_VAL" ]] && PCIE_D2H="$(( ${D2H_VAL%.*} / 1000 )) GB/s ($D2H_VAL MB/s)"
    [[ -n "$D2D_VAL" ]] && VRAM_BANDWIDTH="$(( ${D2D_VAL%.*} / 1000 )) GB/s (CUDA D2D)"
fi

# ------------------------------------------------------------------------------
# Final Aggregated Output Table
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${GREEN}=========================== RESULTS SUMMARY ===========================${NC}"
printf "%-28s | %-40s\n" "Metric / Subsystem" "Measured Throughput / Status"
echo "-----------------------------+------------------------------------------"
printf "%-28s | %-40s\n" "RAM Copy Bandwidth" "$RAM_COPY GB/s"
printf "%-28s | %-40s\n" "RAM Triad Bandwidth" "$RAM_TRIAD GB/s"
printf "%-28s | %-40s\n" "PCIe Max Capability" "$PCIE_LNK_CAP"
printf "%-28s | %-40s\n" "PCIe Negotiated Link" "$PCIE_LNK_STA"
printf "%-28s | %-40s\n" "PCIe Host-to-Device (Write)" "$PCIE_H2D"
printf "%-28s | %-40s\n" "PCIe Device-to-Host (Read)" "$PCIE_D2H"
printf "%-28s | %-40s\n" "GPU VRAM Bandwidth" "$VRAM_BANDWIDTH"
echo -e "${BOLD}${GREEN}=======================================================================${NC}\n"
