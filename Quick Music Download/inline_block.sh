#!/bin/bash

DIR="$HOME/.Shortcuts/Quick_Music_Download"
SCRIPT_URL="https://raw.githubusercontent.com/Oshanotter/Shortcuts/refs/heads/main/Quick%20Music%20Download/main.sh"
SCRIPT_PATH="$DIR/main.sh"
INPUT="$1"


# check if directory exists
if [ ! -d "$DIR" ]; then

    echo "Directory does not exist. Creating it..."
    mkdir -p "$DIR"
    NEED_DOWNLOAD=true

elif [ ! -f "$SCRIPT_PATH" ];then
    NEED_DOWNLOAD=true
else
    NEED_DOWNLOAD=false
fi


# check for --update argument
if [ "$INPUT" = "--update" ]; then
    NEED_DOWNLOAD=true
fi


# download the script if needed
if [ "$NEED_DOWNLOAD" = true ]; then

    echo "Update flag detected."
    echo "Downloading script..."
    
    # use curl
    curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"

    # make executable
    chmod +x "$SCRIPT_PATH"

    echo "Script downloaded and made executable"
    
fi


# run the main script
if ! OUTPUT=$(
    (
        set -eE
        trap 'echo "Error on line $LINENO: $BASH_COMMAND" >&2' ERR

        echo "Running main.sh script..."
        "$SCRIPT_PATH" "$INPUT"
    ) 2>&1
); then
    echo "$OUTPUT"
    echo "The main.sh script failed."
else
    echo "$OUTPUT"
fi