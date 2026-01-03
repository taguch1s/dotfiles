#!/bin/bash

# k6
alias format='npm run format --prefix ./scenarios/'
perf() {
  docker-compose run k6 -c "
  k6 --url https://localhost \
    --username admin \
    --password admin \
    --out-dir /result \
    api/*/*/${1}.js
  "
}
perfall() {
  npm run format --prefix ./scenarios/
  docker-compose build
  docker-compose run k6 -c "
  k6 --url https://localhost \
    --username admin \
    --password admin \
    --out-dir /result \
    api/*/*/${1}.js
  "
}
