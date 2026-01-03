#!/bin/bash

# terraform
alias tf='terraform'
alias tfi='terraform init'
alias tfs='terraform show '  # .terraform/state.tfstate
alias tfl='terraform state list'  # -state=.terraform/state.tfstate
alias tfp='terraform plan'  # -state=.terraform/state.tfstate
alias tfa='terraform apply --auto-approve'  # -state=.terraform/state.tfstate
alias tfd='terraform destroy'  # -state=.terraform/state.tfstate
alias tfr='terraform refresh'  # .terraform/state.tfstate

# gcloud
function gcloudlogin() {
  # gcloud auth login --update-adc
  gcloud auth application-default login
}

function gcloudset() {
  gcloud config set account naoya05280708@gmail.com
  gcloud config set project test-project-373118
}
