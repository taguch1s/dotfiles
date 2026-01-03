#!/bin/bash

# docker
alias d='docker'
alias dp='docker ps -a'
alias drm='docker rm -f $(docker ps -aq)'
alias drmi='docker rmi -f $(docker images -q)'
alias deli='sh -xc "docker rm -f $(docker ps -aq); docker volume prune -a -f; docker system prune -a -f"'
alias dsys='docker system df'

# docker-compose
alias dc='docker-compose'
alias dcp='docker-compose ps -a'
alias dcu='docker-compose up -d'
alias wdcp='watch docker-compose ps -a'
alias dcb='docker-compose build'
alias dcd='docker-compose down'
alias dceli='docker-compose down --rmi all --volumes --remove-orphans'

# dcu() {
#   docker-compose up -d
#   while true; do
#     output=$(docker-compose ps)
#     echo "${output}"
#     if ! echo "${output}" grep -q -e "unhealthy" -e "starting"; then
#       break
#     fi
#     sleep 5
#   done
#   echo "All containers are healthy."
# }

# dcall() {
#   docker-compose down
#   docker-compose build "${1}"
#   docker-compose up -d
#   while true; do
#     output=$(docker-compose ps)
#     echo "${output}"
#     if ! echo "${output}" grep -q -e "unhealthy" -e "starting"; then
#       break
#     fi
#     sleep 5
#   done
#   echo "All containers are healthy."
# }
