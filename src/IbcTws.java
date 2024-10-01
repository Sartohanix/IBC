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

import java.awt.AWTEvent;
import java.awt.Toolkit;
import java.io.File;
import java.io.IOException;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.text.SimpleDateFormat;
import java.text.ParseException;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Date;
import java.util.Enumeration;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.TimeUnit;

/**
 * @author stevek
 *
 * This is our way of automating the Interactive Brokers' TWS and Gateway applications so they do not require human interaction.
 * IBC is a class whose main starts up the TWS or Gateway application, and which
 * monitors the application for certain events, such as the login dialog,
 * after which it can automatically respond to these events.
 * Upon seeing the login dialog, it fills out the username and pwd and presses the button.
 * Upon seeing the "allow incoming connection dialog it presses the yes button.
 *
 * This code is based original code by Ken Geis (ken_geis@telocity.com).
 *
**/

public class IbcTws {
    private static MainLogReader mainLogReader;

    private IbcTws() { }

    public static void main(final String[] args) throws Exception {
        if (Thread.getDefaultUncaughtExceptionHandler() == null) {
            Thread.setDefaultUncaughtExceptionHandler(new ibcalpha.ibc.UncaughtExceptionHandler());
        }
        checkArguments(args);
        setupDefaultEnvironment(args, false);
        load();
    }

    static void setupDefaultEnvironment(final String[] args, final boolean isGateway) throws Exception {
        SessionManager.initialise(isGateway);
        Settings.initialise(new DefaultSettings(args));
        LoginManager.initialise(new DefaultLoginManager(args));
        MainWindowManager.initialise(new DefaultMainWindowManager());
        TradingModeManager.initialise(new DefaultTradingModeManager(args));
    }

    static void checkArguments(String[] args) {
        /**
         * Allowable parameter combinations:
         *
         * 1. No parameters
         *
         * 2. <iniFile> [<tradingMode>]
         *
         * 3. <iniFile> <apiUserName> <apiPassword> [<tradingMode>]
         *
         * 4. <iniFile> <fixUserName> <fixPassword> <apiUserName> <apiPassword> [<tradingMode>]
         *
         * where:
         *
         *      <iniFile>       ::= NULL | path-and-filename-of-.ini-file
         *
         *      <tradingMode>   ::= blank | LIVETRADING | PAPERTRADING
         *
         *      <apiUserName>   ::= blank | username-for-TWS
         *
         *      <apiPassword>   ::= blank | password-for-TWS
         *
         *      <fixUserName>   ::= blank | username-for-FIX-CTCI-Gateway
         *
         *      <fixPassword>   ::= blank | password-for-FIX-CTCI-Gateway
         *
         */
        if (args.length > 6) {
            Utils.logError("Incorrect number of arguments passed. quitting...");
            Utils.logRawToConsole("Number of arguments = " +args.length);
            for (String arg : args) {
                Utils.logRawToConsole(arg);
            }
            Utils.exitWithError(ErrorCodes.INCORRECT_NUMBER_OF_ARGS);
        }
    }

    public static void load() {
        try {
            printVersionInfo();

            printProperties();

            Settings.settings().logDiagnosticMessage();
            LoginManager.loginManager().logDiagnosticMessage();
            MainWindowManager.mainWindowManager().logDiagnosticMessage();
            TradingModeManager.tradingModeManager().logDiagnosticMessage();
            ConfigDialogManager.configDialogManager().logDiagnosticMessage();

            startCommandServer();

            startShutdownTimerIfRequired();

            createToolkitListener();

            startSavingTwsSettingsAutomatically();

            startTwsOrGateway();
        } catch (IllegalStateException e) {
            if (e.getMessage().equalsIgnoreCase("Shutdown in progress")) {
                // an exception with this message can occur if a STOP command is
                // processed by IBC while TWS/Gateway is still in early stages
                // of initialisation
                Utils.exitWithoutError();
            }
        }
    }

    public static void printVersionInfo() {
        Utils.logToConsole("version: " + IbcVersionInfo.IBC_VERSION);
    }

    private static void createToolkitListener() {
        Toolkit.getDefaultToolkit().addAWTEventListener(new TwsListener(createWindowHandlers()), AWTEvent.WINDOW_EVENT_MASK);
    }

    private static List<WindowHandler> createWindowHandlers() {
        List<WindowHandler> windowHandlers = new ArrayList<>();

        windowHandlers.add(new AcceptIncomingConnectionDialogHandler());
        windowHandlers.add(new BlindTradingWarningDialogHandler());
        windowHandlers.add(new LoginFrameHandler());
        windowHandlers.add(new GatewayLoginFrameHandler());
        windowHandlers.add(new MainWindowFrameHandler());
        windowHandlers.add(new GatewayMainWindowFrameHandler());
        windowHandlers.add(new NewerVersionDialogHandler());
        windowHandlers.add(new NewerVersionFrameHandler());
        windowHandlers.add(new NotCurrentlyAvailableDialogHandler());
        windowHandlers.add(new TipOfTheDayDialogHandler());
        windowHandlers.add(new NSEComplianceFrameHandler());
        windowHandlers.add(new PasswordExpiryWarningFrameHandler());
        windowHandlers.add(new GlobalConfigurationDialogHandler());
        windowHandlers.add(new TradesFrameHandler());
        windowHandlers.add(new ExistingSessionDetectedDialogHandler());
        windowHandlers.add(new ApiChangeConfirmationDialogHandler());
        windowHandlers.add(new SplashFrameHandler());

        // this line must come before the one for SecurityCodeDialogHandler
        // because both contain an "Enter Read Only" button
        windowHandlers.add(SecondFactorAuthenticationDialogHandler.getInstance());
        windowHandlers.add(new SecurityCodeDialogHandler());

        windowHandlers.add(new ReloginDialogHandler());
        windowHandlers.add(new NonBrokerageAccountDialogHandler());
        windowHandlers.add(new ExitConfirmationDialogHandler());
        windowHandlers.add(new TradingLoginHandoffDialogHandler());
        windowHandlers.add(new LoginFailedDialogHandler());
        windowHandlers.add(new TooManyFailedLoginAttemptsDialogHandler());
        windowHandlers.add(new ShutdownProgressDialogHandler());
        windowHandlers.add(new BidAskLastSizeDisplayUpdateDialogHandler());
        windowHandlers.add(new LoginErrorDialogHandler());
        windowHandlers.add(new CryptoOrderConfirmationDialogHandler());
        windowHandlers.add(new AutoRestartConfirmationDialog());
        windowHandlers.add(new RestartConfirmationDialogHandler());
        windowHandlers.add(new ResetOrderIdConfirmationDialogHandler());
        windowHandlers.add(new ReconnectDataOrAccountConfirmationDialogHandler());
        return windowHandlers;
    }

    private static Date getColdRestartTime() {
        String coldRestartTimeSetting = Settings.settings().getString("ColdRestartTime", "");
        if (coldRestartTimeSetting.length() == 0) {
            return null;
        }

            int shutdownDayOfWeek = Calendar.SUNDAY;
            int shutdownHour;
            int shutdownMinute;
            Calendar cal = Calendar.getInstance();
            try {
                try {
                    cal.setTime((new SimpleDateFormat("HH:mm")).parse(coldRestartTimeSetting));
                } catch (ParseException e) {
                    throw e;
                }
                shutdownHour = cal.get(Calendar.HOUR_OF_DAY);
                shutdownMinute = cal.get(Calendar.MINUTE);
                cal.setTimeInMillis(System.currentTimeMillis());
                cal.set(Calendar.HOUR_OF_DAY, shutdownHour);
                cal.set(Calendar.MINUTE, shutdownMinute);
                cal.set(Calendar.SECOND, 0);
                cal.add(Calendar.DAY_OF_MONTH,
                        (shutdownDayOfWeek + 7 -
                         cal.get(Calendar.DAY_OF_WEEK)) % 7);
                if (!cal.getTime().after(new Date())) {
                    cal.add(Calendar.DAY_OF_MONTH, 7);
                }
            } catch (ParseException e) {
                Utils.exitWithError(ErrorCodes.INVALID_SETTING_VALUE,
                                    "Invalid ColdRestartTime setting: '" + coldRestartTimeSetting + "'; format should be: <hh:mm>   eg 13:00");
            }
            return cal.getTime();
    }

    private static Date getShutdownTime() {
        String shutdownTimeSetting = Settings.settings().getString("ClosedownAt", "");
        if (shutdownTimeSetting.length() == 0) {
            return null;
        } else {
            int shutdownDayOfWeek;
            int shutdownHour;
            int shutdownMinute;
            Calendar cal = Calendar.getInstance();
            try {
                boolean dailyShutdown = false;
                try {
                    cal.setTime((new SimpleDateFormat("E HH:mm")).parse(shutdownTimeSetting));
                    dailyShutdown = false;
                } catch (ParseException e) {
                    try {
                        String today = (new SimpleDateFormat("E")).format(cal.getTime());
                        cal.setTime((new SimpleDateFormat("E HH:mm")).parse(today + " " + shutdownTimeSetting));
                        dailyShutdown = true;
                    } catch (ParseException x) {
                        throw x;
                    }
                }
                shutdownDayOfWeek = cal.get(Calendar.DAY_OF_WEEK);
                shutdownHour = cal.get(Calendar.HOUR_OF_DAY);
                shutdownMinute = cal.get(Calendar.MINUTE);
                cal.setTimeInMillis(System.currentTimeMillis());
                cal.set(Calendar.HOUR_OF_DAY, shutdownHour);
                cal.set(Calendar.MINUTE, shutdownMinute);
                cal.set(Calendar.SECOND, 0);
                cal.add(Calendar.DAY_OF_MONTH,
                        (shutdownDayOfWeek + 7 -
                         cal.get(Calendar.DAY_OF_WEEK)) % 7);
                if (!cal.getTime().after(new Date())) {
                    if (dailyShutdown) {
                        cal.add(Calendar.DAY_OF_MONTH, 1);
                    } else {
                        cal.add(Calendar.DAY_OF_MONTH, 7);
                    }
                }
            } catch (ParseException e) {
                Utils.exitWithError(ErrorCodes.INVALID_SETTING_VALUE,
                                    "Invalid ClosedownAt setting: '" + shutdownTimeSetting + "'; format should be: <[day ]hh:mm>   eg 22:00 or Friday 22:00");
            }
            return cal.getTime();
        }
    }

    private static String getJtsIniFilePath() {
        return getTWSSettingsDirectory() + File.separatorChar + "jts.ini";
    }

    private static String getTWSSettingsDirectory() {
        String path = Settings.settings().getString("IbDir", System.getProperty("user.dir"));
        try {
            Files.createDirectories(Paths.get(path));
        } catch (FileAlreadyExistsException ex) {
            Utils.exitWithError(ErrorCodes.CANT_CREATE_TWS_SETTINGS_DIR,
                                "Failed to create TWS settings directory at: " + path + "; a file of that name already exists");
        } catch (IOException ex) {
            Utils.exitWithException(ErrorCodes.CANT_CREATE_TWS_SETTINGS_DIR, ex);
        }
        return path;
    }

    private static void printProperties() {
        Properties p = System.getProperties();
        Enumeration<Object> i = p.keys();
        Utils.logRawToConsole("System Properties");
        Utils.logRawToConsole("------------------------------------------------------------");
        while (i.hasMoreElements()) {
            String props = (String) i.nextElement();
            String vals = (String) p.get(props);
            if (props.equals("sun.java.command")) {
                //hide credentials
                String[] args = vals.split(" ");
                for (int j = 2; j < args.length - 1; j++) {
                    args[j] = "***";
                }
                vals = String.join(" ", args);
            }
            Utils.logRawToConsole(props + " = " + vals);
        }
        Utils.logRawToConsole("------------------------------------------------------------");
    }

    private static void startGateway() {
        String[] twsArgs = new String[1];
        twsArgs[0] = getTWSSettingsDirectory();
        try {
            Utils.logToConsole("Starting Gateway");
            ibgateway.GWClient.main(twsArgs);
        } catch (Throwable t) {
            Utils.logError("Exception occurred at Gateway entry point: ibgateway.GWClient.main");
            t.printStackTrace(Utils.getErrStream());
            Utils.exitWithError(ErrorCodes.CANT_FIND_ENTRYPOINT);
        }
    }

    private static void startCommandServer() {
        MyCachedThreadPool.getInstance().execute(new CommandServer());
    }

    private static boolean isColdRestart = false;
    private static void startShutdownTimerIfRequired() {
        Date shutdownTime = getShutdownTime();
        Date coldRestartTime = getColdRestartTime();
        if (shutdownTime == null && coldRestartTime == null) return;
        if (shutdownTime == null && coldRestartTime != null) {
            isColdRestart = true;
            shutdownTime = coldRestartTime;
        } else if (shutdownTime != null && coldRestartTime != null) {
            if (coldRestartTime.before(shutdownTime)) {
                isColdRestart = true;
                shutdownTime = coldRestartTime;
            }
        }
        long delay = shutdownTime.getTime() - System.currentTimeMillis();
        Utils.logToConsole(SessionManager.isGateway() ? "Gateway" : "TWS" +
                        " will be " + (isColdRestart ? "cold restarted" : "shut down") + " at " +
                       (new SimpleDateFormat("yyyy/MM/dd HH:mm")).format(shutdownTime));
        MyScheduledExecutorService.getInstance().schedule(() -> {
            MyCachedThreadPool.getInstance().execute(new StopTask(null, isColdRestart, "ColdRestartTime setting"));
        }, delay, TimeUnit.MILLISECONDS);
    }

    private static void startTws() {
        if (Settings.settings().getBoolean("ShowAllTrades", false)) {
            Utils.showTradesLogWindow();
        }
        String[] twsArgs = new String[1];
        twsArgs[0] = getTWSSettingsDirectory();
        try {
            Utils.logToConsole("Starting TWS");
            jclient.LoginFrame.main(twsArgs);
        } catch (Throwable t) {
            Utils.logError("Exception occurred at TWS entry point: jclient.LoginFrame.main");
            t.printStackTrace(Utils.getErrStream());
            Utils.exitWithError(ErrorCodes.CANT_FIND_ENTRYPOINT);
        }
    }

    private static void startTwsOrGateway() {
        Utils.logToConsole("TWS Settings directory is: " + getTWSSettingsDirectory());
        SessionManager.startSession();
        JtsIniManager.initialise(getJtsIniFilePath());
        if (SessionManager.isGateway()) {
            startGateway();
        } else {
            startTws();
        }

        configureResetOrderIdsAtStart();
        configureApiPort();
        configureMasterClientID();
        configureReadOnlyApi();
        configureSendMarketDataInLotsForUSstocks();
        configureAutoLogoffOrRestart();
        configureApiPrecautions();

        Utils.sendConsoleOutputToTwsLog(!Settings.settings().getBoolean("LogToConsole", false));

        mainLogReader = new MainLogReader();
        mainLogReader.initialize();
    }

    private static void configureResetOrderIdsAtStart() {
        String configName= "ResetOrderIdsAtStart";
        boolean resetOrderIds = Settings.settings().getBoolean(configName, false);
        if (resetOrderIds) {
            if (SessionManager.isFIX()) {
                Utils.logToConsole(configName + " - ignored for FIX");
                return;
            }
            (new ConfigurationTask(new ConfigureResetOrderIdsTask(resetOrderIds))).executeAsync();
        }

    }

    private static void configureApiPort() {
        String configName = "OverrideTwsApiPort";
        int portNumber = Settings.settings().getInt(configName, 0);
        if (portNumber != 0) {
            if (SessionManager.isFIX()){
                Utils.logToConsole(configName + " - ignored for FIX");
                return;
            }
            (new ConfigurationTask(new ConfigureTwsApiPortTask(portNumber))).executeAsync();
        }
    }

    private static void configureMasterClientID() {
        String configName = "OverrideTwsMasterClientID";
        String masterClientID = Settings.settings().getString(configName, "");
        if (!masterClientID.equals("")) {
            if (SessionManager.isFIX()){
                Utils.logToConsole(configName + " - ignored for FIX");
                return;
            }
            (new ConfigurationTask(new ConfigureTwsMasterClientIDTask(masterClientID))).executeAsync();
        }
    }

    private static void configureAutoLogoffOrRestart() {
        String configName = "AutoLogoffTime Or AutoRestartTime";
        String autoLogoffTime = Settings.settings().getString("AutoLogoffTime", "");
        String autoRestartTime = Settings.settings().getString("AutoRestartTime", "");
        if (autoRestartTime.length() != 0 || autoLogoffTime.length() != 0) {
            if (SessionManager.isFIX()){
                Utils.logToConsole(configName + " - ignored for FIX");
                return;
            }
        }
        if (autoRestartTime.length() != 0) {
            (new ConfigurationTask(new ConfigureAutoLogoffOrRestartTimeTask("Auto restart", autoRestartTime))).executeAsync();
            if (autoLogoffTime.length() != 0) {
                Utils.logToConsole("AutoLogoffTime is ignored because AutoRestartTime is also set");
            }
        } else if (autoLogoffTime.length() != 0) {
            (new ConfigurationTask(new ConfigureAutoLogoffOrRestartTimeTask("Auto logoff", autoLogoffTime))).executeAsync();
        }
    }

    private static void configureReadOnlyApi() {
        String configName = "ReadOnlyApi";
        if (!Settings.settings().getString(configName, "").equals("")) {
            if (SessionManager.isFIX()){
                Utils.logToConsole(configName + " - ignored for FIX");
                return;
            }
            (new ConfigurationTask(new ConfigureReadOnlyApiTask(Settings.settings().getBoolean(configName,true)))).executeAsync();
        }
    }

    private static void configureSendMarketDataInLotsForUSstocks(){
        String configName = "SendMarketDataInLotsForUSstocks";
        String sendMarketDataInLots = Settings.settings().getString(configName, "");
        if (!sendMarketDataInLots.equals("")) {
            if (SessionManager.isFIX()){
                Utils.logToConsole(configName + " - ignored for FIX");
                return;
            }
            (new ConfigurationTask(new ConfigureSendMarketDataInLotsForUSstocksTask(Settings.settings().getBoolean(configName, true)))).executeAsync();
        }
    }

    private static void configureApiPrecautions() {
        String configName = "ApiPrecautions";

        String bypassOrderPrecautions = Settings.settings().getString("BypassOrderPrecautions", "");
        String bypassBondWarning = Settings.settings().getString("BypassBondWarning", "");
        String bypassNegativeYieldToWorstConfirmation = Settings.settings().getString("BypassNegativeYieldToWorstConfirmation", "");
        String bypassCalledBondWarning = Settings.settings().getString("BypassCalledBondWarning", "");
        String bypassSameActionPairTradeWarning = Settings.settings().getString("BypassSameActionPairTradeWarning", "");
        String bypassPriceBasedVolatilityRiskWarning = Settings.settings().getString("BypassPriceBasedVolatilityRiskWarning", "");
        String bypassUSStocksMarketDataInSharesWarning = Settings.settings().getString("BypassUSStocksMarketDataInSharesWarning", "");
        String bypassRedirectOrderWarning = Settings.settings().getString("BypassRedirectOrderWarning", "");
        String bypassNoOverfillProtectionPrecaution = Settings.settings().getString("BypassNoOverfillProtectionPrecaution", "");

        if (!bypassOrderPrecautions.equals("") ||
                !bypassBondWarning.equals("") ||
                !bypassNegativeYieldToWorstConfirmation.equals("") ||
                !bypassCalledBondWarning.equals("") ||
                !bypassSameActionPairTradeWarning.equals("") ||
                !bypassPriceBasedVolatilityRiskWarning.equals("") ||
                !bypassUSStocksMarketDataInSharesWarning.equals("") ||
                !bypassRedirectOrderWarning.equals("") ||
                !bypassNoOverfillProtectionPrecaution.equals("")) {
            if (SessionManager.isFIX()){
                Utils.logToConsole(configName + " - ignored for FIX");
                return;
            }
            (new ConfigurationTask(new ConfigureApiPrecautionsTask(
                                    bypassOrderPrecautions,
                                    bypassBondWarning,
                                    bypassNegativeYieldToWorstConfirmation,
                                    bypassCalledBondWarning,
                                    bypassSameActionPairTradeWarning,
                                    bypassPriceBasedVolatilityRiskWarning,
                                    bypassUSStocksMarketDataInSharesWarning,
                                    bypassRedirectOrderWarning,
                                    bypassNoOverfillProtectionPrecaution))).executeAsync();

        }
    }

    private static void startSavingTwsSettingsAutomatically() {
        TwsSettingsSaver.getInstance().initialise();
    }

}

