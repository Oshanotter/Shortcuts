#!/bin/bash

# make any errors cause the whole script to fail (for updating purposes)
set -euo pipefail

# set the default paths
DIR="$HOME/.Shortcuts/Quick_Music_Download"
YT_DLP_PATH="$DIR/yt-dlp"
FFMPEG_PATH="$DIR/ffmpeg"
DENO_PATH="$DIR/deno"
TEMP_PATH="$DIR/temp"
TEMP_ARTWORK_PATH="$TEMP_PATH/artwork.jpg"
TEMP_AUDIO_PATH="$TEMP_PATH/audio.m4a"
DOWNLOAD_PATH="$HOME/Downloads"
INPUT="$1"

echo "Input: $INPUT"


# function to change strings to lowercase
toLowercase() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}


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


# function to search itunes for metadata
searchItunes() {
    local TITLE="$1"
    local UPLOADER="$2"

    # URL encode search term
    local ENCODED
    ENCODED=$(jq -rn --arg v "$TITLE $UPLOADER" '$v|@uri')

    local ITUNES_URL="https://itunes.apple.com/search?term=$ENCODED&limit=1&entity=song"

    # fetch first json
    local JSON1
    JSON1=$(curl -s "$ITUNES_URL")

    local RESULT_COUNT
    RESULT_COUNT=$(echo "$JSON1" | jq -r '.resultCount')

    if [[ "$RESULT_COUNT" -le 0 ]]; then
        echo "No iTunes match found"
        return 1
    fi

    # extract first result
    local TRACK_NAME ARTIST_NAME COLLECTION_ID COLLECTION_NAME RELEASE_DATE ARTWORK GENRE

    TRACK_NAME=$(echo "$JSON1" | jq -r '.results[0].trackName')
    ARTIST_NAME=$(echo "$JSON1" | jq -r '.results[0].artistName')
    COLLECTION_ID=$(echo "$JSON1" | jq -r '.results[0].collectionId')
    COLLECTION_NAME=$(echo "$JSON1" | jq -r '.results[0].collectionName')
    RELEASE_DATE=$(echo "$JSON1" | jq -r '.results[0].releaseDate')
    ARTWORK=$(echo "$JSON1" | jq -r '.results[0].artworkUrl100')
    GENRE=$(echo "$JSON1" | jq -r '.results[0].primaryGenreName')

    # normalize the artist names and track titles for a better match
    TRACK_NAME_N=$(toLowercase "$TRACK_NAME")
    ARTIST_NAME_N=$(toLowercase "$ARTIST_NAME")
    TITLE_N=$(toLowercase "$TITLE")
    UPLOADER_N=$(toLowercase "$UPLOADER")

    # verify match
    if [[ "$TRACK_NAME_N" != *"$TITLE_N"* || "$ARTIST_NAME_N" != *"$UPLOADER_N"* ]]; then
        echo "iTunes match rejected."
        echo "Matching $TRACK_NAME_N by $ARTIST_NAME_N with $TITLE_N by $UPLOADER_N failed."
        return 1
    fi

    # second lookup for album metadata
    local JSON2 ALBUM_ARTIST
    JSON2=$(curl -s "https://itunes.apple.com/lookup?id=$COLLECTION_ID")
    ALBUM_ARTIST=$(echo "$JSON2" | jq -r '.results[0].artistName')

    # year extraction
    local YEAR
    YEAR="${RELEASE_DATE:0:4}"

    # artwork upscale
    ARTWORK="${ARTWORK//100x100bb/1000x1000bb}"

    # featured artists parsing
    local SONG_TITLE SONG_ARTIST FEATURED

    if [[ "$TRACK_NAME" =~ ( \(feat\. | \[feat\. ) ]]; then
        # split at feat marker
        SONG_TITLE="${TRACK_NAME%%"${BASH_REMATCH[1]}"*}"
        FEATURED="${TRACK_NAME#*"${BASH_REMATCH[1]}"}"
        FEATURED="${FEATURED%)*}"
        FEATURED="${FEATURED%]*}"

        SONG_ARTIST="$ARTIST_NAME feat. $FEATURED"
    else
        SONG_TITLE="$TRACK_NAME"
        SONG_ARTIST="$ARTIST_NAME"
    fi

    # album naming rule
    local ALBUM_NAME
    if [[ "$COLLECTION_NAME" == *"feat."* && "$COLLECTION_NAME" == *" - Single" ]]; then
        ALBUM_NAME="$SONG_TITLE - Single"
    else
        ALBUM_NAME="$COLLECTION_NAME"
    fi

    # output JSON
    jq -n \
        --arg title "$SONG_TITLE" \
        --arg artist "$SONG_ARTIST" \
        --arg album "$ALBUM_NAME" \
        --arg album_artist "$ALBUM_ARTIST" \
        --arg genre "$GENRE" \
        --arg year "$YEAR" \
        --arg artwork "$ARTWORK" \
        '{
            title: $title,
            artist: $artist,
            album: $album,
            album_artist: $album_artist,
            genre: $genre,
            year: $year,
            artwork: $artwork
        }'

    return 0
}


# function to parse the default yt-dlp metadata
parseDefaultMetadata() {
    local METADATA="$1"

    local TITLE ARTIST ALBUM ALBUM_ARTIST GENRE YEAR ARTWORK

    # check if the metadata id from youtube
    if [[ "$MUSIC_URL" == *youtube.com* || "$MUSIC_URL" == *youtu.be* ]]; then

        # title
        TITLE=$(echo "$METADATA" | jq -r '.track // .title')

        # artists
        ARTIST=$(echo "$METADATA" | jq -r '
            if .artists then .artists
            elif .creators then .creators
            else [.uploader]
            end
        ')

        # convert array into a string formatted like this: "a, b & c"
        ARTIST=$(echo "$ARTIST" | jq -r '
            if type == "array" then
                if length == 1 then .[0]
                elif length == 2 then "\(.[0]) & \(.[1])"
                else
                    (.[0:-1] | join(", ")) + " & " + .[-1]
                end
            else
                .
            end
        ')

        # album
        local RAW_ALBUM
        RAW_ALBUM=$(echo "$METADATA" | jq -r '.album // empty')

        if [[ -n "$RAW_ALBUM" ]]; then
            # if the album name is the same as the song title, add " - Single" tp the end
            if [[ "$RAW_ALBUM" == "$TITLE" ]]; then
                ALBUM="$RAW_ALBUM - Single"
            else
                ALBUM="$RAW_ALBUM"
            fi
        else
            # if the album tag does not exist in METADATA, use the song title plus " - Single"
            ALBUM="$TITLE - Single"
        fi

        # album artist
        ALBUM_ARTIST="$ARTIST"

        # year
        YEAR=$(echo "$METADATA" | jq -r '
            if .release_year then .release_year
            elif .upload_date then (.upload_date | tostring | .[0:4])
            else empty
            end
        ')

        # genre does not exist on youtube, so leave it empty
        GENRE=$(echo "$METADATA" | jq -r '.genre // empty')

        # artwork
        ARTWORK=$(echo "$METADATA" | jq -r '.thumbnail')
        ARTWORK="${ARTWORK//_webp/}" # replace "_webp" with ""
        ARTWORK="${ARTWORK//.webp/.jpg}" # replace ".webp" with ".jpg"

        # download the thumbnail
        local TMP_IMG="$TEMP_PATH/artwork.jpg"
        curl -s "$ARTWORK" -o "$TMP_IMG"

        # crop with ffmpeg: crop to square at center with height as dimensions
        "$FFMPEG_PATH" -y -i "$TMP_IMG" -vf "crop='min(in_w,in_h):min(in_w,in_h):(in_w-out_w)/2:(in_h-out_h)/2'" "$TMP_IMG"

        ARTWORK="$TMP_IMG"

    elif [[ "$MUSIC_URL" == *soundcloud.com* ]]; then
        # if the metadata is from soundcloud...

        TITLE=$(echo "$METADATA" | jq -r '.title')
        ARTIST=$(echo "$METADATA" | jq -r '.uploader')
        ALBUM_ARTIST="$ARTIST"
        GENRE=$(echo "$METADATA" | jq -r '.genre // empty')

        ALBUM="$TITLE - Single"

        YEAR=$(echo "$METADATA" | jq -r '.upload_date[0:4]')

        ARTWORK=$(echo "$METADATA" | jq -r '.thumbnail')

    fi

    # output json
    jq -n \
        --arg title "$TITLE" \
        --arg artist "$ARTIST" \
        --arg album "$ALBUM" \
        --arg album_artist "$ALBUM_ARTIST" \
        --arg genre "$GENRE" \
        --arg year "$YEAR" \
        --arg artwork "$ARTWORK" \
        '{
            title: $title,
            artist: $artist,
            album: $album,
            album_artist: $album_artist,
            genre: $genre,
            year: $year,
            artwork: $artwork
        }'
}


# function to download the music from the input JSON
downloadMusic() {
    local JSON="$1"

    local TITLE ARTIST ALBUM ALBUM_ARTIST GENRE YEAR MUSIC_URL ARTWORK TRIM
    TITLE="$(echo "$JSON" | jq -r '.title')"
    ARTIST="$(echo "$JSON" | jq -r '.artist')"
    ALBUM="$(echo "$JSON" | jq -r '.album')"
    ALBUM_ARTIST="$(echo "$JSON" | jq -r '.album_artist')"
    GENRE="$(echo "$JSON" | jq -r '.genre')"
    YEAR="$(echo "$JSON" | jq -r '.year')"
    MUSIC_URL="$(echo "$JSON" | jq -r '.music_url')"
    ARTWORK="$(echo "$JSON" | jq -r '.artwork')"
    TRIM="$(echo "$JSON" | jq -r '.trim')"

    # first, download the artwork, if it has not been downloaded already
    handleArtwork "$ARTWORK"

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

    # if the artwork is Base64 data
    if [[ "$ARTWORK" == data:image/* ]]; then
        echo "Decoding base64 artwork..."

        # strip prefix
        local BASE64_DATA
        BASE64_DATA=$(echo "$artwork" | sed -E 's/^data:image\/[a-zA-Z0-9.+-]+;base64,//')

        echo "$BASE64_DATA" | base64 --decode > "$TEMP_ARTWORK_PATH"

    # if the artwork is a url
    elif [[ "$ARTWORK" =~ ^https?:// ]]; then
        echo "Downloading artwork from URL..."

        curl -sfL "$ARTWORK" -o "$TEMP_ARTWORK_PATH"

    # if the artwork is a local file path
    elif [[ -f "$ARTWORK" ]]; then
        echo "Artwork is already downloaded..."
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


    # check if the url is valid
    if [ "$INPUT" = "" ]; then

        echo "No input detected."
        exit 0
        
    elif [[ "$INPUT" = *"youtube.com"* || "$INPUT" = *"youtu.be"* ]]; then

        # check to see if the url is a valid youtube link
        if [[ "$INPUT" =~ ^(https?://)?([a-zA-Z0-9-]+\.)?(youtube\.com/watch\?v=|youtu\.be/)([A-Za-z0-9_-]{11})([&?].*)?$ ]]; then
            VIDEO_ID="${BASH_REMATCH[4]}"
            MUSIC_URL="https://music.youtube.com/watch?v=$VIDEO_ID"
            echo "YouTube URL: $MUSIC_URL"
        else
            echo "Invalid YouTube video URL"
            exit 0
        fi

    elif [[ "$INPUT" = *"soundcloud.com"* ]]; then

        #check to see if the url is a valid soundcloud link
        if [[ "$INPUT" =~ ^(https?://)?(www\.)?soundcloud\.com/([^/]+)/([^/?]+) ]]; then

            ARTIST="${BASH_REMATCH[3]}"
            TRACK="${BASH_REMATCH[4]}"
            
            # reject non-track pages
            if [[ "$INPUT" =~ /(sets|albums|tracks|popular-tracks|reposts) ]]; then
                echo "Invalid SoundCloud URL."
                exit 0
            fi

            # normalize to https
            MUSIC_URL="https://soundcloud.com/$ARTIST/$TRACK"
            echo "SoundCloud URL: $MUSIC_URL"

        else
            echo "Invalid SoundCloud URL."
        fi

    else
        echo "Invalid url."
        exit 0
    fi


    # gather the metadata JSON

    # send a notification about the download starting
    sendNotification "Starting Download..." "Quick Music Download"
    
    # get the metadata JSON
    METADATA="$("$YT_DLP_PATH" --print-json --skip-download "$MUSIC_URL")"
    TITLE="$(echo "$METADATA" | jq -r '.title')"
    UPLOADER="$(echo "$METADATA" | jq -r '.uploader')"
    echo "Title: $TITLE"
    echo "Uploader: $UPLOADER"

    # search iTunes for the correct metadata
    if JSON=$(searchItunes "$TITLE" "$UPLOADER"); then
        echo "iTunes match found!"
        echo "$JSON"

    else
        # itunes metadata could not be found, so use the default yt-dlp metadata
        echo "Using metadata from yt-dlp instead..."

        JSON=$(parseDefaultMetadata "$METADATA")
    fi

    # add the music url to the dict
    JSON=$(echo "$JSON" | jq --arg val "$MUSIC_URL" '. + {music_url: $val}')
    echo "$JSON"

    # finally, download the music
    downloadMusic "$JSON"

    # send a notification about the download finishing
    sendNotification "Download Complete!" "$TITLE by $UPLOADER" true

}


# run the main function
main
