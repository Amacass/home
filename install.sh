#!/bin/bash
# Installation script for Game Automation MCP Server

echo "Installing Game Automation MCP Server..."

# Check if Python is installed
if ! command -v python3 &> /dev/null; then
    echo "Python 3 is required but not installed. Please install Python 3.8 or higher."
    exit 1
fi

# Check if ADB is installed
if ! command -v adb &> /dev/null; then
    echo "Installing Android Debug Bridge (ADB)..."
    
    # Install ADB based on the OS
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        sudo apt-get update
        sudo apt-get install -y android-tools-adb
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            brew install android-platform-tools
        else
            echo "Please install Homebrew first, then run: brew install android-platform-tools"
            exit 1
        fi
    else
        echo "Please install ADB manually for your operating system"
        echo "Visit: https://developer.android.com/studio/command-line/adb"
        exit 1
    fi
fi

# Install Python dependencies
echo "Installing Python dependencies..."
pip3 install -r requirements.txt

# Make the server executable
chmod +x mcp_game_automation_server.py

echo "Installation complete!"
echo ""
echo "Usage:"
echo "1. Start your Android emulator"
echo "2. Enable USB debugging in the emulator"
echo "3. Run: python3 mcp_game_automation_server.py"
echo ""
echo "For farming scripts, place template images in the 'templates/' directory"
echo "and customize the scripts in 'farming_scripts/' directory."