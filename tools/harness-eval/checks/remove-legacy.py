import os, importlib
assert not os.path.exists("shop/legacy.py"), "shop/legacy.py still exists"
assert "legacy" not in open("shop/__init__.py").read(), "__init__ still mentions legacy"
shop = importlib.import_module("shop")
assert shop.Cart and shop.Inventory
