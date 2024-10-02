// This file is part of IBC.

package ibcalpha.ibc;

import java.awt.Component;
import java.awt.Container;
import java.awt.Window;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.util.Map;
import java.util.Timer;
import java.util.TimerTask;

import javax.swing.JPanel;
import javax.swing.JTabbedPane;
import javax.swing.JTextArea;
import javax.swing.JViewport;
import javax.swing.SwingUtilities;
import javax.swing.text.JTextComponent;

import ibcalpha.ibc.Settings;

public class MainLogReader {
    private String logfile;
    private JTextArea logTextArea;
    private int lastLineRead = 0;
    private static final int LINE_LENGTH = 1000;
    private static final int INTERVAL = 2500;

    public void initialize() {
        logTextArea = null;
        logfile = Settings.settings().getString("IbDir", System.getProperty("user.dir")) + "/ibg.log";

        File file = new File(logfile);
        if (!file.exists()) {
            try {
                System.out.println("\n\n[DEBUG] ----- Creating log file: " + logfile + "  ------\n\n");
                file.createNewFile();
            } catch (IOException e) {
                System.err.println("Debug: Error creating log file: " + e.getMessage());
                e.printStackTrace();
            }
        }

        start();
    }

    private void start() {
        Timer timer = new Timer();
        timer.scheduleAtFixedRate(new TimerTask() {
            @Override
            public void run() {
                if (logTextArea == null) {
                    System.out.println("\n\n[DEBUG] ----- Looking for text area... ------\n\n");
                    findLogTextArea();
                } else {
                    readAndAppendLog();
                }
            }
        }, 0, INTERVAL);
    }

    private void findLogTextArea() {
        for (Window window : Window.getWindows()) {
            // if ("ibgateway.aC".equals(window.getClass().getName())) {
            if (true) {
                System.out.println("<<<<< Looking into window " + window.getClass().getName() + " ... >>>>>");
                logTextArea = findLogTextArea(window);
                if (logTextArea != null) {
                    System.out.println("\n\n[DEBUG] ----- Found logTextArea: " + logTextArea + "  ------\n\n");
                    break;
                }
                else {
                    System.out.println("\n\n[DEBUG] ----- DID NOT FIND logTextArea: " + logTextArea + "  ------\n\n");
                    listOpenWindows();
                    System.out.println("\n\n[DEBUG] ----- --------------------------------------  ------\n\n");
                }
            }
        }
    }

    private void readAndAppendLog() {
        if (logTextArea == null) {
            return;
        }

        String[] lines = logTextArea.getText().split("\n");

        try (BufferedWriter writer = new BufferedWriter(new FileWriter(logfile, true))) {
            for (int i = lastLineRead; i < lines.length; i++) {
                String line = lines[i];
                if (line.length() > LINE_LENGTH) {
                    line = line.substring(0, LINE_LENGTH) + " < ... (truncated) ... >";
                }
                writer.write(line);
                writer.newLine();
            }
            lastLineRead = lines.length;
        } catch (IOException e) {
            System.err.println("Debug: Error writing to log file: " + e.getMessage());
            e.printStackTrace();
        }
    }

    private JTextArea findLogTextArea(Component root) {
        if (root instanceof JPanel) {
            for (Component child : ((JPanel) root).getComponents()) {
                if (child instanceof JTabbedPane) {
                    JTextArea result = searchInTabbedPane((JTabbedPane) child);
                    if (result != null) {
                        return result;
                    }
                }
            }
        }

        if (root instanceof Container) {
            for (Component child : ((Container) root).getComponents()) {
                JTextArea result = findLogTextArea(child);
                if (result != null) {
                    return result;
                }
            }
        }

        return null;
    }

    private JTextArea searchInTabbedPane(JTabbedPane tabbedPane) {
        for (Component child : tabbedPane.getComponents()) {
            JTextArea textArea = findJTextAreaInComponent(child);
            if (textArea != null) {
                return textArea;
            }
        }
        getComponentTree(tabbedPane);
        return null;
    }

    private JTextArea findJTextAreaInComponent(Component component) {
        if (component instanceof JViewport) {
            Component viewportChild = ((JViewport) component).getView();
            if (viewportChild instanceof JTextArea) {
                return (JTextArea) viewportChild;
            }
        } else if (component instanceof Container) {
            for (Component child : ((Container) component).getComponents()) {
                JTextArea textArea = findJTextAreaInComponent(child);
                if (textArea != null) {
                    return textArea;
                }
            }
        }
        return null;
    }

    public static void listOpenWindows() {
        Window[] windows = Window.getWindows(); // Get all currently open windows

        if (windows.length == 0) {
            System.out.println("No open windows found.");
        } else {
            for (int i = 0; i < windows.length; i++) {
                System.out.println("Window " + (i + 1) + ": " + windows[i].getClass().getName());
            }
        }
    }

    private void getComponentTree(Component component) {
        StringBuilder builder = new StringBuilder();
        traverseComponents(component, builder, 0);
        System.out.println("\n\n\n\n\n" + builder.toString() + "\n\n\n\n\n");
    }

    private void traverseComponents(Component component, StringBuilder builder, int depth) {
        // Indent based on the depth of the component
        for (int i = 0; i < depth; i++) {
            builder.append("  ");  // Indentation
        }

        // Append the current component's class name
        builder.append(component.getClass().getName()).append("\n---------------------\n");
        if (component instanceof JTextComponent) {
            builder.append(" Text = " + ((JTextComponent) component).getText()).append("\n---------------------\n");
        }
        else {
            builder.append("Class Name = " + component.getClass().getName()).append("\n---------------------\n");
        }

        // If the component is a container, recursively traverse its children
        if (component instanceof Container) {
            Component[] children = ((Container) component).getComponents();
            for (Component child : children) {
                traverseComponents(child, builder, depth + 1);
            }
        }
    }
 }
