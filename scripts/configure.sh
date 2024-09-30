#!/bin/bash

# Disable specific shellcheck warnings
# shellcheck disable=SC2155

# ---------------------------
# Global Variables and Declarations
# ---------------------------

# Set l_dir to current directory if not set
l_dir="${l_dir:-$(pwd)}"

# Log file path
LOG_FILE="$l_dir/configure_ibc.log"

# Declare associative arrays for configuration items
declare -A item_names
declare -A item_descriptions
declare -A item_detailed_descriptions
declare -A item_types
declare -A item_defaults
declare -A item_selects
declare -A item_depths

# Associative array to track expanded families
declare -A expanded_families

# Variables for menu navigation
focus_index=0
menu_items=()
menu_keys=()
total_lines=0

# Variable to track the current mode: "normal" or "edit"
current_mode="normal"

# Variable to store description lines during editing/selecting
declare -a description_lines

# Starting line number for the menu
start_line=3  # Adjusted for title and spacing

# Variable to store jq filter in select_option
jq_filter=""

# Variable to store the configuration file path globally
config_file_path="$l_dir/IBconfig.json"

# Variable to store the JSON configuration in-memory
config_json=""

# Variable to track the currently expanded family
current_expanded_family=""

# ---------------------------
# Utility Functions
# ---------------------------

# Function to log debug messages with timestamp
log_debug() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "${LOG_FILE}"
}

# Function to build jq filter from key path with proper escaping
build_jq_filter() {
    local key_path="$1"
    IFS='.' read -ra keys <<< "$key_path"
    local filter="."
    for k in "${keys[@]}"; do
        # Escape special characters for jq
        k_escaped=$(printf '%s' "$k" | jq -R '.' | sed 's/^"//;s/"$//')
        if [[ "$k_escaped" =~ ^[0-9]+$ ]]; then
            filter="${filter}[${k_escaped}]"
        else
            filter="${filter}[\"${k_escaped}\"]"
        fi
    done
    echo "$filter"
}

# Function to handle cleanup on exit
cleanup() {
    tput cnorm          # Show cursor
    tput sgr0           # Reset text attributes
    tput rmcup          # Restore original screen
    stty sane           # Restore terminal settings

    # Write the updated JSON configuration back to the file
    if [ -n "$config_json" ]; then
        echo "$config_json" | jq . > "${config_file_path}.tmp" && mv "${config_file_path}.tmp" "$config_file_path"
        log_debug "Configuration saved to '$config_file_path'"
    fi

    log_debug "Exiting configure_ibc script"
}
trap cleanup EXIT
trap cleanup SIGINT SIGTERM

# Function to check dependencies
check_dependencies() {
    local dependencies=("jq" "tput" "stty")
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "Error: '$cmd' is not installed. Please install it and retry."
            log_debug "Missing dependency: $cmd"
            exit 1
        fi
    done
}

# Function to handle terminal resize
handle_resize() {
    clear
    print_menu
    update_description
}
trap 'handle_resize' SIGWINCH

# ---------------------------
# JSON Parsing Functions
# ---------------------------

# Function to parse JSON into associative arrays with sorting
parse_json() {
    local json_data="$1"
    local parent_key="$2"
    local depth="$3"

    log_debug "Parsing JSON at depth $depth with parent_key '$parent_key'"

    local data_type
    data_type=$(echo "$json_data" | jq -r 'type')
    log_debug "Data type: $data_type"

    if [ "$data_type" = "object" ]; then
        # Read keys into arrays for settings and families
        readarray -t settings < <(echo "$json_data" | jq -r 'to_entries[] | select(.value | type == "object" and has("value")) | .key')
        readarray -t families < <(echo "$json_data" | jq -r 'to_entries[] | select(.value | type == "object" and has("value") == false) | .key')

        # Sort settings and families alphanumerically
        IFS=$'\n' sorted_settings=($(printf "%s\n" "${settings[@]}" | sort))
        IFS=$'\n' sorted_families=($(printf "%s\n" "${families[@]}" | sort))
        unset IFS

        # Combine sorted settings and families
        local sorted_keys=("${sorted_settings[@]}" "${sorted_families[@]}")

        log_debug "Sorted keys: ${sorted_keys[*]}"

        for key in "${sorted_keys[@]}"; do
            # Skip hidden parameters
            if [[ "$key" == _* ]]; then
                continue
            fi

            local full_key="${parent_key}${key}"
            local value
            value=$(echo "$json_data" | jq -c --arg k "$key" '.[$k]')

            log_debug "Processing key '$full_key'"

            local value_type
            value_type=$(echo "$value" | jq -r 'type')
            log_debug "Value type: $value_type"

            # Store item depth for indentation
            item_depths["$full_key"]="$depth"

            if [ "$value_type" = "object" ]; then
                local has_value
                has_value=$(echo "$value" | jq 'has("value")')
                local is_select
                is_select=$(echo "$value" | jq 'has("select")')

                if [ "$has_value" = "true" ]; then
                    # It's a setting
                    item_types["$full_key"]="setting"
                    item_defaults["$full_key"]=$(echo "$value" | jq -r '.default // empty')
                    item_names["$full_key"]=$(echo "$value" | jq -r '.name // empty')
                    item_descriptions["$full_key"]=$(echo "$value" | jq -r '.description // empty')
                    item_detailed_descriptions["$full_key"]=$(echo "$value" | jq -r '.detailed_description // empty')
                    if [ "$is_select" = "true" ]; then
                        item_selects["$full_key"]=$(echo "$value" | jq -c '.select')
                    fi
                    log_debug "Registered setting '$full_key'"
                else
                    # It's a family
                    item_types["$full_key"]="family"
                    item_names["$full_key"]=$(echo "$value" | jq -r '.name // empty')
                    item_descriptions["$full_key"]=$(echo "$value" | jq -r '.description // empty')
                    log_debug "Registered family '$full_key'"
                    # Recursively parse the family
                    parse_json "$value" "${full_key}." $((depth + 1))
                fi
            else
                # Unsupported type, log and skip
                log_debug "Skipping key '$full_key' (unsupported type: $value_type)"
                continue
            fi
        done
    elif [ "$data_type" = "array" ]; then
        # Process array elements
        local array_length
        array_length=$(echo "$json_data" | jq 'length')
        log_debug "Processing array of length $array_length"
        for ((i=0; i<array_length; i++)); do
            local array_value
            array_value=$(echo "$json_data" | jq -c ".[$i]")
            local full_key="${parent_key}${i}"
            local value_type
            value_type=$(echo "$array_value" | jq -r 'type')
            log_debug "Processing array element '$full_key' of type '$value_type'"

            # Store item depth for indentation
            item_depths["$full_key"]="$depth"

            if [ "$value_type" = "object" ]; then
                local has_value
                has_value=$(echo "$array_value" | jq 'has("value")')
                local is_select
                is_select=$(echo "$array_value" | jq 'has("select")')

                if [ "$has_value" = "true" ]; then
                    # It's a setting
                    item_types["$full_key"]="setting"
                    item_defaults["$full_key"]=$(echo "$array_value" | jq -r '.default // empty')
                    item_names["$full_key"]=$(echo "$array_value" | jq -r '.name // empty')
                    item_descriptions["$full_key"]=$(echo "$array_value" | jq -r '.description // empty')
                    item_detailed_descriptions["$full_key"]=$(echo "$array_value" | jq -r '.detailed_description // empty')
                    if [ "$is_select" = "true" ]; then
                        item_selects["$full_key"]=$(echo "$array_value" | jq -c '.select')
                    fi
                    log_debug "Registered setting '$full_key'"
                else
                    # It's a family
                    item_types["$full_key"]="family"
                    item_names["$full_key"]=$(echo "$array_value" | jq -r '.name // empty')
                    item_descriptions["$full_key"]=$(echo "$array_value" | jq -r '.description // empty')
                    log_debug "Registered family '$full_key'"
                    # Recursively parse the family
                    parse_json "$array_value" "${full_key}." $((depth + 1))
                fi
            else
                # Unsupported type, log and skip
                log_debug "Skipping array element '$full_key' (unsupported type: $value_type)"
                continue
            fi
        done
    else
        log_debug "Skipping parent_key '$parent_key' (unsupported data type: $data_type)"
    fi
}


# ---------------------------
# Menu Building Functions
# ---------------------------

# Function to build the menu
build_menu() {
    menu_items=()
    menu_keys=()

    # Recursively build the menu starting from the root
    build_menu_recursive "" 0

    total_lines=${#menu_items[@]}
}

# Recursive function to build menu items
build_menu_recursive() {
    local parent_key="$1"
    local depth="$2"

    # Collect child keys at the current depth
    local child_keys=()
    for key in "${!item_types[@]}"; do
        if [[ "$key" == "${parent_key}"* ]] && [ "${item_depths[$key]}" -eq "$depth" ]; then
            child_keys+=("$key")
        fi
    done

    # Sort child keys: settings first, then families, both alphanumerically
    local settings=()
    local families=()
    for key in "${child_keys[@]}"; do
        if [ "${item_types[$key]}" = "setting" ]; then
            settings+=("$key")
        else
            families+=("$key")
        fi
    done

    IFS=$'\n' sorted_settings=($(printf "%s\n" "${settings[@]}" | sort))
    IFS=$'\n' sorted_families=($(printf "%s\n" "${families[@]}" | sort))
    unset IFS

    # Combine sorted settings and families
    local sorted_keys=("${sorted_settings[@]}" "${sorted_families[@]}")

    for key in "${sorted_keys[@]}"; do
        local type="${item_types[$key]}"
        local name="${item_names[$key]}"
        local indent=""
        for ((i=0; i<depth; i++)); do
            indent+="    "
        done

        # Use the last part of the key as name if name is empty
        if [ -z "$name" ]; then
            name="${key##*.}"
        fi

        # Build the display line based on the type
        local display_line=""
        if [ "$type" = "family" ]; then
            # Visual distinction for families
            if [ "${expanded_families[$key]}" = "1" ]; then
                display_line="$indent$(tput bold)$name$(tput sgr0) ▼"
            else
                display_line="$indent$(tput bold)$name$(tput sgr0) ►"
            fi
        else
            display_line="$indent$name"
        fi

        # Add to menu arrays
        menu_items+=("$display_line")
        menu_keys+=("$key")

        # If the family is expanded, recursively add its children
        if [ "$type" = "family" ] && [ "${expanded_families[$key]}" = "1" ]; then
            build_menu_recursive "${key}." $((depth + 1))
        fi
    done
}

# Function to print the entire menu
print_menu() {
    local i
    for ((i=0; i<${#menu_items[@]}; i++)); do
        tput cup $((start_line + i)) 0
        tput el

        local display_line="${menu_items[$i]}"
        local key="${menu_keys[$i]}"

        # Skip lines without a key (e.g., separators or descriptions)
        if [ -z "$key" ]; then
            printf "%s" "$display_line"
            continue
        fi

        local type="${item_types[$key]}"
        local value=""

        if [ "$type" = "setting" ] && [ "$i" -eq "$focus_index" ]; then
            # Retrieve the current value with proper escaping
            value=$(echo "$config_json" | jq -r "$(build_jq_filter "$key").value // empty")
            if [ -z "$value" ]; then
                value="${item_defaults[$key]}"
            fi
            display_line="${display_line} = $value"
        fi

        if [ "$i" -eq "$focus_index" ]; then
            # Highlight the focused item without covering " --> "
            local highlight_length=${#menu_items[$i]}
            tput setaf 3      # Set text color to yellow
            tput rev          # Enable reverse video
            printf "%s" "${display_line:0:$highlight_length}"
            tput sgr0         # Reset text attributes
            printf "%s" "${display_line:$highlight_length}"
        else
            printf "%s" "$display_line"
        fi
    done

    # Clear any remaining lines below the menu
    tput cup $((start_line + i)) 0
    tput ed
}

# Function to update the description at the bottom of the screen
update_description() {
    local key="${menu_keys[$focus_index]}"
    local description=""

    if [ -n "$key" ]; then
        description="${item_descriptions[$key]}"
    fi

    local bottom_line=$(( $(tput lines) - 2 ))
    tput cup "$bottom_line" 0
    tput el

    if [ -n "$description" ]; then
        printf "%s" "$description"
    fi
}

# Function to update the highlighting when navigating the menu
update_highlight() {
    local prev_index="$1"
    local new_index="$2"

    # Unhighlight the previous item
    tput cup $((start_line + prev_index)) 0
    tput el

    local display_line="${menu_items[$prev_index]}"
    local key="${menu_keys[$prev_index]}"

    if [ -n "$key" ]; then
        local type="${item_types[$key]}"
        local value=""
        if [ "$type" = "setting" ]; then
            value=$(echo "$config_json" | jq -r "$(build_jq_filter "$key").value // empty")
            if [ -z "$value" ]; then
                value="${item_defaults[$key]}"
            fi
            display_line="${display_line} = $value"
        fi
    fi

    printf "%s" "$display_line"

    # Highlight the new item without covering " --> "
    tput cup $((start_line + new_index)) 0
    tput el

    display_line="${menu_items[$new_index]}"
    key="${menu_keys[$new_index]}"

    if [ -n "$key" ]; then
        local type="${item_types[$key]}"
        local value=""
        if [ "$type" = "setting" ]; then
            value=$(echo "$config_json" | jq -r "$(build_jq_filter "$key").value // empty")
            if [ -z "$value" ]; then
                value="${item_defaults[$key]}"
            fi
            display_line="${display_line} = $value"
        fi
    fi

    # Highlight the focused item without covering " --> "
    local highlight_length=${#menu_items[$new_index]}
    tput setaf 3      # Set text color to yellow
    tput rev          # Enable reverse video
    printf "%s" "${display_line:0:$highlight_length}"
    tput sgr0         # Reset text attributes
    printf "%s" "${display_line:$highlight_length}"

    # Update the description at the bottom
    update_description
}

# Function to print the menu starting from a specific index (used during updates)
print_menu_from() {
    local start_index="$1"
    local i

    for ((i=start_index; i<${#menu_items[@]}; i++)); do
        tput cup $((start_line + i)) 0
        tput el

        local display_line="${menu_items[$i]}"
        local key="${menu_keys[$i]}"

        # Skip lines without a key
        if [ -z "$key" ]; then
            printf "%s" "$display_line"
            continue
        fi

        local type="${item_types[$key]}"
        local value=""

        if [ "$type" = "setting" ] && [ "$i" -eq "$focus_index" ]; then
            value=$(echo "$config_json" | jq -r "$(build_jq_filter "$key").value // empty")
            if [ -z "$value" ]; then
                value="${item_defaults[$key]}"
            fi
            display_line="${display_line} = $value"
        fi

        if [ "$i" -eq "$focus_index" ]; then
            # Highlight the focused item without covering " --> "
            local highlight_length=${#menu_items[$i]}
            tput setaf 3      # Set text color to yellow
            tput rev          # Enable reverse video
            printf "%s" "${display_line:0:$highlight_length}"
            tput sgr0         # Reset text attributes
            printf "%s" "${display_line:$highlight_length}"
        else
            printf "%s" "$display_line"
        fi
    done

    # Clear any remaining lines below the menu
    tput cup $((start_line + i)) 0
    tput ed

    # Update the description at the bottom
    update_description
}

# Function to cleanup and exit Edit Mode
cleanup_edit_mode() {
    # Reset the mode to normal
    current_mode="normal"

    # Remove any description or input lines related to editing
    remove_description_from_menu

    # Restore the original menu line without the value preview
    update_highlight "$focus_index" "$focus_index"

    # Log the cleanup action
    log_debug "Exited Edit Mode and cleaned up UI elements."
}


# ---------------------------
# Helper Functions for Family Expansion
# ---------------------------

# Function to check if two families are in a parent-child relationship
is_parent_or_child() {
    local parent="$1"
    local child="$2"

    if [[ "$child" == "$parent".* ]]; then
        return 0  # child is a descendant of parent
    elif [[ "$parent" == "$child".* ]]; then
        return 0  # parent is a descendant of child
    else
        return 1  # no relationship
    fi
}

# Function to collapse other families that are not parents or children of the current family
collapse_other_families() {
    local current_family="$1"

    for family in "${!item_types[@]}"; do
        if [ "${item_types[$family]}" != "family" ]; then
            continue
        fi

        if [ "$family" = "$current_family" ]; then
            continue  # Skip the current family
        fi

        # Check if the family is a parent or child of the current family
        if is_parent_or_child "$current_family" "$family"; then
            continue  # Do not collapse if in parent-child relationship
        fi

        # Collapse the family if it's expanded
        if [ "${expanded_families[$family]}" = "1" ]; then
            unset 'expanded_families["'"$family"'"]'
            log_debug "Collapsed family '$family' due to expansion of '$current_family'"
            # If the collapsed family was the currently expanded one, reset tracking
            if [ "$current_expanded_family" = "$family" ]; then
                current_expanded_family=""
            fi
        fi
    done
}

# ---------------------------
# Setting and Option Handling Functions
# ---------------------------

# Function to handle editing a setting
edit_setting() {
    local key="$1"

    # Entering Edit Mode
    current_mode="edit"

    # Ensure key is non-empty
    if [ -z "$key" ]; then
        return
    fi

    # Build jq filter with proper escaping
    local jq_filter
    jq_filter=$(build_jq_filter "$key")

    # Get current value with proper escaping
    local setting_value
    setting_value=$(echo "$config_json" | jq -r "$jq_filter.value // empty")
    if [ -z "$setting_value" ]; then
        setting_value="${item_defaults[$key]}"
    fi

    local detailed_description="${item_detailed_descriptions[$key]}"

    # Determine where to display the prompt (on the same line)
    local prompt_line=$((start_line + focus_index))
    local original_line="${menu_items[$focus_index]}"
    local term_width
    term_width=$(tput cols)

    # Prepare the prompt and description lines
    menu_items[$focus_index]="${original_line} --> "

    # Create a separator line
    local separator_line
    separator_line=$(printf '%*s' "$term_width" '' | tr ' ' '-')

    # Wrap the detailed description into lines
    IFS=$'\n' read -rd '' -a wrapped_description <<< "$(echo -e "$detailed_description")"

    # Assemble description lines
    description_lines=()
    description_lines+=("$separator_line")
    for line in "${wrapped_description[@]}"; do
        description_lines+=("$line")
    done
    description_lines+=("$separator_line")

    # Insert description into menu_items
    local insert_index=$((focus_index + 1))
    for line in "${description_lines[@]}"; do
        menu_items=( "${menu_items[@]:0:$insert_index}" "$line" "${menu_items[@]:$insert_index}" )
        menu_keys=( "${menu_keys[@]:0:$insert_index}" "" "${menu_keys[@]:$insert_index}" )
        insert_index=$((insert_index + 1))
    done

    total_lines=${#menu_items[@]}

    # Redraw the menu from the current line
    print_menu_from "$focus_index"

    # Move cursor to the prompt position
    tput cup "$prompt_line" $(( ${#original_line} + 5 ))

    # Initialize input variables
    local input="$setting_value"
    local cursor_pos=${#input}
    local input_length=${#input}
    local key_pressed

    # Enable character-by-character input
    stty -icanon -echo

    # Input loop
    while true; do
        # Display the current input
        tput cup "$prompt_line" $(( ${#original_line} + 5 ))
        printf "%s" "$input"
        tput el

        # Move cursor to the current position
        tput cup "$prompt_line" $(( ${#original_line} + 5 + cursor_pos ))
        tput cnorm  # Show cursor

        # Read a single key press
        IFS= read -rsn1 key_pressed
        if [ $? -ne 0 ]; then
            # EOF detected (Ctrl+D)
            cleanup
            exit 0
        fi

        # Handle escape sequences
        if [[ $key_pressed == $'\x1b' ]]; then
            # Read the rest of the escape sequence
            read -rsn2 -t 0.01 key_rest
            key_pressed+="$key_rest"
        fi

        case "$key_pressed" in
            $'\e[D')
            # Left arrow
                if [ "$cursor_pos" -gt 0 ]; then
                    cursor_pos=$((cursor_pos - 1))
                fi
                ;;
            $'\e[C')
            # Right arrow
                if [ "$cursor_pos" -lt "$input_length" ]; then
                    cursor_pos=$((cursor_pos + 1))
                fi
                ;;
            $'\e[A')
                # Up arrow in Edit Mode: cancel editing
                stty sane
                remove_description_from_menu
                if [ "$focus_index" -gt 0 ]; then
                    local prev_index="$focus_index"
                    focus_index=$((focus_index - 1))
                    update_highlight "$prev_index" "$focus_index"
                fi
                # Reset mode
                current_mode="normal"
                return
                ;;
            $'\e[B')
                # Down arrow in Edit Mode: cancel editing
                stty sane
                remove_description_from_menu
                if [ "$focus_index" -lt $((total_lines - 1)) ]; then
                    local prev_index="$focus_index"
                    focus_index=$((focus_index + 1))
                    update_highlight "$prev_index" "$focus_index"
                fi
                # Reset mode
                current_mode="normal"
                return
                ;;
            '')
            # Enter key
                # Save input and exit
                stty sane
                break
                ;;
            $'\x7f')
            # Backspace
                if [ "$cursor_pos" -gt 0 ]; then
                    input="${input:0:$((cursor_pos - 1))}${input:$cursor_pos}"
                    cursor_pos=$((cursor_pos - 1))
                    input_length=$((input_length -1))
                fi
                ;;
            $'\e')
                # Escape key: cancel editing
                stty sane
                menu_items[$focus_index]="$original_line"
                remove_description_from_menu
                print_menu_from "$focus_index"
                # Reset mode
                current_mode="normal"
                return
                ;;
            $'\x04')
            # Ctrl+D
                # Exit the script gracefully
                cleanup
                exit 0
                ;;
            *)
            # Regular character
                # Insert the character at the current cursor position
                input="${input:0:$cursor_pos}$key_pressed${input:$cursor_pos}"
                cursor_pos=$((cursor_pos + 1))
                input_length=$((input_length + 1))
                ;;
        esac
    done

    # Restore cursor visibility
    tput civis

    # After editing is complete
    current_mode="normal"

    # Update the JSON data with proper escaping
    local input_escaped
    input_escaped=$(printf '%s' "$input" | jq -Rs '.')

    # Safely update config_json
    config_json=$(echo "$config_json" | jq "$jq_filter.value = $input_escaped")

    log_debug "Updated configuration for '$key' to '$input'"

    # Restore the original menu line
    menu_items[$focus_index]="$original_line"

    # Remove the inserted description lines
    remove_description_from_menu

    # Redraw the menu
    print_menu_from "$focus_index"
}

# Function to remove description lines from the menu after editing/selecting
remove_description_from_menu() {
    local remove_index=$((focus_index + 1))
    local num_remove_lines=${#description_lines[@]}
    if [ "$num_remove_lines" -gt 0 ]; then
        menu_items=( "${menu_items[@]:0:$remove_index}" "${menu_items[@]:$((remove_index + num_remove_lines))}" )
        menu_keys=( "${menu_keys[@]:0:$remove_index}" "${menu_keys[@]:$((remove_index + num_remove_lines))}" )
        total_lines=${#menu_items[@]}
    fi
}

# Function to handle selecting a value from predefined options
select_option() {
    local key="$1"

    # Ensure key is non-empty
    if [ -z "$key" ]; then
        return
    fi

    # Build jq filter with proper escaping
    local jq_filter
    jq_filter=$(build_jq_filter "$key")

    # Retrieve options
    local options_json="${item_selects[$key]}"
    readarray -t options < <(echo "$options_json" | jq -r '.[]')

    # Get current value
    local setting_value
    setting_value=$(echo "$config_json" | jq -r "$jq_filter.value // empty")
    if [ -z "$setting_value" ]; then
        setting_value="${item_defaults[$key]}"
    fi

    # Find the index of the current value
    local select_index=0
    for i in "${!options[@]}"; do
        if [ "${options[$i]}" = "$setting_value" ]; then
            select_index="$i"
            break
        fi
    done

    # Determine where to display the options
    local prompt_line=$((start_line + focus_index))
    local original_line="${menu_items[$focus_index]}"
    local term_width
    term_width=$(tput cols)

    # Create a separator line
    local separator_line
    separator_line=$(printf '%*s' "$term_width" '' | tr ' ' '-')

    # Wrap the detailed description into lines
    IFS=$'\n' read -rd '' -a wrapped_description <<< "$(echo -e "${item_detailed_descriptions[$key]}")"

    # Assemble description lines
    description_lines=()
    description_lines+=("$separator_line")
    for line in "${wrapped_description[@]}"; do
        description_lines+=("$line")
    done
    description_lines+=("$separator_line")

    # Insert description into menu_items
    local insert_index=$((focus_index + 1))
    for line in "${description_lines[@]}"; do
        menu_items=( "${menu_items[@]:0:$insert_index}" "$line" "${menu_items[@]:$insert_index}" )
        menu_keys=( "${menu_keys[@]:0:$insert_index}" "" "${menu_keys[@]:$insert_index}" )
        insert_index=$((insert_index + 1))
    done

    # Insert option items
    local options_start_index=$insert_index
    for opt in "${options[@]}"; do
        menu_items=( "${menu_items[@]:0:$insert_index}" "    $opt" "${menu_items[@]:$insert_index}" )
        menu_keys=( "${menu_keys[@]:0:$insert_index}" "" "${menu_keys[@]:$insert_index}" )
        insert_index=$((insert_index + 1))
    done

    local num_option_lines=${#options[@]}
    total_lines=${#menu_items[@]}

    # Redraw the menu from the current line
    print_menu_from "$focus_index"

    # Highlight the current option
    update_option_highlight -1 "$select_index" "$options_start_index"

    # Input loop for option selection
    while true; do
        # Read a single key press
        local key_pressed
        IFS= read -rsn1 key_pressed
        if [[ $key_pressed == $'\x1b' ]]; then
            # Read the rest of the escape sequence
            read -rsn2 -t 0.01 key_rest
            key_pressed+="$key_rest"
        fi

        case "$key_pressed" in
            $'\e[A')
            # Up arrow
                if [ "$select_index" -gt 0 ]; then
                    local prev_index="$select_index"
                    select_index=$((select_index - 1))
                    update_option_highlight "$prev_index" "$select_index" "$options_start_index"
                fi
                ;;
            $'\e[B')
            # Down arrow
                if [ "$select_index" -lt $(( ${#options[@]} - 1 )) ]; then
                    local prev_index="$select_index"
                    select_index=$((select_index + 1))
                    update_option_highlight "$prev_index" "$select_index" "$options_start_index"
                fi
                ;;
            '')
            # Enter key
                # Save selected option and exit
                setting_value="${options[$select_index]}"
                break
                ;;
            $'\e')
            # Escape key
                # Discard changes and exit
                remove_description_and_options_from_menu "$num_option_lines"
                print_menu_from "$focus_index"
                return
                ;;
            *)
            # Ignore other keys
                ;;
        esac
    done

    # Restore cursor visibility
    tput civis

    # Update the JSON data with proper escaping
    local input_escaped
    input_escaped=$(printf '%s' "$setting_value" | jq -Rs '.')

    # Safely update config_json
    config_json=$(echo "$config_json" | jq "$jq_filter.value = $input_escaped")

    log_debug "Updated configuration for '$key' to '$setting_value'"

    # Restore the original menu line
    menu_items[$focus_index]="$original_line"

    # Remove the inserted description and option lines
    remove_description_and_options_from_menu "$num_option_lines"

    # Redraw the menu
    print_menu_from "$focus_index"
}

# Function to update option highlighting during selection
update_option_highlight() {
    local prev_select="$1"
    local new_select="$2"
    local options_start="$3"

    # Calculate previous and new option lines
    local prev_line=$((options_start + prev_select))
    local new_line=$((options_start + new_select))

    # Unhighlight the previous option
    if [ "$prev_select" -ge 0 ]; then
        tput cup $((start_line + prev_line)) 0
        tput el
        printf "%s" "${menu_items[$prev_line]}"
    fi

    # Highlight the new option
    tput cup $((start_line + new_line)) 0
    tput el
    tput setaf 3      # Set text color to yellow
    tput rev          # Enable reverse video
    printf "%s" "${menu_items[$new_line]}"
    tput sgr0         # Reset text attributes
}

# Function to remove description and option lines after selection
remove_description_and_options_from_menu() {
    local num_option_lines="$1"
    local remove_index=$((focus_index + 1))
    local num_remove_lines=${#description_lines[@]}
    local total_remove_lines=$((num_remove_lines + num_option_lines))

    if [ "$total_remove_lines" -gt 0 ]; then
        menu_items=( "${menu_items[@]:0:$remove_index}" "${menu_items[@]:$((remove_index + total_remove_lines))}" )
        menu_keys=( "${menu_keys[@]:0:$remove_index}" "${menu_keys[@]:$((remove_index + total_remove_lines))}" )
        total_lines=${#menu_items[@]}
    fi
}

# ---------------------------
# Main Function
# ---------------------------

configure_ibc() {
    # Set up logging
    exec 2>>"${LOG_FILE}"  # Redirect stderr to log file

    log_debug "Starting configure_ibc script"

    # Save and clear the screen
    tput smcup
    clear

    # Ensure dependencies are met
    check_dependencies

    # Load the JSON configuration
    if [ ! -f "$config_file_path" ]; then
        echo "Error: IBconfig.json file not found. Please repair IBC's installation and retry."
        log_debug "IBconfig.json file not found at $config_file_path"
        cleanup
        return
    fi

    log_debug "Loading configuration from $config_file_path"
    config_json=$(<"$config_file_path")

    # Retrieve the title with proper escaping
    local config_title
    config_title=$(echo "$config_json" | jq -r '._title // "Configuration"')
    log_debug "Configuration title: $config_title"

    # Parse the JSON into associative arrays with sorting
    parse_json "$config_json" "" 0
    log_debug "Finished JSON parsing"

    # Display the title
    tput cup 0 0
    tput bold
    printf "%s interactive configuration\n" "$config_title"
    tput sgr0
    echo "Use arrow keys to navigate, Enter to select, 'q' to quit."

    # Build and print the initial menu
    build_menu
    print_menu

    # Update description at the bottom
    update_description

    # Hide the cursor during interaction
    tput civis

    # Ensure the first item shows its value correctly
    update_highlight "$focus_index" "$focus_index"

    # Main input loop
    while true; do
        # Read a single key press
        IFS= read -rsn1 input
        if [ $? -ne 0 ]; then
            # EOF detected (Ctrl+D)
            cleanup
            exit 0
        fi

        # Handle escape sequences completely to prevent stray characters
        if [[ $input == $'\x1b' ]]; then
            # Read up to two more characters for a complete escape sequence
            read -rsn2 -t 0.01 rest
            input+="$rest"
        fi

        case "$input" in
            $'\e[A')
                if [ "$current_mode" = "edit" ]; then
                    # If in Edit Mode, cancel editing
                    log_debug "Up arrow pressed in Edit Mode. Cancelling edit."
                    cleanup_edit_mode
                else
                    # Normal Up arrow handling
                    if [ "$focus_index" -gt 0 ]; then
                        local prev_index="$focus_index"
                        focus_index=$((focus_index - 1))
                        update_highlight "$prev_index" "$focus_index"
                    fi
                fi
                ;;
            $'\e[B')
                if [ "$current_mode" = "edit" ]; then
                    # If in Edit Mode, cancel editing
                    log_debug "Down arrow pressed in Edit Mode. Cancelling edit."
                    cleanup_edit_mode
                else
                    # Normal Down arrow handling
                    if [ "$focus_index" -lt $((total_lines - 1)) ]; then
                        local prev_index="$focus_index"
                        focus_index=$((focus_index + 1))
                        update_highlight "$prev_index" "$focus_index"
                    fi
                fi
                ;;
            '')
                # Enter key handling
                local key="${menu_keys[$focus_index]}"
                if [ -z "$key" ]; then
                    continue  # Ignore lines without a key
                fi
                local type="${item_types[$key]}"

                if [ "$type" = "family" ]; then
                    # Toggle expansion
                    if [ "${expanded_families[$key]}" = "1" ]; then
                        unset 'expanded_families["'"$key"'"]'
                        log_debug "Collapsed family '$key'"
                        # If the collapsed family was the currently expanded one, reset tracking
                        if [ "$current_expanded_family" = "$key" ]; then
                            current_expanded_family=""
                        fi
                    else
                        # Collapse other families before expanding
                        collapse_other_families "$key"
                        expanded_families["$key"]="1"
                        current_expanded_family="$key"
                        log_debug "Expanded family '$key'"
                    fi
                    # Rebuild and reprint the menu
                    build_menu
                    print_menu
                    # Update description
                    update_description
                elif [ "$type" = "setting" ]; then
                    # Determine if the setting has predefined options
                    if [ -n "${item_selects[$key]}" ]; then
                        select_option "$key"
                    else
                        edit_setting "$key"
                    fi
                fi
                ;;
            $'\e')
                # Escape key handling
                if [ "$current_mode" = "edit" ]; then
                    # If in Edit Mode, cancel editing
                    log_debug "Escape key pressed in Edit Mode. Cancelling edit."
                    cleanup_edit_mode
                else
                    # Normal Escape key handling
                    # Implement existing behavior
                    ...
                fi
                ;;
            'q')
                # Quit
                log_debug "User initiated quit"
                cleanup
                break
                ;;
            $'\x04')
                # Ctrl+D
                log_debug "User pressed Ctrl+D to quit"
                cleanup
                break
                ;;
            $'\x03')
                # Ctrl+C
                log_debug "User pressed Ctrl+C to quit"
                cleanup
                break
                ;;
            *)
                # Handle other inputs
                ;;
        esac
    done
}

# ---------------------------
# Execute the Script
# ---------------------------

configure_ibc
