#!/usr/bin/env bash

#
# Info    : Workaround for case folding issues for BSP map files with custom assets in Steam games on Linux
# Author  : Scorp (https://github.com/scorpius2k1)
# Repo    : https://github.com/scorpius2k1/linux-bsp-casefolding-workaround
# License : https://www.gnu.org/licenses/gpl-3.0.en.html#license-text
#

version="1.02"
logo="$(cat <<EOF
  _ _                     __          
 | | |                   / _|         
 | | |__  ___ _ __   ___| |___      __
 | | '_ \/ __| '_ \ / __|  _\ \ /\ / /
 | | |_) \__ \ |_) | (__| |  \ V  V / 
 |_|_.__/|___/ .__/ \___|_|   \_/\_/  
             | |                      
             |_| v${version} by Scorp 
EOF
)"

declare path_bsp="$PWD/bsp"
declare path_data="$PWD/.data"
declare path_output="$PWD/fix"
declare path_log="$PWD/log"
declare path_run_log="$PWD/log/run.log"
declare vpkeditcli="$PWD/vpkeditcli"
declare dependencies=(curl unzip rsync parallel)
declare -i bsp_processed=0
declare -i autodetect=0

prompt() {
    while true; do
        read -p "" response
        case "${response,,}" in
            Y|y|"") printf '1\n'; return ;;
            N|n) printf '0\n'; return ;;
            *) printf '%s\n' "$response"; return ;;
        esac
    done
}

checkdeps() {
	local missing=0

	for app in "${dependencies[@]}"
	do
		if ! command -v $app &> /dev/null
		then
			color_msg "red" "=> dependency '$app' is required, but not installed.\n" "bold"
			missing=1
		fi
	done
	if [ $missing -eq 1 ]; then
		echo -e "\nPlease check your distribution's documentation for further instructions.\n"
		exit 1
	fi
}

color_msg() {
    local color="$1"
    local text="$2"
    local style="${3:-normal}"

    local style_code=""
    case "$style" in
        bold)      style_code="\033[1m" ;;
        underline) style_code="\033[4m" ;;
        *)         style_code="" ;;
    esac

    local color_code=""
    case "$color" in
        red)          color_code="\033[31m" ;;
        green)        color_code="\033[32m" ;;
        yellow)       color_code="\033[33m" ;;
        blue)         color_code="\033[34m" ;;
        magenta)      color_code="\033[35m" ;;
        cyan)         color_code="\033[36m" ;;
        white)        color_code="\033[37m" ;;
        black)        color_code="\033[30m" ;;
        bred)         color_code="\033[91m" ;;
        bgreen)       color_code="\033[92m" ;;
        byellow)      color_code="\033[93m" ;;
        bblue)        color_code="\033[94m" ;;
        bmagenta)     color_code="\033[95m" ;;
        bcyan)        color_code="\033[96m" ;;
        bwhite)       color_code="\033[97m" ;;
        "red bg")     color_code="\033[41m" ;;
        "green bg")   color_code="\033[42m" ;;
        "yellow bg")  color_code="\033[43m" ;;
        "blue bg")    color_code="\033[44m" ;;
        *)            color_code="" ;;
    esac

    printf "$style_code$color_code$text\033[0m"
}

game_root() {
    local search_path="${1%/}"
    local -a folders=()
    local -i i=0

    if [ ! -d "$search_path" ]; then
        printf '\n'
        return 1
    fi

    while IFS= read -r -d '' folder; do
        local folder_name=$(basename "$folder")
        if [[ -d "$folder" && "$folder" != "$search_path" && ! "${folder_name,,}" =~ proton && ! "${folder_name,,}" =~ steam ]]; then
            folders+=("$folder")
            ((i++))
        fi
    done < <(find "$search_path" -maxdepth 1 -type d -print0 2>/dev/null)

    if [ ${#folders[@]} -eq 0 ]; then
        printf '\n'
        return 1
    fi

    printf '%s\n' "${folders[@]}" | sort
}

game_folder() {
    local root_path="${1%/}"

    # Validate root path
    if [ ! -d "$root_path" ]; then
        printf "Error: '%s' is not a valid directory\n" "$root_path" >&2
        return 1
    fi

    local -a validate=("cfg" "maps" "download" "gameinfo.txt")
    local current_parent=""
    declare -A found_items

    # Use find to get only direct children (maxdepth 1) of each parent
    while IFS= read -r -d '' item; do
        local parent
        parent=$(dirname "$item")
        local item_name
        item_name=$(basename "$item")

        # Only proceed if this is a new parent directory
        if [ "$parent" != "$current_parent" ]; then
            # Check if all targets were found in the previous parent
            if [ -n "$current_parent" ]; then
                local all_found=1
                for target in "${validate[@]}"; do
                    if [ -z "${found_items[$target]}" ]; then
                        all_found=0
                        break
                    fi
                done
                if [ "$all_found" -eq 1 ]; then
                    printf '%s\n' "$current_parent"
                    return 0
                fi
            fi
            # Reset found_items for the new parent
            declare -A found_items
            current_parent="$parent"
        fi

        # Only consider direct children of current_parent
        if [ "$(dirname "$item")" = "$current_parent" ]; then
            for target in "${validate[@]}"; do
                if [ "${item_name,,}" = "${target,,}" ]; then
                    if [ -d "$item" ] || [ -f "$item" ]; then
                        found_items["$target"]=1
                    fi
                    break
                fi
            done
        fi
    done < <(find "$root_path" -maxdepth 2 -print0 2>/dev/null)

    # Final check for the last parent
    if [ -n "$current_parent" ]; then
        local all_found=1
        for target in "${validate[@]}"; do
            if [ -z "${found_items[$target]}" ]; then
                all_found=0
                break
            fi
        done
        if [ "$all_found" -eq 1 ]; then
            printf '%s\n' "$current_parent"
            return 0
        fi
    fi

    return 1
}

process_bsp() {
    local bsp=""
    local -i failed
    local -a cursors=("/" "-" "\\" "|")
    local -i cursor_index=0

    # Ensure variables are exported for parallel
    export vpkeditcli="$vpkeditcli"
    export path_data="$path_data"
    export steampath="$steampath"
    export path_log="$path_log"

    # Create FIFO
    local fifo=$(mktemp -u)
    mkfifo "$fifo"
    trap 'rm -f "$fifo"' EXIT

    # Only adjust ulimit if necessary
    [ "$(ulimit -n)" -lt 8192 ] && ulimit -n 8192

    color_msg "blue" "Initializing..." "bold"
    
    # Run vpkeditcli and rsync in parallel, streaming results to FIFO
    parallel --jobs $(nproc) --load 90% --memfree 512M --keep-order --line-buffer --quote sh -c '
        bsp="$1"
        bsp_name=$(basename "$bsp")
        echo "Debug: bsp=$bsp" >&2
        if "$vpkeditcli" --no-progress --output "$path_data" --extract / "$bsp" 2> "$path_log/${bsp_name}.log"; then
            echo "Debug: Extraction succeeded for $bsp" >&2
            materials="$path_data/${bsp_name%.*}/materials"
            models="$path_data/${bsp_name%.*}/models"
            sound="$path_data/${bsp_name%.*}/sound"
            [ -d "$materials" ] && rsync -aAHX "$materials" "$steampath"
            [ -d "$models" ] && rsync -aAHX "$models" "$steampath"
            [ -d "$sound" ] && rsync -aAHX "$sound" "$steampath"
            echo "Debug: Sync completed for $bsp" >&2
            rm -f "$path_log/${bsp_name}.log"
            echo "SUCCESS: $bsp"
        else
            echo "Debug: Extraction failed for $bsp" >&2
            echo "FAILED: $bsp"
        fi
    ' sh ::: "${bsp_files[@]}" > "$fifo" 2> "$path_log/process.log" &

    local parallel_pid=$!

    # Process FIFO output
    while IFS= read -r result || [ -n "$result" ]; do
        bsp=""
        failed=0
        if [[ "$result" =~ ^FAILED:\ (.+)$ ]]; then
            bsp="${BASH_REMATCH[1]}"
            failed=1
        elif [[ "$result" =~ ^SUCCESS:\ (.+)$ ]]; then
            bsp="${BASH_REMATCH[1]}"
        else
            continue
        fi

        local cursor="${cursors[cursor_index]}"
        local bsp_name=$(basename "$bsp")
        ((cursor_index = (cursor_index + 1) % 4))
        ((bsp_processed++))

        color_msg "blue" "\r\033[K [$cursor] Processing Maps $bsp_processed/$bsp_total $(((bsp_processed) * 100 / bsp_total))%% \033[36m${bsp_name%.*}..." "bold"

        if [ "$failed" -eq 1 ]; then
            color_msg "yellow" "Warning: Failed to extract '$bsp_name', skipping. Check error log at $path_log/${bsp_name}.log"
            sleep 1
        fi
    done < "$fifo"

    wait "$parallel_pid"
    printf "\n"

    rm -rf $fifo
}

get_latest_vpk() {
    local vpkedit_file="vpkedit"  # Adjust this to the actual extracted filename if different
    local timestamp_file=".vpkedit"
    local download_needed=1
    local current_time=$(date +%s)
    local last_modified
    local time_diff

    # Check if vpkedit exists and timestamp file exists
    if [ -f "$vpkedit_file" ] && [ -f "$timestamp_file" ]; then
        # Read the stored timestamp
        last_modified=$(cat "$timestamp_file" 2>/dev/null)
        if [ -n "$last_modified" ]; then
            # Calculate time difference in seconds
            time_diff=$((current_time - last_modified))
            # 86400 seconds = 24 hours
            if [ "$time_diff" -lt 86400 ]; then
                download_needed=0
                color_msg "white" "VPKEdit is up to date (last updated less than 24 hours ago)\n"
                return 0
            fi
        fi
    fi

    # If we need to download (either file doesn't exist or is older than 24 hours)
    if [ "$download_needed" -eq 1 ]; then
        color_msg "white" "Updating 'vpkedit' to latest release\n(https://github.com/craftablescience/VPKEdit)..."
        printf "\n"
        local latest_url
        latest_url=$(curl -s https://api.github.com/repos/craftablescience/VPKEdit/releases/latest \
            | grep "browser_download_url.*.zip" \
            | grep "Linux-Binaries" \
            | cut -d '"' -f 4)
        if [ -z "$latest_url" ]; then
            color_msg "red" "Error: Failed to fetch latest VPKEdit release URL\n" "bold"
            exit 1
        fi
        local filename
        filename=$(basename "$latest_url")
        curl -s -L -o "$filename" "$latest_url" || { color_msg "red" "Error: Failed to download VPKEdit\n" "bold"; exit 1; }
        unzip -o "$filename" &>/dev/null || { color_msg "red" "Error: Failed to unzip VPKEdit\n" "bold"; exit 1; }
        rm -f "$filename"

        # Update timestamp file with current time
        echo "$current_time" > "$timestamp_file"
    fi
}

shorten_path() {
    local path="$1"
    local depth=5

    IFS='/' read -r -a segments <<< "$path"

    local total=${#segments[@]}

    if [ "$total" -le "$depth" ]; then
        echo "$path"
        return
    fi

    local start=$((total - depth))

    local short=".."
    for ((i = start; i < total; i++)); do
        short="$short/${segments[i]}"
    done

    echo "$short"
}

check_steampath() {
    local steamroot=(
        "$HOME/.local/share/Steam/steamapps/common" # System
        "$HOME/.steam/steam/steamapps/common" # System
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common" # Flatpak
        "$HOME/snap/steam/common/.local/share/Steam/steamapps/common" # Snap
    )
    local steamtype=(
        "System"
        "System"
        "Flatpak"
        "Snap"
    )

    for ((i = 0; i < ${#steamroot[@]}; i++)); do
        if [ -d "${steamroot[$i]}" ]; then
            steampath="${steamroot[$i]}"
            color_msg "green" "${steamtype[$i]} Steam Install Detected\n\n"
            return 0
        fi
    done
}

show_logo() {
    clear
    color_msg "bcyan" "$logo\n\n" "bold"
    color_msg "bcyan" ":: Linux BSP Case Folding Workaround ::\n"
    color_msg "bcyan" "=======================================\n\n"
}

# Main script
show_logo

# Check dependencies
checkdeps

# Ensure vpkeditcli exists and is executable
get_latest_vpk
if [ ! -f "$vpkeditcli" ] || [ ! -x "$vpkeditcli" ]; then
    color_msg "red" "Error: '$vpkeditcli' not found or not executable. Please check the path and permissions.\n" "bold"
    exit 1
fi

# Config
color_msg "white" "\nAttempt to auto-detect game folders/maps? [Y/n] " "bold"
autodetect=$(prompt)

if [ "$autodetect" -eq 1 ]; then

    check_steampath

    if [ ! -d "$steampath" ]; then
        color_msg "red" "Error: Steam path invalid or not found! ($steampath)\n" "bold"
        color_msg "white" "=> Enter valid path to your Steam Games root path (../Steam/steamapps/common): " "bold"
        read -r steampath
        if [ ! -d "$steampath" ]; then
            color_msg "red" "Error: No Steam Games found ($steampath), aborting.\n" "bold"
            exit 1
        fi
    fi

    mapfile -t folder_array < <(game_root "$steampath")
    if [ $? -ne 0 ] || [ ${#folder_array[@]} -eq 0 ]; then
        color_msg "red" "Failed to retrieve game folders! ($steampath)\n" "bold"
        exit 1
    fi

    color_msg "white" "Available Games\n"
    for i in "${!folder_array[@]}"; do
        color_msg "bblue" "$((i+1)): ${folder_array[$i]##*/}\n"
    done

    color_msg "white" "\nWhich game to apply workaround (1-${#folder_array[@]}): " "bold"
    read -r choice
    ((choice--))
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -ge "${#folder_array[@]}" ]; then
        color_msg "red" "Invalid choice, exiting.\n" "bold"
        exit 1
    fi

    steampath="${folder_array[$choice]}"
    game_folder=$(game_folder "$steampath")
    steampath="$game_folder"

    if [ -n "$steampath" ]; then
        path_bsp="$steampath/download/maps"
        steampath="$steampath/download"
        color_msg "green" "Game folder set to '${steampath##*/common/}'\n"
    else
        color_msg "red" "Error: Failed to validate game, exiting.\n\n" "bold"
        exit 1
    fi
else
    steampath="$path_output"
    color_msg "yellow" "Manual Mode Selected\n"
fi

# Init
color_msg "green" "Initializing...\n" "bold"
[ -z "$TERM" ] && export TERM="xterm"
mkdir -p "$path_bsp"
mkdir -p "$path_data"
mkdir -p "$path_log"
rm -rf "$path_data"/* || { color_msg "red" "Error: Failed to clean $path_data\n" "bold"; exit 1; }
find "$path_log"/* ! -name 'run.log' -type f -exec rm -f {} + || { color_msg "red" "Error: Failed to clean $path_log\n" "bold"; exit 1; }
if [ "$autodetect" -eq 0 ]; then
    mkdir -p "$path_output"
    rm -rf "$path_output"/* || { color_msg "red" "Error: Failed to clean $path_output\n" "bold"; exit 1; }
fi
sleep 1

# Gather BSP files
clear
show_logo

date_last_success="$(grep -s "Success: @" "$path_log/run.log" | grep -os "@[0-9]\+" | tail -1)"
[[ -z "$date_last_success" || ! ("$date_last_success" =~ [^[:space:]]) ]] && date_last_success="@0"
mapfile -t bsp_files < <(find -L "$path_bsp" -maxdepth 1 -type f -iname "*.bsp" -newermt "$date_last_success" | sort)
bsp_total=${#bsp_files[@]}

if [ "$bsp_total" -eq 0 ] && [ ! -z "$(ls -A "$steampath")" ]; then
    color_msg "white" "All map files are up to date\n" "bold"
    echo "Success: @$(date +%s)" >> "$path_log/run.log"
    exit 0
elif [ "$bsp_total" -eq 0 ]; then
    color_msg "red" "Error: No Map files (bsp) found in '$path_bsp'\n" "bold"
    exit 1
else
    color_msg "green" "=> $bsp_total maps found in '$(shorten_path "$path_bsp")'\n"
    color_msg "green" "=> Output path '$(shorten_path "$steampath")'\n\n"
    if [[ -d "$steampath/materials" || -d "$steampath/models" || -d "$steampath/sound" ]]; then
        color_msg "yellow" "WARNING: Merging into existing game 'materials/models/sound' data!\n" "bold"
        color_msg "yellow" "Ensure you have a backup of these folders before proceeding, if needed.\n\n"
    fi
    color_msg "white" "Press any key to begin (CTRL+C to abort)..." "bold"
    read -n 1 -s
    printf '\n'

    declare -i start_time=$(date +%s)
    process_bsp
    sleep 1
fi

# Finish up
declare -i end_time=$(date +%s)
declare -i total_seconds=$((end_time - start_time))
declare -i minutes=$((total_seconds / 60))
declare -i seconds=$((total_seconds % 60))

echo "Success: @$end_time" >> "$path_log/run.log"

color_msg "white" "\nCleaning up...\n\n"
rm -rf "$path_data"/* || { color_msg "red" "Error: Failed to clean $path_data\n" "bold"; exit 1; }
echo "$(tail -n 100 "$path_log/run.log")" > "$path_log/run.log" # limit run.log to 100 lines

color_msg "bgreen" "=> SUCCESS! $bsp_processed Maps Processed in ${minutes}m ${seconds}s\n" "bold"
if [ "$autodetect" -eq 0 ]; then
    color_msg "bmagenta" " To apply workaround, move everything from"
    color_msg "white" " '$(shorten_path "$steampath")/' "
    color_msg "bmagenta" "into desired Steam Game download path\n"
    color_msg "white" " Ex. '../Steam/steamapps/common/Half Life 2/download/'\n\n"
    color_msg "magenta" " >> Data must be copied to game download path (custom folder does not work) <<\n\n"
fi
printf '\n'
