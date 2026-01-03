#!/bin/bash
set -eux

### Ubuntu22.04 ###
ubuntu_setup() {
  echo "ubuntu setup started."
  sudo apt purge -y needrestart
  sudo timedatectl set-timezone Asia/Tokyo
  sudo systemctl restart rsyslog
  # mirror set riken
  sudo sed -i.bak -r 's!http://(security|us.archive).ubuntu.com/ubuntu!http://ftp.riken.jp/Linux/ubuntu!' /etc/apt/sources.list
  sudo apt update -y && sudo apt upgrade -y
  # set inputrc
  sudo echo "set bell-style none" | sudo tee -a /etc/inputrc
}

main() {
  ubuntu_setup
  echo -e "\e[1;36m Setup completed!!!! \e[m"
}

main "$@"
