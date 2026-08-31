#!/usr/bin/env bash

restore_previous_image() {
    local previous_image_id=$1
    local local_image=$2
    local service=$3
    local container=$4
    local hostname=$5
    local health_path=$6

    if [[ -n $previous_image_id ]]; then
        podman tag "$previous_image_id" "$local_image"
        systemctl restart "$service" || true
        wait_for_target_deployment \
            "$container" "$hostname" "$health_path" "$previous_image_id" 12 5 || true
    else
        systemctl stop "$service" || true
    fi
}
