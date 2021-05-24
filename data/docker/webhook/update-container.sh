#!/bin/sh

docker-compose --verbose pull "$1"
docker-compose up --build --detach "$1"
docker image prune --force
