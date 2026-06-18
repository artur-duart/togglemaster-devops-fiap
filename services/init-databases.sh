#!/bin/bash
set -e

psql -U "$POSTGRES_USER" -d ${POSTGRES_DB} -c "CREATE DATABASE ${TARGETING_DB_NAME};"
psql -U "$POSTGRES_USER" -d ${TARGETING_DB_NAME} -f /schemas/targeting.sql
