#!/usr/bin/env bash

restore_previous_image() {
    local previous_image_id=$1

    if [[ -n $previous_image_id ]]; then
        podman tag "$previous_image_id" "$WEBSITE_LOCAL_IMAGE"
        systemctl restart josephduffy-co-uk.service || true
        wait_for_website_deployment "$previous_image_id" 12 5 || true
    else
        systemctl stop josephduffy-co-uk.service || true
    fi
}
