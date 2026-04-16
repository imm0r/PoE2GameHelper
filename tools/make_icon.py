"""Generate ui/gamehelper.ico from the GameHelper shield logo PNG."""
from PIL import Image
import os

# Source: the GameHelper logo PNG (shield with book, sword, magnifier, potion)
SRC_PNG = os.path.join(os.path.dirname(__file__), "gamehelper_logo.png")
OUT_ICO = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "ui", "gamehelper.ico"))

def main():
    if not os.path.exists(SRC_PNG):
        print(f"Source PNG not found: {SRC_PNG}")
        print("Place the GameHelper logo PNG at that path and re-run.")
        return
    img = Image.open(SRC_PNG).convert("RGBA")
    sizes = [256, 128, 64, 48, 32, 24, 16]
    icons = [img.copy().resize((s, s), Image.LANCZOS) for s in sizes]
    icons[0].save(OUT_ICO, format="ICO", icon_sizes=[(s, s) for s in sizes], append_images=icons[1:])
    print(f"Saved: {OUT_ICO}")

if __name__ == "__main__":
    main()
