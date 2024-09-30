// This file is part of IBC.
// Copyright (C) 2004 Steven M. Kearns (skearns23@yahoo.com )
// Copyright (C) 2004 - 2018 Richard L King (rlking@aultan.com)
// For conditions of distribution and use, see copyright notice in COPYING.txt

// IBC is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// IBC is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with IBC.  If not, see <http://www.gnu.org/licenses/>.

package ibcalpha.ibc;

import static ibcalpha.ibc.IbcTws.checkArguments;
import static ibcalpha.ibc.IbcTws.setupDefaultEnvironment;

import java.io.Console;

public class IbcGateway {
    public static void main(String[] args) throws Exception {
        if (Thread.getDefaultUncaughtExceptionHandler() == null) {
            Thread.setDefaultUncaughtExceptionHandler(new ibcalpha.ibc.UncaughtExceptionHandler());
        }
        Console console = System.console();

        if (console == null) {
            System.err.println("No console available. Please run the application from the command line.");
            System.exit(1);
        }

        // Check that args.length is either 1 or 2 and that argument 1 is a path pointing to an existing file
        if (args.length != 1 && args.length != 2) {
            System.err.println("Usage: java [args] <path_to_config_file> [trading_mode]");
            System.exit(1);
        }

        // Prompt for username
        String username = console.readLine("Enter username: ");

        // Prompt for password (Input will not be echoed)
        char[] passwordChars = console.readPassword("Enter password: ");
        String password = new String(passwordChars);

        // Re-build arguments
        String[] newArgs;
        if (args.length == 1) {
            newArgs = new String[]{args[0], username, password};
        } else {
            newArgs = new String[]{args[0], username, password, args[1]};
        }

        setupDefaultEnvironment(newArgs, true);
        IbcTws.load();
    }

    public static void printVersionInfo() {
        IbcTws.printVersionInfo();
    }

}
