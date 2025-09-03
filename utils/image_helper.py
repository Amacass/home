#!/usr/bin/env python3
"""
Image processing utilities for game automation
"""

import cv2
import numpy as np
from pathlib import Path
from typing import Tuple, Optional, List

class ImageHelper:
    """Helper class for image processing and template matching"""
    
    @staticmethod
    def load_image(image_path: str) -> Optional[np.ndarray]:
        """Load image from path"""
        try:
            image = cv2.imread(image_path, cv2.IMREAD_COLOR)
            return image
        except Exception as e:
            print(f"Error loading image {image_path}: {e}")
            return None
    
    @staticmethod
    def find_template(screenshot: np.ndarray, template: np.ndarray, threshold: float = 0.8) -> Optional[Tuple[int, int, float]]:
        """Find template in screenshot"""
        try:
            result = cv2.matchTemplate(screenshot, template, cv2.TM_CCOEFF_NORMED)
            min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(result)
            
            if max_val >= threshold:
                h, w = template.shape[:2]
                center_x = max_loc[0] + w // 2
                center_y = max_loc[1] + h // 2
                return center_x, center_y, max_val
            
            return None
        except Exception as e:
            print(f"Error in template matching: {e}")
            return None
    
    @staticmethod
    def find_multiple_templates(screenshot: np.ndarray, template: np.ndarray, threshold: float = 0.8) -> List[Tuple[int, int, float]]:
        """Find multiple instances of template in screenshot"""
        try:
            result = cv2.matchTemplate(screenshot, template, cv2.TM_CCOEFF_NORMED)
            locations = np.where(result >= threshold)
            
            matches = []
            h, w = template.shape[:2]
            
            for pt in zip(*locations[::-1]):  # Switch columns and rows
                center_x = pt[0] + w // 2
                center_y = pt[1] + h // 2
                confidence = result[pt[1], pt[0]]
                matches.append((center_x, center_y, confidence))
            
            return matches
        except Exception as e:
            print(f"Error in multiple template matching: {e}")
            return []
    
    @staticmethod
    def create_template_from_screenshot(screenshot_path: str, x: int, y: int, width: int, height: int, output_path: str):
        """Create template image from screenshot coordinates"""
        try:
            screenshot = cv2.imread(screenshot_path)
            template = screenshot[y:y+height, x:x+width]
            cv2.imwrite(output_path, template)
            print(f"Template created: {output_path}")
        except Exception as e:
            print(f"Error creating template: {e}")
    
    @staticmethod
    def resize_image(image: np.ndarray, scale: float) -> np.ndarray:
        """Resize image by scale factor"""
        height, width = image.shape[:2]
        new_width = int(width * scale)
        new_height = int(height * scale)
        return cv2.resize(image, (new_width, new_height), interpolation=cv2.INTER_AREA)
    
    @staticmethod
    def enhance_image_for_ocr(image: np.ndarray) -> np.ndarray:
        """Enhance image for better OCR results"""
        # Convert to grayscale
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        
        # Apply Gaussian blur to reduce noise
        blurred = cv2.GaussianBlur(gray, (5, 5), 0)
        
        # Apply threshold to get binary image
        _, binary = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        
        return binary
    
    @staticmethod
    def save_debug_image(image: np.ndarray, path: str, found_coords: Optional[Tuple[int, int]] = None):
        """Save debug image with optional marker"""
        debug_image = image.copy()
        
        if found_coords:
            x, y = found_coords
            cv2.circle(debug_image, (x, y), 10, (0, 255, 0), 3)
            cv2.putText(debug_image, f"({x},{y})", (x+15, y-15), 
                       cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
        
        cv2.imwrite(path, debug_image)
        print(f"Debug image saved: {path}")

# Example usage functions
def create_templates_from_coordinates():
    """Helper function to create templates from known coordinates"""
    coordinates = {
        "quest_button": (540, 1600, 200, 100),
        "battle_button": (540, 1400, 200, 100),
        "close_button": (960, 200, 80, 80),
    }
    
    screenshot_path = "current_screen.png"
    
    for name, (x, y, w, h) in coordinates.items():
        output_path = f"templates/{name}.png"
        ImageHelper.create_template_from_screenshot(
            screenshot_path, x-w//2, y-h//2, w, h, output_path
        )

if __name__ == "__main__":
    # Example: Create templates from screenshot
    create_templates_from_coordinates()