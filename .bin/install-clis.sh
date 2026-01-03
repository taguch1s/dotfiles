#!/bin/bash
set -eux

# mise set env
eval "$(~/.local/bin/mise activate bash)"

# PATH add to poetry. For exe docker-compose
for dir in "$HOME"/.local/share/mise/installs/poetry/*; do
  if [ -d "$dir" ]; then
    export PATH="$dir/bin:$PATH" # head is higher priority
  fi
done

# PATH add to node. For exe docker-compose
for dir in "$HOME"/.local/share/mise/installs/node/*; do
  if [ -d "$dir" ]; then
    export PATH="$dir/bin:$PATH" # head is higher priority
  fi
done

### Setup my poetry
# - thefuck
# - glances
# - speedtest-cli
poetry install --directory "$HOME/.my/poetry" --no-root
# poetry debug (delete)
# rm -rf "$(poetry env list --full-path --directory "./.my/poetry" | grep -o '/.*' | awk '{print $1}')"
# rm -rf "$(poetry env list --full-path --directory "$HOME/.my/poetry" | grep -o '/.*' | awk '{print $1}')"

### Setup my nodejs
# - aicommits
# .envにOPENAI_KEY=<your token>を設定
npm i --prefix "$HOME/.my/nodejs"
# nodejs ln
sudo ln -s "$(which node | head -n 1)" /usr/local/bin/


### Setup apt install
# - aria2
# - gping
# - figlet
sudo apt install -y aria2 gping figlet

### Generic function to download binary files (tar)
install_tar_package() {
  PACKAGE_NAME=$1
  URL=$2
  aria2c -d /tmp -x 16 -s 16 -k 1M -o "$PACKAGE_NAME.tar.gz" "$URL"
  tar -xzf "/tmp/$PACKAGE_NAME.tar.gz" -C /tmp
  sudo cp -a "/tmp/$PACKAGE_NAME" "$HOME/.local/bin"
  rm -rf "/tmp/$PACKAGE_NAME"*
  sudo chown "$USER:$USER" "$HOME/.local/bin/$PACKAGE_NAME"
  sudo chmod +x "$HOME/.local/bin/$PACKAGE_NAME"
}

### Generic function to download binary files (zip)
install_zip_package() {
  PACKAGE_NAME=$1
  URL=$2
  aria2c -d /tmp -x 16 -s 16 -k 1M -o "$PACKAGE_NAME.zip" "$URL"
  unzip "/tmp/$PACKAGE_NAME.zip" -d /tmp
  sudo cp -a "/tmp/$PACKAGE_NAME" $HOME/.local/bin
  rm -rf "/tmp/$PACKAGE_NAME"*
  sudo chown "$USER:$USER" "$HOME/.local/bin/$PACKAGE_NAME"
  sudo chmod +x "$HOME/.local/bin/$PACKAGE_NAME"
}

### Setup install_package
# - bandwhich
# - lagydocker
# - actionlint
# - cLive
# - pocketbase
install_tar_package bandwhich https://github.com/imsnif/bandwhich/releases/download/v0.22.2/bandwhich-v0.22.2-x86_64-unknown-linux-musl.tar.gz
install_tar_package lazydocker https://github.com/jesseduffield/lazydocker/releases/download/v0.23.3/lazydocker_0.23.3_Linux_x86_64.tar.gz
install_tar_package actionlint https://github.com/rhysd/actionlint/releases/download/v1.7.1/actionlint_1.7.1_linux_amd64.tar.gz
install_tar_package clive https://github.com/koki-develop/clive/releases/download/v0.12.9/clive_Linux_x86_64.tar.gz
install_zip_package pocketbase https://github.com/pocketbase/pocketbase/releases/download/v0.22.18/pocketbase_0.22.18_linux_amd64.zip
install_zip_package procs https://github.com/dalance/procs/releases/download/v0.14.6/procs-v0.14.6-x86_64-linux.zip

### Developments
# - charming
# cargo add charming
# - farm
# npx create farm@latest
# - go-zero
# go get -u github.com/zeromicro/go-zero
# - hyperfine -> Installed from mise

### Other
# - genact
PACKAGE_NAME=genact
sudo curl -Lo "$HOME/.local/bin/$PACKAGE_NAME" https://github.com/svenstaro/genact/releases/download/v1.4.2/genact-1.4.2-x86_64-unknown-linux-musl
sudo chown "$USER:$USER" "$HOME/.local/bin/$PACKAGE_NAME"
sudo chmod +x "$HOME/.local/bin/$PACKAGE_NAME"
# - gh
(type -p wget >/dev/null || (sudo apt update && sudo apt-get install wget -y)) &&
  sudo mkdir -p -m 755 /etc/apt/keyrings &&
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null &&
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg &&
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null &&
  sudo apt update &&
  sudo apt install gh -y

### kubectl, helm, minikube
# - kubectl
sudo ln -s "$(which kubectl | head -n 1)" /usr/bin/
# KUBE_KEY_VERSION=v1.30
# sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg
# sudo mkdir -p /etc/apt/keyrings
# sudo chmod 755 /etc/apt/keyrings
# curl -fsSL https://pkgs.k8s.io/core:/stable:/${KUBE_KEY_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
# echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_KEY_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
# sudo apt-get update
# sudo apt-get install -y kubectl
# # - helm
# curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
# # - minikube
# PACKAGE_NAME=minikube
# URL=https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
# aria2c -d /tmp -x 16 -s 16 -k 1M -o "$PACKAGE_NAME" "$URL"
# sudo install /tmp/minikube /usr/local/bin/minikube


### Install sops because of not to use mise.
# - sops
SOPS_VERSION=3.9.1
curl -LO https://github.com/getsops/sops/releases/download/v$SOPS_VERSION/sops-v$SOPS_VERSION.linux.amd64
sudo mv sops-v$SOPS_VERSION.linux.amd64 /usr/local/bin/sops
sudo chmod +x /usr/local/bin/sops

### Install other plugins
gcloud components install gke-gcloud-auth-plugin
helm plugin install https://github.com/jkroepke/helm-secrets --version v4.6.2
