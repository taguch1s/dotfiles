#!/bin/bash

# iostat
alias myio="iostat -cdmhNtz 1"

# sar
# cpusar() {
#   sar -u -f /var/log/sysstat/sa"$1"
# }
# memsar() {
#   sar -r -f /var/log/sysstat/sa"$1"
# }
# swapsar() {
#   sar -W -f /var/log/sysstat/sa"$1"
# }
# swap2sar() {
#   sar -S -f /var/log/sysstat/sa"$1"
# }
# iosar() {
#   sar -b -f /var/log/sysstat/sa"$1"
# }
# pgsar() {
#   sar -B -f /var/log/sysstat/sa"$1"
# }
# fssar() {
#   sar -F -f /var/log/sysstat/sa"$1"
# }
alias netsar="sar -n DEV"

# docker stats
# cpustats() {
#   docker stats --no-stream --format "{{.Name}},{{.CPUPerc}}" awk -F"," '{ print $2 " " $1}' sort -nr column -t
# }
# memstats() {
#   docker stats --no-stream --format "{{.Name}},{{.MemPerc}}" awk -F"," '{ print $2 " " $1}' sort -nr column -t
# }
