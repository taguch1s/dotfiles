#!/bin/bash

# database
alias mypsql="docker-compose exec database psql -U pguser database -P 'pager=off'"
# mypsqlcolumn() {
#   docker-compose exec database psql -U pguser database -P 'pager=off' -c "select column_name from information_schema.columns where table_schema = 'public' AND table_name = '$1';"
# }
# Add postgresql.conf
#   logging_collector = on
#   log_statement = 'all'
alias querylog="docker-compose exec database tail -f /var/lib/..."

# redis
alias myredis="docker-compose exec cache-server redis-cli"
