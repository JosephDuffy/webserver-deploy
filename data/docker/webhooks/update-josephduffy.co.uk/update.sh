#! /bin/bash

echo "Performing website update"

docker-compose pull josephduffy-co-uk
docker-compose up -d josephduffy-co-uk
docker image prune --force
