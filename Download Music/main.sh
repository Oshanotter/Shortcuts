#!/bin/bash

# make any errors cause the whole script to fail (for updating purposes)
set -euo pipefail

# set the default paths
DIR="$HOME/.Shortcuts/Download_Music"
YT_DLP_PATH="$DIR/yt-dlp"
FFMPEG_PATH="$DIR/ffmpeg"
DENO_PATH="$DIR/deno"
TEMP_PATH="$DIR/temp"
TEMP_ARTWORK_PATH="$TEMP_PATH/artwork.jpg"
TEMP_AUDIO_PATH="$TEMP_PATH/audio.m4a"
JSON_DIRECTORY="$HOME/Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/Music Download Suite/Songs To Get"
DOWNLOAD_PATH="$HOME/Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/Music Download Suite/Music"
INPUT="$1"

echo "Input: $INPUT"


# function to send a notification: title, message, sound (bool)
sendNotification() {
    local TITLE="$1"
    local MESSAGE="$2"
    local SOUND="${3:-false}"   # default to false if not provided

    # escape backslashes first, then quotes
    TITLE=${TITLE//\\/\\\\}
    TITLE=${TITLE//\"/\\\"}

    MESSAGE=${MESSAGE//\\/\\\\}
    MESSAGE=${MESSAGE//\"/\\\"}

    if [ "$SOUND" = true ]; then
        osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\" sound name \"\"" # leave blank for default
    else
        osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\""
    fi
}


# function to download the required binaries
downloadBinaries() {
    echo "Downloading yt-dlp, ffmpeg, and deno..."
    sendNotification "Starting Update..." "Quick Music Download is now being updated."

    # first, remove the old ones, if they exist
    rm -f "$YT_DLP_PATH"
    rm -f "$FFMPEG_PATH"
    rm -f "$DENO_PATH"

    # download yt-dlp
    curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos -o "$YT_DLP_PATH"
    chmod a+rx "$YT_DLP_PATH"

    # download deno
    curl -LO https://github.com/denoland/deno/releases/latest/download/deno-x86_64-apple-darwin.zip --output-dir "$DIR"
    unzip "$DIR/deno-x86_64-apple-darwin.zip" -d "$DIR"
    rm "$DIR/deno-x86_64-apple-darwin.zip"

    #download ffmpeg
    # fetch the webpage
    page=$(curl -s https://osxexperts.net/)

    # extract the first match for ffmpeg*arm.zip
    url=$(echo "$page" | grep -o 'https://www.osxexperts.net/ffmpeg[^"]*arm\.zip' | head -n 1)

    if [ -n "$url" ]; then
        echo "Latest Apple Silicon ffmpeg URL:"
        echo "$url"
        
        # download the zip file
        curl -L "$url" -o "$DIR/ffmpeg.zip"
        unzip "$DIR/ffmpeg.zip" -d "$DIR"
        chmod +x "$FFMPEG_PATH"
        rm "$DIR/ffmpeg.zip"
        olddir="$DIR/__MACOSX"
        if [ -d "$olddir" ]; then
            rmdir "$olddir"
        fi
    else
        echo "No matching ffmpeg Apple Silicon URL found."
        exit 0
    fi

    # also make sure that the temp directory exists
    mkdir -p "$TEMP_PATH"

    sendNotification "Update Successful!" "Quick Music Download was successfully updated." true

}


# function to download the music from the input JSON
downloadMusic() {
    local JSON="$1"

    local TITLE ARTIST ALBUM ALBUM_ARTIST GENRE YEAR MUSIC_URL ARTWORK TRIM ARTWORK_STYLE
    TITLE="$(echo "$JSON" | jq -r '.title')"
    ARTIST="$(echo "$JSON" | jq -r '.artist')"
    ALBUM="$(echo "$JSON" | jq -r '.album')"
    ALBUM_ARTIST="$(echo "$JSON" | jq -r '.album_artist')"
    GENRE="$(echo "$JSON" | jq -r '.genre')"
    YEAR="$(echo "$JSON" | jq -r '.year')"
    MUSIC_URL="$(echo "$JSON" | jq -r '.music_url')"
    ARTWORK="$(echo "$JSON" | jq -r '.artwork')"
    TRIM="$(echo "$JSON" | jq -r '.trim')"
    ARTWORK_STYLE="$(echo "$JSON" | jq -r '.artwork_style')"

    # first, download the artwork, if it has not been downloaded already
    handleArtwork "$ARTWORK" "$ARTWORK_STYLE"

    # build the final filename and sanitize it
    FILENAME="$TITLE - $ARTIST"
    # replace invalid filename characters with underscores
    FILENAME=$(echo "$FILENAME" | sed 's/[\/:*?"<>|\\]/_/g')
    # replace leading dot (.) with underscore (_) to avoid hidden files
    FILENAME=$(echo "$FILENAME" | sed 's/^\./_/')
    # limit the filename to 200 characters
    FILENAME=${FILENAME:0:200}
    # add extension
    FILENAME="$FILENAME.m4a"

    # specify where the file should be located before it is moved to the final destination
    TEMP_FINAL_LOCATION="$TEMP_PATH/$FILENAME"

    # specify the final location for the file
    FINAL_FILE_PATH="$DOWNLOAD_PATH/$FILENAME"

    # handle trim functionality
    DOWNLOAD_SECTIONS=""
    if [[ "$TRIM" != "Start-Stop" && "$TRIM" =~ ^[0-9]+-[0-9]+$ ]]; then
        START_TIME=$(echo "$TRIM" | cut -d'-' -f1)
        STOP_TIME=$(echo "$TRIM" | cut -d'-' -f2)
        START_TIME=$((START_TIME + 10)) # Add 10 seconds to the start time
        DOWNLOAD_SECTIONS="*${START_TIME}-${STOP_TIME}"
        echo "Download sections: $DOWNLOAD_SECTIONS"
    fi

    # next, download the music
    $YT_DLP_PATH \
        -o "$TEMP_AUDIO_PATH" \
        "$MUSIC_URL" \
        -f bestaudio \
        --extract-audio \
        --audio-format m4a \
        --audio-quality 0 \
        ${DOWNLOAD_SECTIONS:+--download-sections="$DOWNLOAD_SECTIONS"} \
        --js-runtimes "deno:$DENO_PATH" \
        --ffmpeg-location $FFMPEG_PATH

    # add metadata with ffmpeg
    "$FFMPEG_PATH" \
        -i "$TEMP_AUDIO_PATH" \
        -i "$TEMP_ARTWORK_PATH" \
        -map 0 -map 1 -c copy -c:a aac -b:a 192k \
        -metadata title="$TITLE" \
        -metadata artist="$ARTIST" \
        -metadata album="$ALBUM" \
        -metadata album_artist="$ALBUM_ARTIST" \
        -metadata genre="$GENRE" \
        -metadata date="$YEAR-01-01" \
        -metadata comment="$YEAR" \
        -disposition:v attached_pic -y \
        "$TEMP_FINAL_LOCATION"
    
    # remove the temporary files
    rm "$TEMP_ARTWORK_PATH"
    rm "$TEMP_AUDIO_PATH"

    # move the audio to the final destination
    mv "$TEMP_FINAL_LOCATION" "$FINAL_FILE_PATH"

}


# function to extract the artwork to the correct path
handleArtwork() {
    local ARTWORK="$1"
    local ARTWORK_STYLE="$2"

    # if the artwork is Base64 data
    if [[ "$ARTWORK" == data:image/* ]]; then
        echo "Decoding base64 artwork..."

        # strip prefix
        local BASE64_DATA
        BASE64_DATA=$(echo "$ARTWORK" | sed -E 's/^data:image\/[a-zA-Z0-9.+-]+;base64,//')

        echo "$BASE64_DATA" | base64 --decode > "$TEMP_ARTWORK_PATH"

    # if the artwork is a url
    elif [[ "$ARTWORK" =~ ^https?:// ]]; then
        echo "Downloading artwork from URL..."

        curl -sfL "$ARTWORK" -o "$TEMP_ARTWORK_PATH"

    # if the artwork is a local file path
    elif [[ -f "$ARTWORK" ]]; then
        echo "Artwork is already downloaded..."
    fi

    # if the artwork_style exists, crop or add margins to the artwork
    if [[ "$ARTWORK_STYLE" == "Edges Cropped" || "$ARTWORK_STYLE" == "Margins Added" ]]; then

        # if it needs cropping, crop it
        if [[ "$ARTWORK_STYLE" == "Edges Cropped" ]]; then

            echo "Cropping artwork to square..."

            "$FFMPEG_PATH" \
                -i "$TEMP_ARTWORK_PATH" \
                -vf "crop=min(iw\,ih):min(iw\,ih)" \
                -y "${TEMP_ARTWORK_PATH}.tmp"

        # if it needs margins added, add them
        elif [[ "$ARTWORK_STYLE" == "Margins Added" ]]; then

            echo "Adding margins to artwork..."

            "$FFMPEG_PATH" \
                -i "$TEMP_ARTWORK_PATH" \
                -vf "pad=max(iw\,ih):max(iw\,ih):(ow-iw)/2:(oh-ih)/2" \
                -y "${TEMP_ARTWORK_PATH}.tmp"

        fi

        # place the squared image into the correct directory
        mv "${TEMP_ARTWORK_PATH}.tmp" "$TEMP_ARTWORK_PATH"

    fi
}


# function to run the main functionality
main(){

    # check for --update argument
    if [ "$INPUT" = "--update" ]; then

        echo "Update flag detected."
        
        # download the binaries
        downloadBinaries

        echo "Scripts and Binaries updated successfully."

        exit 0
        
    fi


    # check if binaries exist
    if [ -f "$YT_DLP_PATH" ] && [ -f "$FFMPEG_PATH" ] && [ -f "$DENO_PATH" ]; then
        echo "Dependencies Exist"
    else
        echo "Dependencies Do Not Exist"
        downloadBinaries
    fi


    # remove and create the temp path again
    rm -rf "$TEMP_PATH"
    mkdir -p "$TEMP_PATH"

    # keep track of whether any files were found
    FOUND_FILES=false
    DOWNLOADED_ANY_FILES=false

    # process each music metadata JSON file in the directory
    for JSON_FILE in "$JSON_DIRECTORY"/*.json; do

        # make sure file is a json file
        [[ -f "$JSON_FILE" ]] || continue

        FOUND_FILES=true

        # load the JSON document into memory
        JSON=$(<"$JSON_FILE")

        # if the music from this file has already been downloaded, skip it
        ALREADY_DOWNLOADED="$(echo "$JSON" | jq -r '.already_encoded')"
        if [ "$ALREADY_DOWNLOADED" = "true" ] ; then
            continue
        fi

        # get the metadata from the JSON
        TITLE="$(echo "$JSON" | jq -r '.title')"
        ARTIST="$(echo "$JSON" | jq -r '.artist')"
        # send a notification about the download starting
        sendNotification "Downloading..." "$TITLE by $ARTIST"

        # download and tag the music file
        downloadMusic "$JSON"
        DOWNLOADED_ANY_FILES=true

        # mark the file as encoded
        jq '.already_encoded = true' "$JSON_FILE" > "${JSON_FILE}.tmp" && mv "${JSON_FILE}.tmp" "$JSON_FILE"

    done

    # notify if no files were found
    if [ "$FOUND_FILES" = false ]; then
        echo "No JSON files found in directory."
        exit 0
    fi

    # notify if no files were found
    if [ "$DOWNLOADED_ANY_FILES" = false ]; then
        echo "No more files to download."
        exit 0
    fi

    # send a notification about the download finishing
    sendNotification "Download Complete!" "All music files have been downloaded!" true

    echo "All downloads complete."

}


# run the main function
main
