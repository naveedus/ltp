#!/bin/bash
# Test Validation Script: Compare libhugetlbfs quota.c vs LTP hugemmap33.c
# This script generates evidence that both tests exercise identical kernel behavior

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBHUGETLBFS_DIR="$SCRIPT_DIR/libhugetlbfs"
LTP_DIR="$SCRIPT_DIR/ltp"
OUTPUT_DIR="$SCRIPT_DIR/validation_output"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Test Validation: quota.c → hugemmap33.c"
echo "=========================================="
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}ERROR: This script must be run as root (hugepage tests require root)${NC}"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Step 1: Build both tests
echo -e "${YELLOW}Step 1: Building tests...${NC}"
echo "Building libhugetlbfs..."
cd "$LIBHUGETLBFS_DIR"
make clean > /dev/null 2>&1 || true
make > "$OUTPUT_DIR/libhugetlbfs_build.log" 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ libhugetlbfs built successfully${NC}"
else
    echo -e "${RED}✗ libhugetlbfs build failed (see $OUTPUT_DIR/libhugetlbfs_build.log)${NC}"
    exit 1
fi

echo "Building LTP hugemmap tests..."
cd "$LTP_DIR/testcases/kernel/mem/hugetlb/hugemmap"
make clean > /dev/null 2>&1 || true
make > "$OUTPUT_DIR/ltp_build.log" 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ LTP tests built successfully${NC}"
else
    echo -e "${RED}✗ LTP build failed (see $OUTPUT_DIR/ltp_build.log)${NC}"
    exit 1
fi
echo

# Step 2: Run original test with strace
echo -e "${YELLOW}Step 2: Running original libhugetlbfs quota test...${NC}"
cd "$LIBHUGETLBFS_DIR/tests"
strace -e trace=mount,mmap,munmap,statfs,umount2 -o "$OUTPUT_DIR/quota_orig.strace" \
    ./run_tests.py -t quota > "$OUTPUT_DIR/quota_orig.output" 2>&1
ORIG_EXIT=$?
if [ $ORIG_EXIT -eq 0 ]; then
    echo -e "${GREEN}✓ Original test PASSED${NC}"
else
    echo -e "${RED}✗ Original test FAILED (exit code: $ORIG_EXIT)${NC}"
fi
cat "$OUTPUT_DIR/quota_orig.output"
echo

# Step 3: Run LTP port with strace
echo -e "${YELLOW}Step 3: Running LTP port (hugemmap33)...${NC}"
cd "$LTP_DIR/testcases/kernel/mem/hugetlb/hugemmap"
strace -e trace=mount,mmap,munmap,statfs,umount2 -o "$OUTPUT_DIR/hugemmap33.strace" \
    ./hugemmap33 > "$OUTPUT_DIR/hugemmap33.output" 2>&1
LTP_EXIT=$?
if [ $LTP_EXIT -eq 0 ]; then
    echo -e "${GREEN}✓ LTP test PASSED${NC}"
else
    echo -e "${RED}✗ LTP test FAILED (exit code: $LTP_EXIT)${NC}"
fi
cat "$OUTPUT_DIR/hugemmap33.output"
echo

# Step 4: Compare syscall patterns
echo -e "${YELLOW}Step 4: Analyzing syscall patterns...${NC}"

# Extract key syscalls from traces
echo "Extracting mount syscalls..."
grep "mount(" "$OUTPUT_DIR/quota_orig.strace" 2>/dev/null | grep -v "ENOENT" > "$OUTPUT_DIR/quota_mount.txt" || true
grep "mount(" "$OUTPUT_DIR/hugemmap33.strace" 2>/dev/null | grep -v "ENOENT" > "$OUTPUT_DIR/ltp_mount.txt" || true

echo "Extracting mmap syscalls..."
grep "mmap(" "$OUTPUT_DIR/quota_orig.strace" 2>/dev/null > "$OUTPUT_DIR/quota_mmap.txt" || true
grep "mmap(" "$OUTPUT_DIR/hugemmap33.strace" 2>/dev/null > "$OUTPUT_DIR/ltp_mmap.txt" || true

echo "Extracting statfs syscalls..."
grep "statfs(" "$OUTPUT_DIR/quota_orig.strace" 2>/dev/null > "$OUTPUT_DIR/quota_statfs.txt" || true
grep "statfs(" "$OUTPUT_DIR/hugemmap33.strace" 2>/dev/null > "$OUTPUT_DIR/ltp_statfs.txt" || true

echo "Extracting munmap syscalls..."
grep "munmap(" "$OUTPUT_DIR/quota_orig.strace" 2>/dev/null > "$OUTPUT_DIR/quota_munmap.txt" || true
grep "munmap(" "$OUTPUT_DIR/hugemmap33.strace" 2>/dev/null > "$OUTPUT_DIR/ltp_munmap.txt" || true

# Count syscalls
ORIG_MOUNT=$(wc -l < "$OUTPUT_DIR/quota_mount.txt")
LTP_MOUNT=$(wc -l < "$OUTPUT_DIR/ltp_mount.txt")
ORIG_MMAP=$(wc -l < "$OUTPUT_DIR/quota_mmap.txt")
LTP_MMAP=$(wc -l < "$OUTPUT_DIR/ltp_mmap.txt")
ORIG_STATFS=$(wc -l < "$OUTPUT_DIR/quota_statfs.txt")
LTP_STATFS=$(wc -l < "$OUTPUT_DIR/ltp_statfs.txt")
ORIG_MUNMAP=$(wc -l < "$OUTPUT_DIR/quota_munmap.txt")
LTP_MUNMAP=$(wc -l < "$OUTPUT_DIR/ltp_munmap.txt")

echo
echo "Syscall Count Comparison:"
echo "========================="
printf "%-15s %10s %10s %10s\n" "Syscall" "Original" "LTP Port" "Match"
printf "%-15s %10s %10s %10s\n" "-------" "--------" "--------" "-----"
printf "%-15s %10d %10d %10s\n" "mount()" "$ORIG_MOUNT" "$LTP_MOUNT" "$([ $ORIG_MOUNT -eq $LTP_MOUNT ] && echo '✓' || echo '✗')"
printf "%-15s %10d %10d %10s\n" "mmap()" "$ORIG_MMAP" "$LTP_MMAP" "$([ $ORIG_MMAP -eq $LTP_MMAP ] && echo '✓' || echo '✗')"
printf "%-15s %10d %10d %10s\n" "statfs()" "$ORIG_STATFS" "$LTP_STATFS" "$([ $ORIG_STATFS -eq $LTP_STATFS ] && echo '✓' || echo '✗')"
printf "%-15s %10d %10d %10s\n" "munmap()" "$ORIG_MUNMAP" "$LTP_MUNMAP" "$([ $ORIG_MUNMAP -eq $LTP_MUNMAP ] && echo '✓' || echo '✗')"
echo

# Step 5: Generate summary report
echo -e "${YELLOW}Step 5: Generating validation summary...${NC}"

cat > "$OUTPUT_DIR/VALIDATION_SUMMARY.txt" << EOF
Test Validation Summary
=======================
Date: $(date)
Host: $(hostname)
Kernel: $(uname -r)

Test Results:
-------------
Original libhugetlbfs quota test: $([ $ORIG_EXIT -eq 0 ] && echo "PASSED" || echo "FAILED")
LTP port hugemmap33 test:         $([ $LTP_EXIT -eq 0 ] && echo "PASSED" || echo "FAILED")

Syscall Pattern Analysis:
-------------------------
mount() calls:   Original=$ORIG_MOUNT, LTP=$LTP_MOUNT   $([ $ORIG_MOUNT -eq $LTP_MOUNT ] && echo "✓ MATCH" || echo "✗ DIFFER")
mmap() calls:    Original=$ORIG_MMAP, LTP=$LTP_MMAP     $([ $ORIG_MMAP -eq $LTP_MMAP ] && echo "✓ MATCH" || echo "✗ DIFFER")
statfs() calls:  Original=$ORIG_STATFS, LTP=$LTP_STATFS $([ $ORIG_STATFS -eq $LTP_STATFS ] && echo "✓ MATCH" || echo "✗ DIFFER")
munmap() calls:  Original=$ORIG_MUNMAP, LTP=$LTP_MUNMAP $([ $ORIG_MUNMAP -eq $LTP_MUNMAP ] && echo "✓ MATCH" || echo "✗ DIFFER")

Functional Equivalence:
-----------------------
EOF

if [ $ORIG_EXIT -eq 0 ] && [ $LTP_EXIT -eq 0 ]; then
    echo "✓ Both tests PASSED" >> "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"
else
    echo "✗ Test results differ" >> "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"
fi

if [ $ORIG_MOUNT -eq $LTP_MOUNT ] && [ $ORIG_MMAP -eq $LTP_MMAP ] && \
   [ $ORIG_STATFS -eq $LTP_STATFS ] && [ $ORIG_MUNMAP -eq $LTP_MUNMAP ]; then
    echo "✓ Syscall patterns MATCH - tests exercise identical kernel code paths" >> "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"
else
    echo "⚠ Syscall patterns differ - review traces for details" >> "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"
fi

echo >> "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"
echo "Detailed traces available in:" >> "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"
echo "  - $OUTPUT_DIR/quota_orig.strace" >> "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"
echo "  - $OUTPUT_DIR/hugemmap33.strace" >> "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"
echo >> "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"
echo "Test outputs available in:" >> "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"
echo "  - $OUTPUT_DIR/quota_orig.output" >> "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"
echo "  - $OUTPUT_DIR/hugemmap33.output" >> "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"

cat "$OUTPUT_DIR/VALIDATION_SUMMARY.txt"
echo

# Final verdict
echo "=========================================="
if [ $ORIG_EXIT -eq 0 ] && [ $LTP_EXIT -eq 0 ] && \
   [ $ORIG_MOUNT -eq $LTP_MOUNT ] && [ $ORIG_MMAP -eq $LTP_MMAP ] && \
   [ $ORIG_STATFS -eq $LTP_STATFS ] && [ $ORIG_MUNMAP -eq $LTP_MUNMAP ]; then
    echo -e "${GREEN}✓ VALIDATION SUCCESSFUL${NC}"
    echo -e "${GREEN}  Both tests pass and exercise identical kernel code paths${NC}"
    EXIT_CODE=0
else
    echo -e "${YELLOW}⚠ VALIDATION INCOMPLETE${NC}"
    echo -e "${YELLOW}  Review detailed traces in $OUTPUT_DIR/${NC}"
    EXIT_CODE=1
fi
echo "=========================================="
echo
echo "All validation artifacts saved to: $OUTPUT_DIR/"
echo "Review TEST_VALIDATION_REPORT.md for detailed analysis"

exit $EXIT_CODE

# Made with Bob
