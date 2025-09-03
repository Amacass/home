#!/usr/bin/env python3
"""
Setup script for Game Automation MCP Server
"""

from setuptools import setup, find_packages

setup(
    name="game-automation-mcp",
    version="1.0.0",
    description="MCP Server for Mobile Game Automation on Emulators",
    author="Game Automation Team",
    packages=find_packages(),
    install_requires=[
        "mcp>=1.0.0",
        "opencv-python>=4.8.0",
        "pillow>=10.0.0",
        "numpy>=1.24.0",
        "aiofiles>=23.0.0",
    ],
    python_requires=">=3.8",
    entry_points={
        "console_scripts": [
            "game-automation-mcp=mcp_game_automation_server:main",
        ],
    },
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: Developers",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
    ],
)