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
    local IBC_BIN="$g_path/modules/ibg/jars"

    echo
    echo "--- Building IBC from source ... ---"
    echo

    (cd "$l_dir"; ant)

    # Check if the build was successful
    if [ ! -f "$l_dir/ibc.jar" ]; then
        echo
        echo "ERROR: IBC build failed."
        echo
        return 1
    fi

    # Remove java source files
    rm -rf "$l_dir/src"

    # Configure now ?
    while true; do
        read -rp "Open config editor now? [Y/n]: " choice
        case "$choice" in
            [Yy]* | "" )
                break
                source "$l_dir/scripts/configure.sh"
                return 1
                ;;
            [Nn]* )
                return 0
                ;;
            * )
                echo "Error: Invalid input. Please enter 'y' for yes or 'n' for no."
                ;;
        esac
    done
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

rm -rf "$l_dir/src" "$l_dir/build.xml" "$l_dir/README.md" "$l_dir/LICENSE"


echo
echo " ### IBC: INSTALLATION COMPLETE ### "
echo