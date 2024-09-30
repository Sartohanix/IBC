#!/bin/bash

#### Automatic installation file for the IBAlgo framework ########
##                                                              ##
## Global variables:                                            ##
##    - g_path: The path to IBAlgo's main directory             ##
##    - l_dir: The path at which the module will be installed   ##
##    - tmp_dir: The path to which temporary installation files ##
##               may be written                                 ##
##                                                              ##
##  Note: this script will be sourced from within the scripts   ##
##        directory. Always use abolute paths!                  ##
##################################################################

build_ibc_from_source() {
    echo
    echo "--- Building IBC from source ... ---"
    echo

    local ibg_path="$g_path/modules/ibg"

    # Java compatibility handling
    # Step 1: get ibg's embedded java version number

        local release_file="$ibg_path/jre/release"
        if [ ! -f "$release_file" ]; then
            echo "ERROR: Java release file not found at $release_file."
            return 1
        fi

        local java_version_line=$(grep "JAVA_VERSION=" "$release_file")
        if [ -z "$java_version_line" ]; then
            echo "ERROR: JAVA_VERSION not found in release file"
            return 1
        fi

        local java_version
        java_version=$(echo "$java_version_line" | cut -d'=' -f2 | tr -d '"' | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
        if [ -z "$java_version" ]; then
            echo "ERROR: Failed to extract JAVA_VERSION from release file"
            return 1
        fi

        echo "(Detected Java version: $java_version. Updating the build.xml file.)"

    # Step 2: Insert the version number in the build.xml file
        sed -i "s/\[COMPILERVERSIONOPTIONS\]/source=\"$java_version\" target=\"$java_version\" compiler=\"javac$java_version\"/g" "$l_dir/build.xml"
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to update Java version in build.xml"
            return 1
        fi

    # Now
    (cd "$l_dir"; export IBC_BIN="$ibg_path/jars"; ant)

    # Check if the build was successful
    if [ ! -f "$l_dir/IBC.jar" ]; then
        echo
        echo "ERROR: IBC build failed."
        echo


            # Debug-print the whole content of $l_dir/build.xml file
            echo "DEBUG: Content of $l_dir/build.xml:"
            cat "$l_dir/build.xml"
            echo "END OF DEBUG: $l_dir/build.xml content"


        return 1
    fi

    # Remove build files
    rm -rf "$l_dir/src" "$l_dir/build.xml" "$l_dir/README.md" "$l_dir/LICENSE"

    # Configure now ?
    while true; do
        read -rp "Open config editor now? [Y/n]: " choice
        case "$choice" in
            [Yy]* | "" )
                echo "[DEBUG] Running configure.sh ..."

                source "$l_dir/scripts/configure.sh"
                break
                ;;
            [Nn]* )
                break
                ;;
            * )
                echo "Error: Invalid input. Please enter 'y' for yes or 'n' for no."
                ;;
        esac
    done

    # Install is now complete. The following is required by IBC's auto-restart feature
    if [[ -e "${ibg_path}/ibgateway" ]]; then mv "${ibg_path}/ibgateway" "${ibg_path}/_ibgateway"; fi

    return 0
}


echo
echo " ### INSTALLING IBC ### "
echo

build_ibc_from_source

if [ $? -ne 0 ]; then
    echo
    echo "ERROR: IBC installation failed."
    echo
    return 1
fi

echo
echo " ### IBC: INSTALLATION COMPLETE ### "
echo