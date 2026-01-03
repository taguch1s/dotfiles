#!/bin/bash

# ansible
alias play="ansible-playbook --key-file ~/.ssh/main -i hosts playbook.yml"
alias playc="ansible-playbook --key-file ~/.ssh/main -i hosts playbook.yml -C"
alias play-env="ansible-playbook -f 30 --key-file ~/.ssh/main -i hosts playbook.yml -e 'ansible_python_interpreter=/usr/bin/python3'"
alias playc-env="ansible-playbook -f 30 --key-file ~/.ssh/main -i hosts playbook.yml -C -e 'ansible_python_interpreter=/usr/bin/python3'"

# with inventory
alias iplay="ansible-playbook --key-file ~/.ssh/main -i inventory.yml playbook.yml"
alias iplayc="ansible-playbook --key-file ~/.ssh/main -i inventory.yml playbook.yml -C"
