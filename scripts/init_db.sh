#!/usr/bin/env bash

set -euo pipefail

if ! [ -x "$(command -v sqlx)" ]
then
    echo >&2 "Error: sqlx is not installed"
    echo >&2 "Use:"
    echo >&2 "  cargo install sqlx-cli --no-default-features --features rustls,postgres"
    echo >&2 "to install it"
    exit 1
fi

SKIP_DOCKER=""
DB_PORT="${POSTGRES_PORT:=5432}"
SUPERUSER="${SUPERUSER:=postgres}"
SUPERUSER_PWD="${SUPERUSER_PWD:=password}"

APP_USER="${APP_USER:=app}"
APP_USER_PWD="${APP_USER_PWD:=secret}"
APP_DB_NAME="${APP_DB_NAME:=newsletter}"

if [[ -z "${SKIP_DOCKER}" ]]
then
    CONTAINER_NAME="newsletter_api_postgres"

    # if a DB container is running, print instructions to stop it and exit
    RUNNING_CONTAINER=$(docker ps --filter "name=${CONTAINER_NAME}" --format '{{.ID}}')
    if [[ -n $RUNNING_CONTAINER ]]
    then
        echo >&2 "there is a DB container already running, stop it with"
        echo >&2 "    docker container stop ${RUNNING_CONTAINER}"
        exit 1
    fi

    # if a DB container is already existing, do not create it
    EXISTING_CONTAINER=$(docker container ls --all --filter "name=${CONTAINER_NAME}" --format '{{.ID}}')
    if [[ -z "${EXISTING_CONTAINER}" ]]
    then
        echo >&2 "DB does not exist, creating it"
        docker run \
            --env POSTGRES_USER=${SUPERUSER} \
            --env POSTGRES_PASSWORD=${SUPERUSER_PWD} \
            --health-cmd="pg_isready -U ${SUPERUSER} || exit 1" \
            --health-interval=1s \
            --health-timeout=5s \
            --health-retries=5 \
            --publish "${DB_PORT}":5432 \
            --detach \
            --name "${CONTAINER_NAME}" \
            postgres -N 1000
    else
        echo >&2 "DB is already existing, starting it"
        docker container start "${EXISTING_CONTAINER}"
    fi

    until [ "$(docker inspect -f "{{.State.Health.Status}}" ${CONTAINER_NAME})" == "healthy" ]
    do
        echo >&2 "DB is still unavailable - sleeping"
        sleep 1
    done

    if [[ -z "${EXISTING_CONTAINER}" ]]
    then
        CREATE_QUERY="CREATE USER ${APP_USER} WITH PASSWORD '${APP_USER_PWD}';"
        docker exec -it "${CONTAINER_NAME}" psql -U "${SUPERUSER}" -c "${CREATE_QUERY}"

        GRANT_QUERY="ALTER USER ${APP_USER} CREATEDB;"
        docker exec -it "${CONTAINER_NAME}" psql -U "${SUPERUSER}" -c "${GRANT_QUERY}"
    fi
fi

>&2 echo "DB is up and running on port ${DB_PORT} - running migrations now!"

DATABASE_URL=postgres://${APP_USER}:${APP_USER_PWD}@127.0.0.1:${DB_PORT}/${APP_DB_NAME}
export DATABASE_URL

sqlx database create

sqlx migrate run

>&2 echo "DB has been migrated, ready to go!"
