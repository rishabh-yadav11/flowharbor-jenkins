#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"
TFVARS="$TF_DIR/terraform.tfvars"
PLAN_FILE="$TF_DIR/cloudfront.tfplan"

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

# Robust parsing: allow leading whitespace before the key.
get_status() {
    if [ ! -f "$TFVARS" ]; then
        echo "enabled (default)"
        return 0
    fi
    if grep -Eq '^[[:space:]]*enable_cloudfront[[:space:]]*=[[:space:]]*true([[:space:]#].*)?$' "$TFVARS"; then
        echo "enabled"
    elif grep -Eq '^[[:space:]]*enable_cloudfront[[:space:]]*=[[:space:]]*false([[:space:]#].*)?$' "$TFVARS"; then
        echo "disabled"
    else
        echo "enabled (default)"
    fi
}

cmd_status() {
    echo "CloudFront is currently: $(get_status)"
}

# Idempotent edit of the toggle key. Uses mktemp+trap and portable sed
# (writes to temp file instead of sed -i, which differs between GNU/BSD).
set_toggle() {
    local want="$1" tmp
    tmp="$(mktemp "${TF_DIR}/.terraform.tfvars.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT INT TERM
    if [ ! -f "$TFVARS" ]; then
        printf '# CloudFront CDN toggle\nenable_cloudfront = %s\n' "$want" > "$tmp"
        mv "$tmp" "$TFVARS"
        trap - EXIT INT TERM
        return 0
    fi
    cp "$TFVARS" "$TFVARS.bak"
    if grep -Eq '^[[:space:]]*enable_cloudfront[[:space:]]*=' "$TFVARS"; then
        # Replace only the first occurrence; keep the rest untouched.
        awk -v want="$want" '{
            if (!done && $0 ~ /^[[:space:]]*enable_cloudfront[[:space:]]*=/) {
                print "enable_cloudfront = " want; done=1
            } else { print }
        }' "$TFVARS" > "$tmp"
    else
        cat "$TFVARS" > "$tmp"
        printf '\n# CloudFront CDN toggle\nenable_cloudfront = %s\n' "$want" >> "$tmp"
    fi
    mv "$tmp" "$TFVARS"
    trap - EXIT INT TERM
}

cmd_add() {
    local s
    s=$(get_status)
    if [ "$s" = "enabled" ] || [ "$s" = "enabled (default)" ]; then
        echo "CloudFront is already enabled. No changes made."
        exit 0
    fi

    echo "Enabling CloudFront..."
    set_toggle "true"

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
    set_toggle "false"

    echo "CloudFront disabled. Run '$0 plan' to review changes."
}

cmd_plan() {
    cd "$TF_DIR" && terraform fmt -check -recursive
    cd "$TF_DIR" && terraform validate
    cd "$TF_DIR" && terraform plan -out "$PLAN_FILE"
}

cmd_apply() {
    if [ -f "$PLAN_FILE" ]; then
        cd "$TF_DIR" && terraform apply "$PLAN_FILE"
    else
        cd "$TF_DIR" && terraform apply
    fi
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
