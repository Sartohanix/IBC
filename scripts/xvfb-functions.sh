#!/bin/bash


# Command to start Xvfb
start_xvfb_on_display() {
    local display_number="$1"

    # Check if the Xvfb server is already running on this display
    if pgrep -f "Xvfb :$display_number" > /dev/null; then
        echo "Xvfb server is already running on display :$display_number."
        return 1
    fi

    echo -n "Starting Xvfb server on display :$display_number..."
    ( Xvfb :"$display_number" -screen 0 1024x768x24 > /dev/null 2>&1 & )

    sleep .1

    local xvfb_pid=$(pgrep -f "Xvfb :$display_number")

    if [[ -z "$xvfb_pid" ]]; then
        echo "\nFailed to start Xvfb server on display :$display_number."
        return 1
    fi

    echo " Done. (PID = $xvfb_pid)"

    return 0
}

# Command to stop Xvfb
stop_xvfb() {
    local display_number="$1"

    # Find the Xvfb process and kill it
    local xvfb_pid=$(pgrep -f "Xvfb :$display_number")

    if [[ -n "$xvfb_pid" ]]; then
        echo -n "Stopping Xvfb server on display :$display_number..."
        kill "$xvfb_pid"
        echo " Done. (PID = $xvfb_pid)"
    else
        echo "No Xvfb server running on display :$display_number."
    fi
}

start_xvfb() {
    local max_display_number=99
    local display_number=1

    while [[ $display_number -le $max_display_number ]]; do
        if start_xvfb_on_display "$display_number" > /dev/null 2>&1; then
            echo "Started Xvfb server on display :$display_number."

            # Set the global variable for the current Xvfb display
            _current_xvfb_display_=$display_number

            return 0
        fi
        display_number=$((display_number + 1))
    done

    echo "[start_xvfb ERROR] Failed to start Xvfb server on any display up to: $max_display_number."
    _current_xvfb_display_=""

    return 1
}



# Command to list running Xvfb servers
list_xvfb() {
    echo "Listing all running Xvfb servers..."
	pgrep -a Xvfb
}

# Function to get the window tree for a given display ID
get_window_tree() {
    local display_id=$1
    local output=""

    # Stack to keep track of the remaining children at each depth level
    declare -a child_stack=()

    # Function to append a line with proper indentation to the output
    append_with_indent() {
        local depth_level=$1
        local content=$2
        output+=$(printf "%$((depth_level * 4))s%s\n" "" "$content")
    }

    # Function to decrement the depth when no more children are present
    pop_stack() {
        while [[ ${#child_stack[@]} -gt 0 && ${child_stack[-1]} -eq 0 ]]; do
            unset 'child_stack[-1]'
        done
    }

    # Extract the window title from the line
    extract_title() {
        local line="$1"

        # Extract window name or return "(has no name)" if no name is found
        if [[ "$line" =~ ^0x[0-9a-fA-F]+\ (.*): ]]; then
            local title="${BASH_REMATCH[1]}"
            if [[ "$title" =~ \"(.*)\" ]]; then
                printf "%s" "${BASH_REMATCH[1]}"  # Extract the window name inside quotes
            else
                printf "(has no name)"
            fi
        fi
    }

    # Process the output of xwininfo -root -tree
    DISPLAY=":$display_id" xwininfo -root -tree | while read -r line; do
        # Check if the line contains a number of children (increasing depth)
        if [[ "$line" =~ ([0-9]+)\ children ]]; then
            append_with_indent ${#child_stack[@]} "$(extract_title "$line") - ${BASH_REMATCH[1]} children"
            child_stack+=("${BASH_REMATCH[1]}")  # Push number of children to the stack
        # Check if the line indicates a single child
        elif [[ "$line" =~ ([0-9]+)\ child ]]; then
            append_with_indent ${#child_stack[@]} "$(extract_title "$line") - 1 child"
            child_stack+=(1)  # Push 1 child to the stack
        # Detect window entries with a hex code followed by a colon (extract window title)
        elif [[ "$line" =~ ^0x[0-9a-fA-F]+ ]]; then
            append_with_indent ${#child_stack[@]} "$(extract_title "$line")"

            # Decrement the child count at the current depth
            if [[ ${#child_stack[@]} -gt 0 ]]; then
                child_stack[-1]=$((child_stack[-1] - 1))
                pop_stack
            fi
        fi
    done

    echo "$output"
}