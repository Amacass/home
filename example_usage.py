#!/usr/bin/env python3
"""
Example usage of Game Automation MCP Server
ゲーム自動化MCPサーバーの使用例
"""

import asyncio
import json
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def main():
    """Example usage of the game automation MCP server"""
    
    # Connect to the MCP server
    server_params = StdioServerParameters(
        command="python3",
        args=["mcp_game_automation_server.py"],
    )
    
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            # Initialize the session
            await session.initialize()
            
            print("=== Game Automation MCP Server Example ===")
            
            # 1. List available devices
            print("\n1. Listing devices...")
            result = await session.call_tool("list_devices", {})
            print(result.content[0].text)
            
            # 2. Connect to device (replace with your device ID)
            print("\n2. Connecting to device...")
            # You would replace "emulator-5554" with your actual device ID
            device_id = "emulator-5554"  # Change this to your emulator's device ID
            result = await session.call_tool("connect_device", {"device_id": device_id})
            print(result.content[0].text)
            
            # 3. Take a screenshot
            print("\n3. Taking screenshot...")
            result = await session.call_tool("take_screenshot", {"save_path": "current_screen.png"})
            print(result.content[0].text)
            
            # 4. Example tap operation
            print("\n4. Performing tap operation...")
            result = await session.call_tool("tap", {"x": 540, "y": 960})
            print(result.content[0].text)
            
            # 5. Example swipe operation
            print("\n5. Performing swipe operation...")
            result = await session.call_tool("swipe", {
                "x1": 540, "y1": 1200,
                "x2": 540, "y2": 600,
                "duration": 1000
            })
            print(result.content[0].text)
            
            # 6. Image recognition example (if template exists)
            print("\n6. Looking for image template...")
            result = await session.call_tool("find_image", {
                "template_path": "templates/quest_button.png",
                "threshold": 0.8
            })
            print(result.content[0].text)
            
            # 7. Run farming script example
            print("\n7. Running farming script...")
            result = await session.call_tool("run_farming_script", {
                "script_name": "daily_quest",
                "iterations": 1
            })
            print(result.content[0].text)
            
            print("\n=== Example completed ===")

if __name__ == "__main__":
    asyncio.run(main())