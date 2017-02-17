#!/bin/bash
# Allows Channels-DVR-to-Plex jobs run with GNU parallels to be monitored in real-time
# Usage: monitor_jobs.sh ${WORKING_DIR}

find "${1} -name stdout -exec xterm -e tail -f {} \;
