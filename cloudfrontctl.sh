#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"

usage() {
    cat <<EOF
Usage: $0 {status|add|remove|plan|apply}

Commands:
  status    Show whether CloudFront is currently enabled or disabled
  add       Enable  CloudFront CDN for production (routes root domain through CloudFront)
  remove    Disable CloudFront CDN for production (routes root domain directly to ALB)
  plan      Run 'terraform plan' to preview infrastructure changes
  apply     Run 'terraform apply' to apply infrastructure changes
EOF
    exit 1
}

get_status() {
    if grep -Eq '^enable_cloudfront\s*=\s*true' "$TF_DIR/terraform.tfvars" 2>/dev/null; then
        echo "enabled"
    elif grep -Eq '^enable_cloudfront\s*=\s*false' "$TF_DIR/terraform.tfvars" 2>/dev/null; then
        echo "disabled"
    else
        echo "enabled (default)"
    fi
}

cmd_status() {
    echo "CloudFront is currently: $(get_status)"
}

cmd_add() {
    local s
    s=$(get_status)
    if [ "$s" = "enabled" ] || [ "$s" = "enabled (default)" ]; then
        echo "CloudFront is already enabled. No changes made."
        exit 0
    fi

    echo "Enabling CloudFront..."
    cp "$TF_DIR/terraform.tfvars" "$TF_DIR/terraform.tfvars.bak"

    if grep -Eq '^enable_cloudfront' "$TF_DIR/terraform.tfvars"; then
        sed -i 's/^enable_cloudfront\s*=.*/enable_cloudfront = true/' "$TF_DIR/terraform.tfvars"
    else
        cat <<EOF >> "$TF_DIR/terraform.tfvars"

# CloudFront CDN toggle
enable_cloudfront = true
EOF
    fi

    echo "CloudFront enabled. Run '$0 plan' to review changes."
}

cmd_remove() {
    local s
    s=$(get_status)
    if [ "$s" = "disabled" ]; then
        echo "CloudFront is already disabled. No changes made."
        exit 0
    fi

    echo "Disabling CloudFront..."
    cp "$TF_DIR/terraform.tfvars" "$TF_DIR/terraform.tfvars.bak"

    if grep -Eq '^enable_cloudfront' "$TF_DIR/terraform.tfvars"; then
        sed -i 's/^enable_cloudfront\s*=.*/enable_cloudfront = false/' "$TF_DIR/terraform.tfvars"
    else
        cat <<EOF >> "$TF_DIR/terraform.tfvars"

# CloudFront CDN toggle
enable_cloudfront = false
EOF
    fi

    echo "CloudFront disabled. Run '$0 plan' to review changes."
}

cmd_plan() {
    cd "$TF_DIR" && terraform plan
}

cmd_apply() {
    cd "$TF_DIR" && terraform apply
}

case "${1:-help}" in
    status)
        cmd_status
        ;;
    add|enable)
        cmd_add
        ;;
    remove|disable|rm)
        cmd_remove
        ;;
    plan)
        cmd_plan
        ;;
    apply)
        cmd_apply
        ;;
    *)
        usage
        ;;
esac
