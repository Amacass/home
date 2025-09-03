#!/usr/bin/env python3
"""
MCP Server for Mobile Game Automation on Emulators
エミュレータ上でのソシャゲ自動周回用MCPサーバー

This server provides tools for automating mobile games on Android emulators.
Features:
- Screen capture and image recognition
- Touch and swipe automation
- ADB integration for device control
- Template-based farming scripts
"""

import asyncio
import base64
import io
import json
import logging
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import cv2
import numpy as np
from PIL import Image
from mcp import McpError
from mcp.server import Server
from mcp.server.models import InitializationOptions
from mcp.server.stdio import stdio_server
from mcp.types import (
    Resource,
    Tool,
    TextContent,
    ImageContent,
    EmbeddedResource,
)

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("game-automation-mcp")

class GameAutomationServer:
    def __init__(self):
        self.server = Server("game-automation-mcp")
        self.current_device = None
        self.screenshot_cache = {}
        
        # Register tools
        self._register_tools()
        
    def _register_tools(self):
        """Register all available tools"""
        
        @self.server.list_tools()
        async def handle_list_tools() -> List[Tool]:
            """List available automation tools"""
            return [
                Tool(
                    name="list_devices",
                    description="List all connected Android devices/emulators",
                    inputSchema={
                        "type": "object",
                        "properties": {},
                    },
                ),
                Tool(
                    name="connect_device",
                    description="Connect to a specific Android device/emulator",
                    inputSchema={
                        "type": "object",
                        "properties": {
                            "device_id": {
                                "type": "string",
                                "description": "Device ID (e.g., emulator-5554)",
                            }
                        },
                        "required": ["device_id"],
                    },
                ),
                Tool(
                    name="take_screenshot",
                    description="Take a screenshot of the current screen",
                    inputSchema={
                        "type": "object",
                        "properties": {
                            "save_path": {
                                "type": "string",
                                "description": "Path to save screenshot (optional)",
                            }
                        },
                    },
                ),
                Tool(
                    name="tap",
                    description="Tap at specific coordinates",
                    inputSchema={
                        "type": "object",
                        "properties": {
                            "x": {"type": "number", "description": "X coordinate"},
                            "y": {"type": "number", "description": "Y coordinate"},
                            "duration": {
                                "type": "number", 
                                "description": "Tap duration in milliseconds (default: 100)",
                                "default": 100
                            }
                        },
                        "required": ["x", "y"],
                    },
                ),
                Tool(
                    name="swipe",
                    description="Swipe from one point to another",
                    inputSchema={
                        "type": "object",
                        "properties": {
                            "x1": {"type": "number", "description": "Start X coordinate"},
                            "y1": {"type": "number", "description": "Start Y coordinate"},
                            "x2": {"type": "number", "description": "End X coordinate"},
                            "y2": {"type": "number", "description": "End Y coordinate"},
                            "duration": {
                                "type": "number",
                                "description": "Swipe duration in milliseconds (default: 500)",
                                "default": 500
                            }
                        },
                        "required": ["x1", "y1", "x2", "y2"],
                    },
                ),
                Tool(
                    name="find_image",
                    description="Find an image template on the current screen",
                    inputSchema={
                        "type": "object",
                        "properties": {
                            "template_path": {
                                "type": "string",
                                "description": "Path to template image file",
                            },
                            "threshold": {
                                "type": "number",
                                "description": "Match threshold (0.0-1.0, default: 0.8)",
                                "default": 0.8
                            },
                            "take_screenshot": {
                                "type": "boolean",
                                "description": "Take new screenshot before searching (default: true)",
                                "default": True
                            }
                        },
                        "required": ["template_path"],
                    },
                ),
                Tool(
                    name="tap_image",
                    description="Find and tap an image on the screen",
                    inputSchema={
                        "type": "object",
                        "properties": {
                            "template_path": {
                                "type": "string",
                                "description": "Path to template image file",
                            },
                            "threshold": {
                                "type": "number",
                                "description": "Match threshold (0.0-1.0, default: 0.8)",
                                "default": 0.8
                            },
                            "offset_x": {
                                "type": "number",
                                "description": "X offset from center of found image (default: 0)",
                                "default": 0
                            },
                            "offset_y": {
                                "type": "number",
                                "description": "Y offset from center of found image (default: 0)",
                                "default": 0
                            }
                        },
                        "required": ["template_path"],
                    },
                ),
                Tool(
                    name="wait_for_image",
                    description="Wait for an image to appear on screen",
                    inputSchema={
                        "type": "object",
                        "properties": {
                            "template_path": {
                                "type": "string",
                                "description": "Path to template image file",
                            },
                            "timeout": {
                                "type": "number",
                                "description": "Timeout in seconds (default: 30)",
                                "default": 30
                            },
                            "threshold": {
                                "type": "number",
                                "description": "Match threshold (0.0-1.0, default: 0.8)",
                                "default": 0.8
                            },
                            "check_interval": {
                                "type": "number",
                                "description": "Check interval in seconds (default: 1)",
                                "default": 1
                            }
                        },
                        "required": ["template_path"],
                    },
                ),
                Tool(
                    name="run_farming_script",
                    description="Run a predefined farming/grinding script",
                    inputSchema={
                        "type": "object",
                        "properties": {
                            "script_name": {
                                "type": "string",
                                "description": "Name of the farming script to run",
                            },
                            "iterations": {
                                "type": "number",
                                "description": "Number of iterations to run (default: 1)",
                                "default": 1
                            },
                            "config": {
                                "type": "object",
                                "description": "Script-specific configuration parameters",
                                "additionalProperties": True
                            }
                        },
                        "required": ["script_name"],
                    },
                ),
            ]

        @self.server.call_tool()
        async def handle_call_tool(name: str, arguments: Dict[str, Any]) -> List[TextContent]:
            """Handle tool calls"""
            try:
                if name == "list_devices":
                    return await self._list_devices()
                elif name == "connect_device":
                    return await self._connect_device(arguments["device_id"])
                elif name == "take_screenshot":
                    return await self._take_screenshot(arguments.get("save_path"))
                elif name == "tap":
                    return await self._tap(arguments["x"], arguments["y"], arguments.get("duration", 100))
                elif name == "swipe":
                    return await self._swipe(
                        arguments["x1"], arguments["y1"], 
                        arguments["x2"], arguments["y2"], 
                        arguments.get("duration", 500)
                    )
                elif name == "find_image":
                    return await self._find_image(
                        arguments["template_path"],
                        arguments.get("threshold", 0.8),
                        arguments.get("take_screenshot", True)
                    )
                elif name == "tap_image":
                    return await self._tap_image(
                        arguments["template_path"],
                        arguments.get("threshold", 0.8),
                        arguments.get("offset_x", 0),
                        arguments.get("offset_y", 0)
                    )
                elif name == "wait_for_image":
                    return await self._wait_for_image(
                        arguments["template_path"],
                        arguments.get("timeout", 30),
                        arguments.get("threshold", 0.8),
                        arguments.get("check_interval", 1)
                    )
                elif name == "run_farming_script":
                    return await self._run_farming_script(
                        arguments["script_name"],
                        arguments.get("iterations", 1),
                        arguments.get("config", {})
                    )
                else:
                    raise McpError(f"Unknown tool: {name}")
            except Exception as e:
                logger.error(f"Error in {name}: {str(e)}")
                raise McpError(f"Tool execution failed: {str(e)}")

    async def _run_adb_command(self, command: List[str]) -> Tuple[str, str, int]:
        """Run ADB command and return stdout, stderr, return code"""
        if self.current_device:
            command = ["adb", "-s", self.current_device] + command[1:]
        
        process = await asyncio.create_subprocess_exec(
            *command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await process.communicate()
        return stdout.decode(), stderr.decode(), process.returncode

    async def _list_devices(self) -> List[TextContent]:
        """List all connected devices"""
        stdout, stderr, returncode = await self._run_adb_command(["adb", "devices"])
        
        if returncode != 0:
            return [TextContent(type="text", text=f"Error listing devices: {stderr}")]
        
        devices = []
        for line in stdout.strip().split('\n')[1:]:  # Skip header line
            if line.strip() and '\t' in line:
                device_id, status = line.strip().split('\t')
                devices.append(f"{device_id} ({status})")
        
        if not devices:
            return [TextContent(type="text", text="No devices found. Make sure your emulator is running and ADB is enabled.")]
        
        return [TextContent(type="text", text=f"Available devices:\n" + "\n".join(devices))]

    async def _connect_device(self, device_id: str) -> List[TextContent]:
        """Connect to a specific device"""
        # Verify device exists
        stdout, stderr, returncode = await self._run_adb_command(["adb", "devices"])
        
        if device_id not in stdout:
            return [TextContent(type="text", text=f"Device {device_id} not found")]
        
        self.current_device = device_id
        return [TextContent(type="text", text=f"Connected to device: {device_id}")]

    async def _take_screenshot(self, save_path: Optional[str] = None) -> List[TextContent]:
        """Take a screenshot"""
        if not self.current_device:
            return [TextContent(type="text", text="No device connected. Use connect_device first.")]
        
        # Take screenshot using ADB
        stdout, stderr, returncode = await self._run_adb_command([
            "adb", "shell", "screencap", "-p", "/sdcard/screenshot.png"
        ])
        
        if returncode != 0:
            return [TextContent(type="text", text=f"Failed to take screenshot: {stderr}")]
        
        # Pull screenshot from device
        temp_path = "/tmp/screenshot.png"
        stdout, stderr, returncode = await self._run_adb_command([
            "adb", "pull", "/sdcard/screenshot.png", temp_path
        ])
        
        if returncode != 0:
            return [TextContent(type="text", text=f"Failed to pull screenshot: {stderr}")]
        
        # Cache the screenshot
        self.screenshot_cache["latest"] = temp_path
        
        # Save to specified path if provided
        if save_path:
            import shutil
            shutil.copy2(temp_path, save_path)
            return [TextContent(type="text", text=f"Screenshot saved to: {save_path}")]
        
        return [TextContent(type="text", text=f"Screenshot taken and cached: {temp_path}")]

    async def _tap(self, x: float, y: float, duration: int = 100) -> List[TextContent]:
        """Tap at coordinates"""
        if not self.current_device:
            return [TextContent(type="text", text="No device connected. Use connect_device first.")]
        
        stdout, stderr, returncode = await self._run_adb_command([
            "adb", "shell", "input", "tap", str(int(x)), str(int(y))
        ])
        
        if returncode != 0:
            return [TextContent(type="text", text=f"Failed to tap: {stderr}")]
        
        # Add small delay
        await asyncio.sleep(duration / 1000.0)
        
        return [TextContent(type="text", text=f"Tapped at ({int(x)}, {int(y)})")]

    async def _swipe(self, x1: float, y1: float, x2: float, y2: float, duration: int = 500) -> List[TextContent]:
        """Swipe from one point to another"""
        if not self.current_device:
            return [TextContent(type="text", text="No device connected. Use connect_device first.")]
        
        stdout, stderr, returncode = await self._run_adb_command([
            "adb", "shell", "input", "swipe", 
            str(int(x1)), str(int(y1)), str(int(x2)), str(int(y2)), str(duration)
        ])
        
        if returncode != 0:
            return [TextContent(type="text", text=f"Failed to swipe: {stderr}")]
        
        return [TextContent(type="text", text=f"Swiped from ({int(x1)}, {int(y1)}) to ({int(x2)}, {int(y2)})")]

    async def _find_image(self, template_path: str, threshold: float = 0.8, take_screenshot: bool = True) -> List[TextContent]:
        """Find image template on screen"""
        if not self.current_device:
            return [TextContent(type="text", text="No device connected. Use connect_device first.")]
        
        # Take new screenshot if requested
        if take_screenshot:
            await self._take_screenshot()
        
        # Check if we have a cached screenshot
        if "latest" not in self.screenshot_cache:
            return [TextContent(type="text", text="No screenshot available. Take a screenshot first.")]
        
        try:
            # Load template and screenshot
            template = cv2.imread(template_path, cv2.IMREAD_COLOR)
            screenshot = cv2.imread(self.screenshot_cache["latest"], cv2.IMREAD_COLOR)
            
            if template is None:
                return [TextContent(type="text", text=f"Could not load template image: {template_path}")]
            
            if screenshot is None:
                return [TextContent(type="text", text="Could not load screenshot")]
            
            # Perform template matching
            result = cv2.matchTemplate(screenshot, template, cv2.TM_CCOEFF_NORMED)
            min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(result)
            
            if max_val >= threshold:
                # Calculate center coordinates
                h, w = template.shape[:2]
                center_x = max_loc[0] + w // 2
                center_y = max_loc[1] + h // 2
                
                return [TextContent(type="text", text=f"Image found at ({center_x}, {center_y}) with confidence {max_val:.3f}")]
            else:
                return [TextContent(type="text", text=f"Image not found. Best match confidence: {max_val:.3f}")]
        
        except Exception as e:
            return [TextContent(type="text", text=f"Error during image matching: {str(e)}")]

    async def _tap_image(self, template_path: str, threshold: float = 0.8, offset_x: int = 0, offset_y: int = 0) -> List[TextContent]:
        """Find and tap an image"""
        # First find the image
        find_result = await self._find_image(template_path, threshold, True)
        find_text = find_result[0].text
        
        if "Image found at" in find_text:
            # Extract coordinates from the result text
            import re
            match = re.search(r'Image found at \((\d+), (\d+)\)', find_text)
            if match:
                x, y = int(match.group(1)), int(match.group(2))
                # Apply offsets
                x += offset_x
                y += offset_y
                
                # Tap at the location
                tap_result = await self._tap(x, y)
                return [TextContent(type="text", text=f"Found and tapped image at ({x}, {y})")]
            else:
                return [TextContent(type="text", text="Could not parse coordinates from image search result")]
        else:
            return find_result

    async def _wait_for_image(self, template_path: str, timeout: int = 30, threshold: float = 0.8, check_interval: int = 1) -> List[TextContent]:
        """Wait for an image to appear"""
        start_time = time.time()
        
        while time.time() - start_time < timeout:
            find_result = await self._find_image(template_path, threshold, True)
            find_text = find_result[0].text
            
            if "Image found at" in find_text:
                return [TextContent(type="text", text=f"Image appeared after {time.time() - start_time:.1f} seconds. {find_text}")]
            
            await asyncio.sleep(check_interval)
        
        return [TextContent(type="text", text=f"Image did not appear within {timeout} seconds")]

    async def _run_farming_script(self, script_name: str, iterations: int = 1, config: Dict = None) -> List[TextContent]:
        """Run a farming script"""
        if config is None:
            config = {}
            
        scripts_dir = Path("farming_scripts")
        script_path = scripts_dir / f"{script_name}.json"
        
        if not script_path.exists():
            return [TextContent(type="text", text=f"Farming script not found: {script_path}")]
        
        try:
            with open(script_path, 'r', encoding='utf-8') as f:
                script_data = json.load(f)
            
            results = []
            for iteration in range(iterations):
                results.append(f"=== Iteration {iteration + 1}/{iterations} ===")
                
                for step_num, step in enumerate(script_data.get("steps", []), 1):
                    action = step.get("action")
                    params = step.get("params", {})
                    
                    # Apply config overrides
                    for key, value in config.items():
                        if key in params:
                            params[key] = value
                    
                    results.append(f"Step {step_num}: {action}")
                    
                    if action == "tap":
                        await self._tap(params["x"], params["y"], params.get("duration", 100))
                    elif action == "swipe":
                        await self._swipe(params["x1"], params["y1"], params["x2"], params["y2"], params.get("duration", 500))
                    elif action == "tap_image":
                        await self._tap_image(params["template_path"], params.get("threshold", 0.8))
                    elif action == "wait_for_image":
                        await self._wait_for_image(params["template_path"], params.get("timeout", 30))
                    elif action == "wait":
                        await asyncio.sleep(params.get("seconds", 1))
                    
                    # Add delay between steps
                    step_delay = step.get("delay", 1)
                    if step_delay > 0:
                        await asyncio.sleep(step_delay)
                
                # Add delay between iterations
                if iteration < iterations - 1:
                    iteration_delay = script_data.get("iteration_delay", 5)
                    await asyncio.sleep(iteration_delay)
            
            return [TextContent(type="text", text="\n".join(results) + f"\n\nCompleted {iterations} iterations of {script_name}")]
            
        except Exception as e:
            return [TextContent(type="text", text=f"Error running farming script: {str(e)}")]

async def main():
    """Main server entry point"""
    server_instance = GameAutomationServer()
    
    async with stdio_server() as (read_stream, write_stream):
        await server_instance.server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="game-automation-mcp",
                server_version="1.0.0",
                capabilities=server_instance.server.get_capabilities(
                    notification_options=None,
                    experimental_capabilities=None,
                ),
            ),
        )

if __name__ == "__main__":
    asyncio.run(main())