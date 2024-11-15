#!/bin/bash
set -euo pipefail # Enable strict mode for bash

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
    # Check if FEED_NAME is already set in the environment
    if [[ -n "${FEED_NAME:-}" ]]; then
        echo "FEED_NAME: $FEED_NAME" | tee -a "$LOG_FILE"
    else
        # Check if .env file exists
        if [ -f ".env" ]; then
            source .env
            # Check if FEED_NAME is set after sourcing .env
            if [[ -n "${FEED_NAME:-}" ]]; then
                echo "FEED_NAME: $FEED_NAME" | tee -a "$LOG_FILE"
            else
                # Prompt the user for FEED_NAME if still not set
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

# install yq if not installed
validate_command() {
    command -v /tmp/yq_linux_amd64 > /dev/null 2>&1 || {
        echo -e "\e[31m[ERROR]: the yq needed is not available!\e[0m"  | tee -a "$LOG_FILE"
        echo -e "\e[32m[INFO]:..........Getting yq from github.........\e[0m"
        wget https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 -P /tmp
        chmod a+x /tmp/yq_linux_amd64
        echo -e "\e[32m[SUCCESS]: yq is now available in /tmp/yq_linux_amd64 !!!\e[0m"
    }
}

sanitize_values() {
    echo -e "\e[32m[INFO]:..........Creating backup of generated-values.yaml.........\e[0m"
    # create a backup of the current generated-values.yaml as generated-values.yaml.bak
    helm get values "$FEED_NAME" -n "$FEED_NAME" > "$HOME/$FEED_NAME/.generated-values.yaml.${EPOCH}-HELM_BACKUP"
    cp "$HOME/$FEED_NAME/generated-values.yaml" "$HOME/$FEED_NAME/.generated-values.yaml.${EPOCH}-bak"

    echo -e "\e[32m[INFO]:..........Sanitizing generated-values.yaml.........\e[0m"
    # Read the YAML file
    yaml_file="$HOME/$FEED_NAME/generated-values.yaml"
    yaml_content=$(<"$yaml_file")

    # Extract the value of musig.env.normal.CFG_WEB_URL
    musig_web_url=$(echo "$yaml_content" | /tmp/yq_linux_amd64 '.musig.env.normal.CFG_WEB_URL' -)
    
    # Check if musig_web_url is not empty
    if [[ "$musig_web_url" != "null" ]]; then
        echo -e "\e[32m[INFO]: .Values.musig present .....Sanitizing generated-values.yaml .....\e[0m"
        # Create a new YAML structure with the updated value
        /tmp/yq_linux_amd64 -i '.ghost.env.normal.CFG_WEB_URL = .musig.env.normal.CFG_WEB_URL' $HOME/$FEED_NAME/generated-values.yaml
        # remove redunent values from generated-values.yaml
        /tmp/yq_linux_amd64 -i 'del(.musig)' $HOME/$FEED_NAME/generated-values.yaml
        /tmp/yq_linux_amd64 -i 'del(.ghost.chainId)' $HOME/$FEED_NAME/generated-values.yaml
        /tmp/yq_linux_amd64 -i 'del(.ghost.ethChainId)' $HOME/$FEED_NAME/generated-values.yaml
        /tmp/yq_linux_amd64 -i 'del(.ghost.env.normal.CFG_WEB_URL)' $HOME/$FEED_NAME/generated-values.yaml
    else
        echo "\e[32m[INFO] Removing CFG_WEB_URL as the tor-controller handles this now...\e[0m"
        /tmp/yq_linux_amd64 -i 'del(.ghost.env.normal.CFG_WEB_URL)' $HOME/$FEED_NAME/generated-values.yaml
        echo "\e[32m[INFO] .Values.musig not present in the YAML file. Skipping sanitization.\e[0m"
    fi
}

create_helm_upgrade() {
    # helm upgrade $FEED_NAME with --debug and --dry-run
    echo -e "\e[32m[INFO]:..........DRY RUN UPGRADE feed: $FEED_NAME in namespace: $FEED_NAME.........\e[0m"
    helm repo update
    helm upgrade "$FEED_NAME" -f "$HOME/$FEED_NAME/generated-values.yaml" chronicle/validator --namespace "$FEED_NAME" --debug --dry-run

    # prompt user to confirm upgrade, accept a Y/N
    echo -e "\e[33m[NOTICE]: DRY RUN UPGRADE complete! Do you want to continue with the upgrade? (y/n): "
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo -e "\e[33m[NOTICE]: Upgrading feed: $FEED_NAME in namespace: $FEED_NAME.\e[0m"
        helm upgrade "$FEED_NAME" -f "$HOME/$FEED_NAME/generated-values.yaml" chronicle/validator --namespace "$FEED_NAME"
    else
        echo -e "\e[33m[NOTICE]: Terminating the script as per user request.\e[0m"
        # print the helm command they will need to run
        echo -e "\e[33m[NOTICE]: You can run the following command to upgrade the feed:\e[0m"
        echo -e "\e[33m[NOTICE]: helm upgrade $FEED_NAME -f $HOME/$FEED_NAME/generated-values.yaml chronicle/validator --namespace $FEED_NAME\e[0m"
        exit 0
    fi
}

main() {
    echo -e "\e[32m[INFO]:..........Attempting to upgrade Chronicle feed.........\e[0m"
    validate_user
    validate_dot_env
    validate_command
    sanitize_values
    create_helm_upgrade
    echo -e "\e[33m[SUCCESS]: Upgrade complete!\e[0m"
}

main "$@"