#!/bin/bash

# shellcheck disable=SC1090
if command -v kubectl &> /dev/null; then
  source <(kubectl completion bash)
  alias k='kubectl'
  complete -F __start_kubectl k
fi

alias kcv='kubectl config view -o jsonpath='\''{.users[*].name}'\'''
alias kgn='kubectl get node -A'
alias kgp='kubectl get pod -A'
alias kgpw='kubectl get pod -A -o wide'
alias kgs='kubectl get svc -A'
alias kgd='kubectl get deployment -A'
alias kgstate='kubectl get statefulset -A'
alias kgsc='kubectl get storageclass -A'
alias kgname='kubectl get namespace -A'
alias kak='kubectl apply -k ./'
alias kd='kubectl describe'
