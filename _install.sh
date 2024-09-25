#!/bin/bash

install_ibc_from_source() {
    IBC_BIN="$g_path/modules/ibg/jars"

    ant -v "$l_dir"

    while :; do
        sleep 1
    done
}