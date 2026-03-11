#!/bin/bash
set -euo pipefail # Enable strict mode for bash

CHART_VERSION="0.5.1"

EPOCH=$(date +%s)
LOG_FILE="/tmp/upgrader-crash-${EPOCH}.log"

touch "$LOG_FILE"

trap 'handle_error $LINENO' ERR

handle_error() {
    echo -e "\e[31m[ERROR]: Script failed at line $1 with status $?\e[0m" | tee -a "$LOG_FILE"
    display_usage
}

display_usage() {
    echo -e "\e[33m[NOTICE]: Usage:\e[0m"
    echo "======"
    echo "./upgrade.sh"
    echo "# export FEED_NAME=<MY_FEED_NAME>"
    echo "can be set in .env file or exported in the environment"
    echo "required variables: FEED_NAME"
}

# Source the .env file if it exists and prompt for FEED_NAME if not set
validate_dot_env() {
    if [[ -n "${FEED_NAME:-}" ]]; then
        echo "FEED_NAME: $FEED_NAME" | tee -a "$LOG_FILE"
    else
        if [ -f ".env" ]; then
            source .env
            if [[ -n "${FEED_NAME:-}" ]]; then
                echo "FEED_NAME: $FEED_NAME" | tee -a "$LOG_FILE"
            else
                echo -e "\e[33m[WARNING]: FEED_NAME is not set in .env file.\e[0m" | tee -a "$LOG_FILE"
                read -rp "Enter FEED_NAME: " FEED_NAME
                if [[ -n "${FEED_NAME:-}" ]]; then
                    echo "FEED_NAME: $FEED_NAME" | tee -a "$LOG_FILE"
                else
                    echo -e "\e[31m[ERROR]: FEED_NAME cannot be empty! Exiting...\e[0m" | tee -a "$LOG_FILE"
                    exit 1
                fi
            fi
        else
            echo -e "\e[33m[WARNING]: .env file not found. Prompting for FEED_NAME.\e[0m" | tee -a "$LOG_FILE"
            read -rp "Enter FEED_NAME: " FEED_NAME
            if [[ -n "${FEED_NAME:-}" ]]; then
                echo "FEED_NAME: $FEED_NAME" | tee -a "$LOG_FILE"
            else
                echo -e "\e[31m[ERROR]: FEED_NAME cannot be empty! Exiting...\e[0m" | tee -a "$LOG_FILE"
                exit 1
            fi
        fi
    fi

    echo "OS Version: $(lsb_release -rs)" | tee -a "$LOG_FILE"
    echo "User: $USER" | tee -a "$LOG_FILE"
    echo "Date: $(date)" | tee -a "$LOG_FILE"
}

# validate if user is root, and if so, prompt user to switch to non-root user with sudo privileges
validate_user() {
    if [ "$USER" == "root" ]; then
        echo -e "\e[31m[ERROR]: This script should not be run as root!\e[0m"
        echo -e "\e[31m[ERROR]: Please run the script as a non-root user with sudo privileges.\e[0m"
        echo -e "\e[31m[ERROR]: Switch to the user created by the installer script and re-run the script.\e[0m" | tee -a "$LOG_FILE"
        exit 1
    fi
}

create_helm_upgrade() {
    echo -e "\e[32m[INFO]:..........Updating helm repositories.........\e[0m" | tee -a "$LOG_FILE"
    helm repo update | tee -a "$LOG_FILE"

    echo -e "\e[32m[INFO]:..........DRY RUN UPGRADE feed: $FEED_NAME in namespace: $FEED_NAME.........\e[0m" | tee -a "$LOG_FILE"
    helm upgrade "$FEED_NAME" -f "$HOME/$FEED_NAME/generated-values.yaml" chronicle/validator --namespace "$FEED_NAME" --version "$CHART_VERSION" --debug --dry-run 2>&1 | tee -a "$LOG_FILE"

    echo -e "\e[33m[NOTICE]: DRY RUN UPGRADE complete! Do you want to continue with the upgrade? (y/n): \e[0m"
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo -e "\e[33m[NOTICE]: Upgrading feed: $FEED_NAME in namespace: $FEED_NAME.\e[0m" | tee -a "$LOG_FILE"
        helm upgrade "$FEED_NAME" -f "$HOME/$FEED_NAME/generated-values.yaml" chronicle/validator --namespace "$FEED_NAME" --version "$CHART_VERSION" 2>&1 | tee -a "$LOG_FILE"
    else
        echo -e "\e[33m[NOTICE]: Terminating the script as per user request.\e[0m"
        echo -e "\e[33m[NOTICE]: You can run the following command to upgrade the feed:\e[0m"
        echo -e "\e[33m[NOTICE]: helm upgrade $FEED_NAME -f $HOME/$FEED_NAME/generated-values.yaml chronicle/validator --namespace $FEED_NAME --version $CHART_VERSION\e[0m"
        exit 0
    fi
}

main() {
    echo -e "\e[32m[INFO]:..........Attempting to upgrade Chronicle feed.........\e[0m"
    validate_user
    validate_dot_env
    create_helm_upgrade
    echo -e "\e[32m[SUCCESS]: Upgrade complete!\e[0m" | tee -a "$LOG_FILE"
}

main "$@"
