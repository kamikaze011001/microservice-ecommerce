#!/bin/bash
# Shared color codes. Source, don't execute.
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export YELLOW='\033[1;33m'
export NC='\033[0m'

# Logging helpers — write to stderr so command output stays clean on stdout
log_info()  { echo -e "${BLUE}$*${NC}" >&2; }
log_ok()    { echo -e "${GREEN}✓ $*${NC}" >&2; }
log_warn()  { echo -e "${YELLOW}⚠ $*${NC}" >&2; }
log_err()   { echo -e "${RED}✗ $*${NC}" >&2; }
